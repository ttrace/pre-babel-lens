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
        throw FoundationModelsIntegrationError.unsupportedOperatingSystem
#else
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
#endif
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
        throw FoundationModelsIntegrationError.unsupportedOperatingSystem
#else
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
#endif
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
        throw FoundationModelsIntegrationError.unsupportedOperatingSystem
#else
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
#endif
    }
}

private enum FoundationModelsIntegrationError: LocalizedError {
    case missingFoundationModelsToolchain
    case unsupportedOperatingSystem

    var errorDescription: String? {
        switch self {
        case .missingFoundationModelsToolchain:
            return "Foundation Models is unavailable in the current build toolchain. Build with Xcode toolchain and retry."
        case .unsupportedOperatingSystem:
            return "Foundation Models requires macOS 26.0+ / iOS 26.0+. Please run this app on a supported OS version."
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
private actor FoundationModelsTranslationGate {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let next = waiters.removeFirst()
        next.resume()
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeTranslator {
    private static let translationGate = FoundationModelsTranslationGate()

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
        try await translationGate.withLock {
            try ensureModelAvailability()

            let segments = input.segments.isEmpty
                ? [TextSegment(index: 0, text: input.originalText)]
                : input.segments

            var outputs: [SegmentOutput] = []
            outputs.reserveCapacity(segments.count)

            for segment in segments {
                // Keep each segment isolated to avoid context-window growth.
                let session = LanguageModelSession(instructions: instructions(for: input))
                let prompt = promptForSegment(segment, input: input)
                let finalResult: StructuredTranslationResult

                do {
                    finalResult = try await translateStructuredSegmentWithRetry(
                        prompt: prompt,
                        sourceText: segment.text,
                        expectedTargetLanguage: input.targetLanguage,
                        preprocessKind: segment.kind,
                        using: session,
                        segmentIndex: segment.index,
                        onPartialResult: onPartialResult,
                        onDiagnosticEvent: onDiagnosticEvent
                    )
                } catch {
                    onDiagnosticEvent?(
                        "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): no-retry-source-returned (\(error.localizedDescription))"
                    )
                    finalResult = StructuredTranslationResult(
                        translation: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        kind: nil
                    )
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
    }

    private static func translateStructuredSegmentWithRetry(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        preprocessKind: SegmentKind,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> StructuredTranslationResult {
        if verboseLoggingEnabled {
            let sourceForLog = sanitizedForLog(sourceText) ?? "(empty)"
            let promptForLog = sanitizedForLog(prompt) ?? "(empty)"
            onDiagnosticEvent?(
                "verbose model-input segment=\(segmentIndex), preprocess-kind=\(preprocessKind.rawValue), sourceChars=\(sourceText.count), promptChars=\(prompt.count), source=\(sourceForLog), prompt=\(promptForLog)"
            )
        }
        do {
            return try await translateSegment(
                prompt: prompt,
                sourceText: sourceText,
                expectedTargetLanguage: expectedTargetLanguage,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent
            )
        } catch let error as FoundationModelsStructuredOutputError {
            onDiagnosticEvent?(
                "segment=\(segmentIndex), preprocess-kind=\(preprocessKind.rawValue): structured-output-no-retry-source-returned (\(error.localizedDescription))"
            )
            return StructuredTranslationResult(
                translation: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: nil
            )
        }
    }

    private static func translateSegment(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> StructuredTranslationResult {
        let response = try await session.respond(
            to: prompt,
            generating: StructuredTranslationPayload.self,
            includeSchemaInPrompt: false
        )
        if verboseLoggingEnabled {
            let translationForLog = sanitizedForLog(response.content.translation) ?? "(empty)"
            onDiagnosticEvent?(
                "verbose model-output segment=\(segmentIndex), payload={targetLanguage=\(response.content.targetLanguage), kind=\(response.content.kind), translationChars=\(response.content.translation.count), translation=\(translationForLog)}"
            )
        }
        let result = try validateStructuredTranslation(
            payload: response.content,
            expectedTargetLanguage: expectedTargetLanguage
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
        Translate every sentence in the source text; do not omit any part.
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
        lines.append("Translate every sentence in the source text; do not omit any part.")
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
        lines.append("Translate every sentence in the source text; do not omit any part.")
        lines.append("Important: translation must be translated source text, never the kind label itself.")
        return lines.joined(separator: "\n")
    }

    private static func strictPromptForSegment(
        sourceText: String,
        expectedTargetLanguage: String
    ) -> String {
        """
        Translate this text strictly.
        Rules:
        - target language: \(expectedTargetLanguage)
        - translate every sentence in the source text; do not omit any part
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
        preprocessKind: SegmentKind,
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
                preprocessKind: preprocessKind,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent
            )
        } catch {
            onDiagnosticEvent?(
                "segment=\(segmentIndex), preprocess-kind=\(preprocessKind.rawValue): fallback-failed-source-returned (\(error.localizedDescription))"
            )
            return StructuredTranslationResult(
                translation: sourceText.trimmingCharacters(in: .whitespacesAndNewlines),
                kind: nil
            )
        }
    }

    private static func validateStructuredTranslation(
        payload: StructuredTranslationPayload,
        expectedTargetLanguage: String
    ) throws -> StructuredTranslationResult {
        let actualCode = normalizedLanguageCode(payload.targetLanguage)
        let expectedCode = normalizedLanguageCode(expectedTargetLanguage)
        guard actualCode == expectedCode else {
            throw FoundationModelsStructuredOutputError.targetLanguageMismatch(
                expected: expectedCode,
                actual: actualCode
            )
        }
        let parsedKind = parseSegmentKind(payload.kind)

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

    private static func sanitizedForLog(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.replacingOccurrences(of: "\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }

        let limit = 1_500
        guard compact.count > limit else { return compact }

        let headCount = 1_000
        let tailCount = 350
        let omitted = compact.count - headCount - tailCount
        let head = compact.prefix(headCount)
        let tail = compact.suffix(tailCount)
        return "\(head)...(truncated \(omitted) chars)...\(tail)"
    }

    private static var verboseLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "developerVerboseModeEnabled")
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsStructuredOutputError: LocalizedError {
    case invalidFormat(content: String)
    case targetLanguageMismatch(expected: String, actual: String)
    case emptyTranslation
    case kindLabelTranslation(value: String)
    case placeholderTranslation(value: String)

    var isRetryable: Bool {
        switch self {
        case .invalidFormat:
            return true
        case .targetLanguageMismatch:
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
