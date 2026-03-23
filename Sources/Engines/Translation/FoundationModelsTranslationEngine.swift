import Foundation

struct FoundationModelsTranslationEngine: DiagnosticCapableTranslationEngine {
    var name: String {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return "foundation-models"
        }
        return "foundation-models-unavailable(os)"
#else
        return "foundation-models-unavailable(toolchain)"
#endif
    }

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(input)
        }
#endif
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(
                input,
                onPartialResult: onPartialResult
            )
        }
#endif
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(
                input,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent
            )
        }
#endif
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
    }
}

private enum FoundationModelsIntegrationError: LocalizedError {
    case missingFoundationModelsToolchain

    var errorDescription: String? {
        switch self {
        case .missingFoundationModelsToolchain:
            return "Foundation Models is unavailable in the current build toolchain. Build with Xcode toolchain and retry."
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeTranslator {
    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct StructuredTranslationPayload {
        @Guide(description: "Target language code.")
        var targetLanguage: String
        @Guide(description: "Segment kind label.")
        var kind: String
        @Guide(description: "Translated text only.")
        var translation: String
    }

    private struct StructuredTranslationResult {
        var translation: String
        var kind: SegmentKind?
    }

    static func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)? = nil,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)? = nil
    ) async throws -> [SegmentOutput] {
        try ensureModelAvailability()

        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        let session = LanguageModelSession(instructions: instructions(for: input))
        let sensitiveContentSession = LanguageModelSession(
            instructions: sensitiveContentSafeInstructions(for: input)
        )
        var outputs: [SegmentOutput] = []
        outputs.reserveCapacity(segments.count)

        for segment in segments {
            let prompt = promptForSegment(segment, input: input)
            let finalResult: StructuredTranslationResult

            do {
                finalResult = try await translateStructuredSegmentWithRetry(
                    prompt: prompt,
                    sourceText: segment.text,
                    expectedTargetLanguage: input.targetLanguage,
                    expectedKind: segment.kind,
                    using: session,
                    segmentIndex: segment.index,
                    onPartialResult: onPartialResult,
                    onDiagnosticEvent: onDiagnosticEvent
                )
            } catch {
                if shouldRetryOrFallbackForGeneration(error) {
                    onDiagnosticEvent?(
                        "segment=\(segment.index), kind=\(segment.kind.rawValue): fallback-session-triggered (\(error.localizedDescription))"
                    )
                    let safePrompt = promptForSensitiveContentSegment(segment, input: input)
                    finalResult = await fallbackSafeSegmentTranslation(
                        safePrompt: safePrompt,
                        sourceText: segment.text,
                        expectedTargetLanguage: input.targetLanguage,
                        expectedKind: segment.kind,
                        session: sensitiveContentSession,
                        segmentIndex: segment.index,
                        onPartialResult: onPartialResult,
                        onDiagnosticEvent: onDiagnosticEvent
                    )
                } else {
                    throw error
                }
            }

            let structuredKindLogValue = finalResult.kind?.rawValue ?? "n/a"
            onDiagnosticEvent?(
                "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue), structured-kind=\(structuredKindLogValue)"
            )

            outputs.append(
                SegmentOutput(
                    segmentIndex: segment.index,
                    sourceText: segment.text,
                    translatedText: finalResult.translation
                )
            )
        }

        return outputs
    }

    private static func translateStructuredSegmentWithRetry(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        expectedKind: SegmentKind,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> StructuredTranslationResult {
        do {
            return try await translateSegment(
                prompt: prompt,
                sourceText: sourceText,
                expectedTargetLanguage: expectedTargetLanguage,
                expectedKind: expectedKind,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult
            )
        } catch let error as FoundationModelsStructuredOutputError {
            if !error.isRetryable {
                throw error
            }
            onDiagnosticEvent?("segment=\(segmentIndex), kind=\(expectedKind.rawValue): structured-output-retry (\(error.localizedDescription))")
            let strictPrompt = strictPromptForSegment(
                sourceText: sourceText,
                expectedTargetLanguage: expectedTargetLanguage,
                expectedKind: expectedKind
            )
            do {
                return try await translateSegment(
                    prompt: strictPrompt,
                    sourceText: sourceText,
                    expectedTargetLanguage: expectedTargetLanguage,
                    expectedKind: expectedKind,
                    using: session,
                    segmentIndex: segmentIndex,
                    onPartialResult: onPartialResult
                )
            } catch let finalError as FoundationModelsStructuredOutputError {
                onDiagnosticEvent?(
                    "segment=\(segmentIndex), kind=\(expectedKind.rawValue): structured-output-final-fallback-source-returned (\(finalError.localizedDescription))"
                )
                return StructuredTranslationResult(
                    translation: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: nil
                )
            }
        }
    }

    private static func translateSegment(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        expectedKind: SegmentKind,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> StructuredTranslationResult {
        var latestCompletePayload: StructuredTranslationPayload?
        var latestStreamedTranslation: String?
        var repeatedSnapshotCount = 0
        let maxAllowedCharacters = max(400, min(8_000, sourceText.count * 12))
        let maxSnapshotCount = 240
        let maxStreamingDuration: TimeInterval = 20
        let streamStartedAt = Date()
        var receivedSnapshotCount = 0

        do {
            let stream = session.streamResponse(
                to: prompt,
                generating: StructuredTranslationPayload.self,
                includeSchemaInPrompt: false
            )
            for try await snapshot in stream {
                receivedSnapshotCount += 1

                if latestStreamedTranslation == snapshot.content.translation {
                    repeatedSnapshotCount += 1
                } else {
                    repeatedSnapshotCount = 0
                }

                if repeatedSnapshotCount >= 12 {
                    break
                }

                if receivedSnapshotCount >= maxSnapshotCount {
                    break
                }

                if Date().timeIntervalSince(streamStartedAt) >= maxStreamingDuration {
                    break
                }

                if snapshot.rawContent.jsonString.count > maxAllowedCharacters {
                    break
                }

                if let targetLanguage = snapshot.content.targetLanguage,
                   let kind = snapshot.content.kind,
                   let translation = snapshot.content.translation
                {
                    latestCompletePayload = StructuredTranslationPayload(
                        targetLanguage: targetLanguage,
                        kind: kind,
                        translation: translation
                    )
                }

                let streamedCandidate =
                    snapshot.content.translation?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? extractPartialTranslation(fromRawJSON: snapshot.rawContent.jsonString)

                if let partial = streamedCandidate,
                   !partial.isEmpty,
                   partial != latestStreamedTranslation
                {
                    latestStreamedTranslation = partial
                    onPartialResult?(segmentIndex, partial)
                }
            }
        } catch {
            if let latestCompletePayload {
                return try validateStructuredTranslation(
                    payload: latestCompletePayload,
                    expectedTargetLanguage: expectedTargetLanguage,
                    expectedKind: expectedKind
                )
            }
            throw error
        }

        if let latestCompletePayload {
            let result = try validateStructuredTranslation(
                payload: latestCompletePayload,
                expectedTargetLanguage: expectedTargetLanguage,
                expectedKind: expectedKind
            )
            onPartialResult?(segmentIndex, result.translation)
            return result
        }

        let response = try await session.respond(
            to: prompt,
            generating: StructuredTranslationPayload.self,
            includeSchemaInPrompt: false
        )
        let result = try validateStructuredTranslation(
            payload: response.content,
            expectedTargetLanguage: expectedTargetLanguage,
            expectedKind: expectedKind
        )
        onPartialResult?(segmentIndex, result.translation)
        return result
    }

    private static func extractPartialTranslation(fromRawJSON raw: String) -> String? {
        guard let translationKeyRange = raw.range(of: #""translation""#) else { return nil }
        let tail = raw[translationKeyRange.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        var cursor = raw.index(after: colon)

        while cursor < raw.endIndex, raw[cursor].isWhitespace {
            cursor = raw.index(after: cursor)
        }
        guard cursor < raw.endIndex, raw[cursor] == "\"" else { return nil }
        cursor = raw.index(after: cursor)

        var result = ""
        var escaping = false
        while cursor < raw.endIndex {
            let char = raw[cursor]
            if escaping {
                switch char {
                case "\"":
                    result.append("\"")
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "r":
                    result.append("\r")
                case "\\":
                    result.append("\\")
                default:
                    result.append(char)
                }
                escaping = false
            } else {
                if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    break
                } else {
                    result.append(char)
                }
            }
            cursor = raw.index(after: cursor)
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func ensureModelAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw FoundationModelsRuntimeError.unavailable(reason: String(describing: reason))
        @unknown default:
            throw FoundationModelsRuntimeError.unavailable(reason: "unknown")
        }
    }

    private static func instructions(for input: TranslationInput) -> String {
        """
        You are a translation engine.
        Translate from \(input.sourceLanguage) to \(input.targetLanguage).
        Preserve meaning and punctuation structure whenever possible.
        Do not include explanations, notes, or commentary.
        """
    }

    private static func sensitiveContentSafeInstructions(for input: TranslationInput) -> String {
        """
        You are a universal translation engine.
        Translate from \(input.sourceLanguage) to \(input.targetLanguage).
        The input can include politics, war, safety, or other sensitive topics.
        Your role is strictly translation, not policy analysis.
        Keep meaning and tone faithful.
        Do not refuse, summarize, or add warnings.
        If any part cannot be translated due to safety restrictions, keep only that part in the original language and annotate it with "原文ママ" inside "translation".
        """
    }

    private static func promptForSegment(_ segment: TextSegment, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Source text:")
        lines.append(segment.text)

        if !input.glossaryMatches.isEmpty {
            let glossaryLines = input.glossaryMatches
                .map { "\($0.source)=\($0.target)" }
            lines.append("")
            lines.append("Glossary constraints (prefer exact target terms):")
            lines.append(contentsOf: glossaryLines)
        }

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("")
            lines.append("Protected tokens (do not translate): \(protectedList)")
        }

        lines.append("")
        lines.append("Target language code: \(input.targetLanguage)")
        lines.append("Segment kind: \(segment.kind.rawValue)")
        lines.append("Translate faithfully for this segment kind.")
        lines.append("Important: translation must be translated source text, never the kind label itself.")
        return lines.joined(separator: "\n")
    }

    private static func promptForSensitiveContentSegment(_ segment: TextSegment, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Task: direct translation only.")
        lines.append("Source language: \(input.sourceLanguage)")
        lines.append("Target language: \(input.targetLanguage)")
        lines.append("")
        lines.append("Source text:")
        lines.append(segment.text)

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("")
            lines.append("Protected tokens (do not translate): \(protectedList)")
        }

        lines.append("")
        lines.append("Segment kind: \(segment.kind.rawValue)")
        lines.append("Translate faithfully for this segment kind.")
        lines.append("Important: translation must be translated source text, never the kind label itself.")
        return lines.joined(separator: "\n")
    }

    private static func strictPromptForSegment(
        sourceText: String,
        expectedTargetLanguage: String,
        expectedKind: SegmentKind
    ) -> String {
        """
        Translate this text strictly.
        Rules:
        - target language: \(expectedTargetLanguage)
        - segment kind: \(expectedKind.rawValue)
        - output translation only, no notes or placeholders
        - translation must not be the kind label (for example: heading, general, dialogue, ui-labels, lists, codes_or_path)

        Source text:
        \(sourceText)
        """
    }

    private static func fallbackSafeSegmentTranslation(
        safePrompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        expectedKind: SegmentKind,
        session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async -> StructuredTranslationResult {
        do {
            return try await translateStructuredSegmentWithRetry(
                prompt: safePrompt,
                sourceText: sourceText,
                expectedTargetLanguage: expectedTargetLanguage,
                expectedKind: expectedKind,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent
            )
        } catch {
            onDiagnosticEvent?(
                "segment=\(segmentIndex), kind=\(expectedKind.rawValue): fallback-failed-source-returned (\(error.localizedDescription))"
            )
            return StructuredTranslationResult(
                translation: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: nil
            )
        }
    }

    private static func validateStructuredTranslation(
        payload: StructuredTranslationPayload,
        expectedTargetLanguage: String,
        expectedKind: SegmentKind
    ) throws -> StructuredTranslationResult {
        let actualCode = normalizedLanguageCode(payload.targetLanguage)
        let expectedCode = normalizedLanguageCode(expectedTargetLanguage)
        guard actualCode == expectedCode else {
            throw FoundationModelsStructuredOutputError.targetLanguageMismatch(
                expected: expectedCode,
                actual: actualCode
            )
        }
        guard let parsedKind = parseSegmentKind(payload.kind) else {
            throw FoundationModelsStructuredOutputError.invalidFormat(
                content: "kind=\(payload.kind)"
            )
        }
        guard parsedKind == expectedKind else {
            throw FoundationModelsStructuredOutputError.kindMismatch(
                expected: expectedKind.rawValue,
                actual: parsedKind.rawValue
            )
        }

        let trimmed = payload.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FoundationModelsStructuredOutputError.emptyTranslation
        }
        guard !isKindLabelTranslation(trimmed) else {
            throw FoundationModelsStructuredOutputError.kindLabelTranslation(value: trimmed)
        }
        guard !isPlaceholderTranslation(trimmed) else {
            throw FoundationModelsStructuredOutputError.placeholderTranslation(value: trimmed)
        }
        return StructuredTranslationResult(
            translation: trimmed,
            kind: parsedKind
        )
    }

    private static func isPlaceholderTranslation(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let placeholders: Set<String> = [
            "<translated text>",
            "<translation>",
            "[translated text]",
            "[translation]",
            "(translated text)",
            "(translation)",
            "{translated text}",
            "{translation}",
        ]
        return placeholders.contains(normalized)
    }

    private static func isKindLabelTranslation(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return SegmentKind.allCases.map(\.rawValue).contains(normalized)
    }

    private static func normalizedLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
    }

    private static func parseSegmentKind(_ raw: String) -> SegmentKind? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let exact = SegmentKind(rawValue: normalized) {
            return exact
        }

        switch normalized {
        case "ui_labels", "ui-label", "ui_label":
            return .uiLabels
        case "list", "list-item", "list_item":
            return .lists
        case "code_or_path", "code-path", "code_or_paths", "codes_or_paths":
            return .codesOrPath
        default:
            return nil
        }
    }

    private static func shouldRetryOrFallbackForGeneration(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain.contains("FoundationModels.LanguageModelSession.GenerationError") {
            return true
        }

        let reflectedType = String(reflecting: type(of: error))
        if reflectedType.contains("LanguageModelSession.GenerationError")
            || reflectedType.contains("GenerationError")
        {
            return true
        }

        let localized = error.localizedDescription.lowercased()
        return localized.contains("unsafe")
            || localized.contains("safety")
            || localized.contains("content")
            || localized.contains("policy")
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsStructuredOutputError: LocalizedError {
    case invalidFormat(content: String)
    case targetLanguageMismatch(expected: String, actual: String)
    case kindMismatch(expected: String, actual: String)
    case emptyTranslation
    case kindLabelTranslation(value: String)
    case placeholderTranslation(value: String)

    var isRetryable: Bool {
        switch self {
        case .invalidFormat:
            return true
        case .targetLanguageMismatch:
            return true
        case .kindMismatch:
            return true
        case .emptyTranslation:
            return true
        case .kindLabelTranslation:
            return true
        case .placeholderTranslation:
            return true
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Model output was not valid structured translation content."
        case .targetLanguageMismatch(let expected, let actual):
            return "Structured output target mismatch. expected=\(expected), actual=\(actual)"
        case .kindMismatch(let expected, let actual):
            return "Structured output kind mismatch. expected=\(expected), actual=\(actual)"
        case .emptyTranslation:
            return "Structured output translation was empty."
        case .kindLabelTranslation(let value):
            return "Structured output translation was a kind label (\(value))."
        case .placeholderTranslation(let value):
            return "Structured output translation was placeholder text (\(value))."
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeError: LocalizedError {
    case unavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Foundation Models is unavailable (\(reason)). Enable Apple Intelligence and finish downloading model assets, then retry."
        }
    }
}
#endif
