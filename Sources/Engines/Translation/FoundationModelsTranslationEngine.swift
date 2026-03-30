import Foundation
import NaturalLanguage

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
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        if !isLocked {
            isLocked = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let next = waiters.removeFirst().continuation
        next.resume(returning: ())
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeTranslator {
    private static let lineBreakMarker = "</br>"
    private static let translationGate = FoundationModelsTranslationGate()

    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct StructuredTranslationPayload {
        @Guide(description: "Target language code.")
        var targetLanguage: String
        @Guide(description: "Translated HTML-like text only in the language specified by `targetLanguage`. Keep the same sentence count as the source text. STYLE REQUIREMENT: Preserve all `</br>` tokens exactly as in source (same count, same position even on the line head).")
        var translation: String
    }

    private struct StructuredTranslationResult {
        var translation: String
        var outputBreakTagCount: Int
    }

    static func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)? = nil,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)? = nil
    ) async throws -> [SegmentOutput] {
        try await translationGate.withLock {
            try ensureModelAvailability()

            let segments = input.segments.isEmpty
                ? [TextSegment(index: 0, text: input.originalText, role: .leading)]
                : input.segments

            // Reuse one session per translation request to reduce per-segment setup overhead.
            var session = LanguageModelSession(instructions: instructions(for: input))

            var outputs: [SegmentOutput] = []
            outputs.reserveCapacity(segments.count)

            for segment in segments {
                try Task.checkCancellation()
                let prompt = promptForSegment(segment, input: input)
                var finalResult: StructuredTranslationResult
                var isUnsafeFallback = false
                var shouldSkipSentenceDropRetry = false

                do {
                    finalResult = try await translateStructuredSegmentWithRetry(
                        prompt: prompt,
                        sourceText: segment.text,
                        expectedTargetLanguage: input.targetLanguage,
                        preprocessKind: segment.kind,
                        shouldStreamPartial: segment.role == .leading,
                        using: session,
                        segmentIndex: segment.index,
                        onPartialResult: onPartialResult,
                        onDiagnosticEvent: onDiagnosticEvent
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isUnsafeContentError(error) {
                        isUnsafeFallback = true
                        shouldSkipSentenceDropRetry = true
                        onDiagnosticEvent?(
                            "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): unsafe-no-retry-source-returned (\(error.localizedDescription))"
                        )
                        finalResult = StructuredTranslationResult(
                            translation: sourceFallbackTranslation(
                                sourceText: segment.text
                            ),
                            outputBreakTagCount: 0
                        )
                        session = LanguageModelSession(instructions: instructions(for: input))
                        onDiagnosticEvent?(
                            "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): session-reset-after-unsafe-fallback"
                        )
                    } else if isContextWindowExceededError(error) {
                        onDiagnosticEvent?(
                            "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): context-window-exceeded-refresh-session-and-retry"
                        )
                        session = LanguageModelSession(instructions: instructions(for: input))
                        do {
                            finalResult = try await translateStructuredSegmentWithRetry(
                                prompt: prompt,
                                sourceText: segment.text,
                                expectedTargetLanguage: input.targetLanguage,
                                preprocessKind: segment.kind,
                                shouldStreamPartial: segment.role == .leading,
                                using: session,
                                segmentIndex: segment.index,
                                onPartialResult: onPartialResult,
                                onDiagnosticEvent: onDiagnosticEvent
                            )
                            onDiagnosticEvent?(
                                "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): resumed-after-session-refresh"
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            isUnsafeFallback = isUnsafeContentError(error)
                            shouldSkipSentenceDropRetry = isUnsafeFallback
                            onDiagnosticEvent?(
                                "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): retry-after-session-refresh-failed-source-returned (\(error.localizedDescription))"
                            )
                            finalResult = StructuredTranslationResult(
                                translation: sourceFallbackTranslation(
                                    sourceText: segment.text
                                ),
                                outputBreakTagCount: 0
                            )
                            if isUnsafeFallback {
                                session = LanguageModelSession(instructions: instructions(for: input))
                                onDiagnosticEvent?(
                                    "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): session-reset-after-unsafe-fallback"
                                )
                            }
                        }
                    } else {
                        onDiagnosticEvent?(
                            "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): no-retry-source-returned (\(error.localizedDescription))"
                        )
                        finalResult = StructuredTranslationResult(
                            translation: sourceFallbackTranslation(
                                sourceText: segment.text
                            ),
                            outputBreakTagCount: 0
                        )
                    }
                }

                if isUnsafeFallback {
                    onPartialResult?(segment.index, finalResult.translation)
                    outputs.append(
                        SegmentOutput(
                            segmentIndex: segment.index,
                            sourceText: segment.text,
                            translatedText: finalResult.translation,
                            isUnsafeFallback: true
                        )
                    )
                    continue
                }

                let inputSentenceCount = sentenceCountByNLTokenizer(segment.text)
                var outputSentenceCount = sentenceCountByNLTokenizer(finalResult.translation)
                if !shouldSkipSentenceDropRetry && shouldRetryForSentenceDrop(
                    inputSentenceCount: inputSentenceCount,
                    outputSentenceCount: outputSentenceCount
                ) {
                    onDiagnosticEvent?(
                        "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): sentence-count-drop-detected retry-once"
                    )
                    do {
                        let retrySession = LanguageModelSession(instructions: instructions(for: input))
                        let retryResult = try await translateStructuredSegmentWithRetry(
                            prompt: prompt,
                            sourceText: segment.text,
                            expectedTargetLanguage: input.targetLanguage,
                            preprocessKind: segment.kind,
                            shouldStreamPartial: segment.role == .leading,
                            using: retrySession,
                            segmentIndex: segment.index,
                            onPartialResult: onPartialResult,
                            onDiagnosticEvent: onDiagnosticEvent
                        )
                        finalResult = retryResult
                        outputSentenceCount = sentenceCountByNLTokenizer(finalResult.translation)
                        onDiagnosticEvent?(
                            "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): sentence-count-retry-finished"
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        onDiagnosticEvent?(
                            "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue): sentence-count-retry-failed-keep-first (\(error.localizedDescription))"
                        )
                    }
                }
                let inputBreakCount = lineBreakTagCount(in: sourceTextForPrompt(segment.text))
                let outputBreakCount = finalResult.outputBreakTagCount
                onDiagnosticEvent?(
                    "segment=\(segment.index), preprocess-kind=\(segment.kind.rawValue), sentence-counts={input=\(inputSentenceCount), output=\(outputSentenceCount)}, br-counts={input=\(inputBreakCount), output=\(outputBreakCount)}"
                )

                outputs.append(
                    SegmentOutput(
                        segmentIndex: segment.index,
                        sourceText: segment.text,
                        translatedText: finalResult.translation,
                        isUnsafeFallback: isUnsafeFallback
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
        shouldStreamPartial: Bool,
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
                shouldStreamPartial: shouldStreamPartial,
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
                translation: sourceFallbackTranslation(
                    sourceText: sourceText
                ),
                outputBreakTagCount: 0
            )
        }
    }

    private static func translateSegment(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        shouldStreamPartial: Bool,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> StructuredTranslationResult {
        let payload: StructuredTranslationPayload
        if shouldStreamPartial, onPartialResult != nil {
            payload = try await streamSegmentResponse(
                prompt: prompt,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult
            )
        } else {
            payload = try await session.respond(
                to: prompt,
                generating: StructuredTranslationPayload.self,
                includeSchemaInPrompt: true
            ).content
        }
        if verboseLoggingEnabled {
            let translationForLog = sanitizedForLog(payload.translation) ?? "(empty)"
            onDiagnosticEvent?(
                "verbose model-output segment=\(segmentIndex), payload={targetLanguage=\(payload.targetLanguage), translationChars=\(payload.translation.count), translation=\(translationForLog)}"
            )
        }
        let result = try validateStructuredTranslation(
            payload: payload,
            expectedTargetLanguage: expectedTargetLanguage,
            sourceText: sourceText
        )
        onPartialResult?(segmentIndex, result.translation)
        return result
    }

    private static func streamSegmentResponse(
        prompt: String,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> StructuredTranslationPayload {
        let stream = session.streamResponse(
            to: prompt,
            generating: StructuredTranslationPayload.self,
            includeSchemaInPrompt: true
        )

        var latestSnapshot: LanguageModelSession.ResponseStream<StructuredTranslationPayload>.Snapshot?
        var lastPartialTranslation: String?

        for try await snapshot in stream {
            latestSnapshot = snapshot

            guard let partialTranslation = extractPartialTranslation(
                fromRawJSON: snapshot.rawContent.jsonString
            ) else {
                continue
            }

            let normalizedPartial = normalizeBreakTagsToNewline(in: partialTranslation)
            guard normalizedPartial != lastPartialTranslation else { continue }
            lastPartialTranslation = normalizedPartial
            onPartialResult?(segmentIndex, normalizedPartial)
        }

        guard let latestSnapshot else {
            throw FoundationModelsStructuredOutputError.invalidFormat(content: "(empty stream)")
        }

        return try StructuredTranslationPayload(latestSnapshot.rawContent)
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
        Keep the same number of sentences as the source text.
        Treat the source as HTML-like text.
        STRICT REQUIREMENT: Preserve all `</br>` tokens exactly as in source (same count and order). Do not replace, remove, or add `</br>`.
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
        lines.append("Target language code: \(input.targetLanguage)")
        lines.append("The source is HTML-like text.")
        lines.append("STYLE REQUIREMENT: Preserve all `</br>` tokens exactly as in source (same count and order).")
        lines.append("Translate every sentence in the source text; do not omit any part.")
        lines.append("Keep the same number of sentences as the source text.")
        lines.append("Important: translation must be translated source text only.")

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
        lines.append("Source text:")
        lines.append(sourceTextForPrompt(segment.text))
        return lines.joined(separator: "\n")
    }

    private static func promptForSensitiveContentSegment(_ segment: TextSegment, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Task: direct translation only.")
        lines.append("Source language: \(input.sourceLanguage)")
        lines.append("Target language: \(input.targetLanguage)")

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("")
            lines.append("Protected tokens (do not translate): \(protectedList)")
        }

        lines.append("")
        lines.append("The source is HTML-like text.")
        lines.append("STRICT REQUIREMENT: Preserve all `</br>` tokens exactly as in source (same count and order). Do not replace, remove, or add `</br>`.")
        lines.append("Translate every sentence in the source text; do not omit any part.")
        lines.append("Keep the same number of sentences as the source text.")
        lines.append("Important: translation must be translated source text only.")
        lines.append("")
        lines.append("Source text:")
        lines.append(sourceTextForPrompt(segment.text))
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
        - source is HTML-like text
        - STRICT REQUIREMENT: preserve all `</br>` tokens exactly as in source (same count and order)
        - do not replace, remove, or add `</br>`
        - translate every sentence in the source text; do not omit any part
        - keep the same number of sentences as the source text; do not merge, split, summarize, or drop sentences
        - output translation only, no notes or placeholders
        - translation must not be the kind label (for example: heading, general, dialogue, ui-labels, lists, codes_or_path)

        Source text:
        \(sourceTextForPrompt(sourceText))
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
                shouldStreamPartial: false,
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
                translation: sourceFallbackTranslation(
                    sourceText: sourceText
                ),
                outputBreakTagCount: 0
            )
        }
    }

    private static func validateStructuredTranslation(
        payload: StructuredTranslationPayload,
        expectedTargetLanguage: String,
        sourceText: String
    ) throws -> StructuredTranslationResult {
        let actualCode = normalizedLanguageCode(payload.targetLanguage)
        let expectedCode = normalizedLanguageCode(expectedTargetLanguage)
        guard actualCode == expectedCode else {
            throw FoundationModelsStructuredOutputError.targetLanguageMismatch(
                expected: expectedCode,
                actual: actualCode
            )
        }
        let trimmed = payload.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FoundationModelsStructuredOutputError.emptyTranslation
        }
        let sanitized = sanitizeStructuredLeakage(in: trimmed)
        guard !isPlaceholderTranslation(sanitized) else {
            throw FoundationModelsStructuredOutputError.placeholderTranslation(value: sanitized)
        }
        let sourcePromptText = sourceTextForPrompt(sourceText)
        let completed = appendMissingTrailingBreakMarkers(
            from: sourcePromptText,
            to: sanitized
        )
        let outputBreakTagCount = lineBreakTagCount(in: completed)
        let normalizedTranslation = normalizeBreakTagsToNewline(in: completed)
        return StructuredTranslationResult(
            translation: normalizedTranslation,
            outputBreakTagCount: outputBreakTagCount
        )
    }

    private static func sourceTextForPrompt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: lineBreakMarker)
    }

    private static func sentenceCountByNLTokenizer(_ text: String) -> Int {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = normalized

        var count = 0
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { _, _ in
            count += 1
            return true
        }
        return max(1, count)
    }

    private static func shouldRetryForSentenceDrop(
        inputSentenceCount: Int,
        outputSentenceCount: Int
    ) -> Bool {
        guard inputSentenceCount > 0 else { return false }
        if inputSentenceCount == 2 && outputSentenceCount == 1 {
            return false
        }
        return outputSentenceCount * 2 < inputSentenceCount
    }

    private static func normalizeBreakTagsToNewline(in text: String) -> String {
        var normalized = text
        normalized = replaceRegex(
            pattern: #"(?i)</\s*p\s*>\s*<\s*p(?:\s+[^>]*)?\s*>"#,
            in: normalized,
            with: "\n"
        )
        normalized = replaceRegex(
            pattern: #"(?i)</\s*p\s*>"#,
            in: normalized,
            with: "\n"
        )
        normalized = replaceRegex(
            pattern: #"(?i)<\s*p(?:\s+[^>]*)?\s*>"#,
            in: normalized,
            with: ""
        )
        normalized = replaceRegex(
            pattern: #"(?i)<\s*/?\s*br(?:\s*/)?\s*>"#,
            in: normalized,
            with: "\n"
        )
        return normalized
    }

    private static func lineBreakTagCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let pattern = #"(?i)(<\s*/?\s*br(?:\s*/)?\s*>|</\s*p\s*>\s*<\s*p(?:\s+[^>]*)?\s*>|</\s*p\s*>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: fullRange)
    }

    private static func appendMissingTrailingBreakMarkers(from sourceText: String, to outputText: String) -> String {
        let requiredTrailingBreaks = trailingBreakMarkerCount(in: sourceText)
        guard requiredTrailingBreaks > 0 else { return outputText }

        let actualTrailingBreaks = trailingBreakMarkerCount(in: outputText)
        guard actualTrailingBreaks < requiredTrailingBreaks else { return outputText }

        return outputText + String(repeating: lineBreakMarker, count: requiredTrailingBreaks - actualTrailingBreaks)
    }

    private static func trailingBreakMarkerCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 0
        var remainder = text[...]
        while remainder.hasSuffix(lineBreakMarker) {
            count += 1
            remainder = remainder.dropLast(lineBreakMarker.count)
        }
        return count
    }

    private static func replaceRegex(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: replacement)
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

    private static func sanitizeStructuredLeakage(in text: String) -> String {
        // Guard against occasional structured-output collapse where extra JSON/meta text
        // leaks into `translation` (for example: ..."}Author2024-...).
        let leakagePattern = #"(?:\"|”)?\}\s*[\p{L}\p{N}]"#
        guard let leakageRange = text.range(of: leakagePattern, options: .regularExpression) else {
            return text
        }

        let head = String(text[..<leakageRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"”"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head
    }

    private static func normalizedLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
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

    private static func isUnsafeContentError(_ error: Error) -> Bool {
        var queue: [NSError] = [error as NSError]
        var visited = Set<String>()

        while let current = queue.popLast() {
            let key = "\(current.domain)#\(current.code)#\(current.localizedDescription)"
            if visited.contains(key) {
                continue
            }
            visited.insert(key)

            if isUnsafeSignal(current) {
                return true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                queue.append(contentsOf: detailed)
            }
            if let multiple = current.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] {
                queue.append(contentsOf: multiple)
            }
        }

        return false
    }

    private static func isUnsafeSignal(_ error: NSError) -> Bool {
        let domain = error.domain.lowercased()
        let description = error.localizedDescription.lowercased()
        let failureReason = (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "")
            .lowercased()
        let recoverySuggestion = (error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String ?? "")
            .lowercased()
        let combined = [description, failureReason, recoverySuggestion].joined(separator: " ")

        // Foundation Models generation errors may surface as numeric codes with little text.
        if domain.contains("languagemodelsession.generationerror"), error.code == 2 {
            return true
        }

        return combined.contains("unsafe")
            || combined.contains("safety")
            || combined.contains("policy")
            || combined.contains("content filter")
            || combined.contains("prohibited")
            || combined.contains("restricted")
            || combined.contains("disallowed")
            || combined.contains("moderation")
    }

    private static func sourceFallbackTranslation(sourceText: String) -> String {
        sourceText
    }

    private static func isContextWindowExceededError(_ error: Error) -> Bool {
        let localized = error.localizedDescription.lowercased()
        return localized.contains("context window")
            || localized.contains("exceeded model context window size")
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
    case placeholderTranslation(value: String)

    var isRetryable: Bool {
        switch self {
        case .invalidFormat:
            return true
        case .targetLanguageMismatch:
            return true
        case .emptyTranslation:
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
