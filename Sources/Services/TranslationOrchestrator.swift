import Foundation
import NaturalLanguage

enum TranslationPipelineError: LocalizedError {
    case unsupportedAppleIntelligenceLanguage(detectedLanguageCode: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedAppleIntelligenceLanguage(let languageCode):
            return "\(languageCode) is not supported by Apple Intelligence"
        }
    }

    var detectedLanguageCode: String? {
        switch self {
        case .unsupportedAppleIntelligenceLanguage(let languageCode):
            return languageCode
        }
    }
}

struct TranslationOrchestrator: Sendable {
    let preprocessEngine: PreprocessEngine
    let enginePolicy: TranslationEnginePolicy

    func translate(
        _ request: TranslationRequest,
        onSessionStarted: (@Sendable (_ segmentCount: Int, _ tokenizerSentenceCount: Int, _ detectedLanguageCode: String, _ targetLanguage: String, _ kindSummary: String) -> Void)? = nil,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)? = nil,
        onPartialSegmentResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String, _ joinersAfter: [String]) -> Void)? = nil,
        onSessionFinished: (@Sendable () -> Void)? = nil
    ) async throws -> TranslationOutput {
        let preprocessResult = preprocessEngine.analyze(request)
        let input = preprocessResult.input
        let effectiveSourceLanguage = input.detectedLanguageCode ?? input.sourceLanguage
        let isSameLanguagePair = isSameLanguagePair(
            sourceLanguage: effectiveSourceLanguage,
            targetLanguage: input.targetLanguage
        )

        if isSameLanguagePair {
            onDiagnosticEvent?(
                "engine=fallback-same-language source=\(effectiveSourceLanguage) target=\(input.targetLanguage)"
            )

            let segments = input.segments.isEmpty
                ? [TextSegment(index: 0, text: input.originalText, role: .leading)]
                : input.segments
            let segmentOutputs = segments.map { segment in
                SegmentOutput(
                    segmentIndex: segment.index,
                    sourceText: segment.text,
                    translatedText: segment.text,
                    isUnsafeFallback: true,
                    isUnsafeRecoveredByTranslationFramework: false
                )
            }
            for output in segmentOutputs {
                onPartialSegmentResult?(output.segmentIndex, output.translatedText, input.segmentJoinersAfter)
            }

            let traces = preprocessResult.traces + [
                PreprocessTrace(
                    step: "same-language-fallback",
                    summary: "source=\(effectiveSourceLanguage), target=\(input.targetLanguage)"
                )
            ]

            return TranslationOutput(
                translatedText: input.originalText,
                containsUnsafeFallback: true,
                segmentOutputs: segmentOutputs,
                analysis: TranslationAnalysis(
                    request: request,
                    traces: traces,
                    input: input,
                    engineName: "same-language-fallback"
                )
            )
        }

        let engine = enginePolicy.resolveEngine(for: request)
        let requiresAppleIntelligenceLanguageSupport = engine.name.contains("foundation-models")

        if requiresAppleIntelligenceLanguageSupport,
           !input.isDetectedLanguageSupportedByAppleIntelligence,
           let languageCode = input.detectedLanguageCode {
            throw TranslationPipelineError.unsupportedAppleIntelligenceLanguage(
                detectedLanguageCode: languageCode
            )
        }

        let kindSummary = summarizeKinds(input.segments)
        let tokenizerSentenceCount = sentenceCountByNLTokenizer(for: input.originalText)
        onSessionStarted?(
            input.segments.count,
            tokenizerSentenceCount,
            input.detectedLanguageCode ?? input.sourceLanguage,
            request.targetLanguage,
            kindSummary
        )
        defer { onSessionFinished?() }

        let segmentOutputs: [SegmentOutput]
        if let diagnosticEngine = engine as? any DiagnosticCapableTranslationEngine {
            segmentOutputs = try await diagnosticEngine.translate(
                input,
                onPartialResult: { segmentIndex, partialTranslation in
                    onPartialSegmentResult?(segmentIndex, partialTranslation, input.segmentJoinersAfter)
                },
                onDiagnosticEvent: onDiagnosticEvent
            )
            .sorted { $0.segmentIndex < $1.segmentIndex }
        } else {
            segmentOutputs = try await engine.translate(
                input,
                onPartialResult: { segmentIndex, partialTranslation in
                    onPartialSegmentResult?(segmentIndex, partialTranslation, input.segmentJoinersAfter)
                }
            )
            .sorted { $0.segmentIndex < $1.segmentIndex }
        }

        let translatedText = reconstructTranslatedText(
            segmentTranslationsByIndex: Dictionary(
                uniqueKeysWithValues: segmentOutputs.map { ($0.segmentIndex, $0.translatedText) }
            ),
            joinersAfter: input.segmentJoinersAfter
        )

        return TranslationOutput(
            translatedText: translatedText,
            containsUnsafeFallback: segmentOutputs.contains(where: \.isUnsafeFallback),
            segmentOutputs: segmentOutputs,
            analysis: TranslationAnalysis(
                request: request,
                traces: preprocessResult.traces,
                input: input,
                engineName: engine.name
            )
        )
    }

    private func reconstructTranslatedText(
        segmentTranslationsByIndex: [Int: String],
        joinersAfter: [String]
    ) -> String {
        guard !segmentTranslationsByIndex.isEmpty else { return "" }
        let orderedTranslations = segmentTranslationsByIndex
            .sorted { $0.key < $1.key }
            .map(\.value)

        if joinersAfter.count >= orderedTranslations.count {
            return orderedTranslations.enumerated().map { index, translatedText in
                translatedText + normalizedJoiner(
                    joinersAfter[index],
                    forTranslatedSegment: translatedText
                )
            }.joined()
        }

        return orderedTranslations
            .joined(separator: " ")
    }

    private func normalizedJoiner(_ joiner: String, forTranslatedSegment translatedText: String) -> String {
        guard !joiner.isEmpty else { return joiner }
        guard let last = translatedText.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return joiner
        }

        let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？"]
        guard terminalPunctuation.contains(last) else { return joiner }

        var scalars = Array(joiner)
        while let first = scalars.first, terminalPunctuation.contains(first) {
            scalars.removeFirst()
        }
        return String(scalars)
    }

    private func summarizeKinds(_ segments: [TextSegment]) -> String {
        guard !segments.isEmpty else { return "(none)" }
        let grouped = Dictionary(grouping: segments, by: \.kind)
        return SegmentKind.allCases.compactMap { kind in
            guard let count = grouped[kind]?.count else { return nil }
            return "\(kind.rawValue)=\(count)"
        }
        .joined(separator: ", ")
    }

    private func sentenceCountByNLTokenizer(for text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = trimmed

        var count = 0
        tokenizer.enumerateTokens(in: trimmed.startIndex..<trimmed.endIndex) { _, _ in
            count += 1
            return true
        }

        return max(1, count)
    }

    private func isSameLanguagePair(sourceLanguage: String, targetLanguage: String) -> Bool {
        let source = normalizedLanguageIdentifier(sourceLanguage)
        let target = normalizedLanguageIdentifier(targetLanguage)
        guard !source.isEmpty, !target.isEmpty, source != "und", target != "und" else {
            return false
        }
        return source == target
    }

    private func normalizedLanguageIdentifier(_ code: String) -> String {
        code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}
