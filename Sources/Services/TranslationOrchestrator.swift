import Foundation

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
        onPartialSegmentResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String, _ joinersAfter: [String]) -> Void)? = nil
    ) async throws -> TranslationOutput {
        let preprocessResult = preprocessEngine.analyze(request)
        let input = preprocessResult.input
        let engine = enginePolicy.resolveEngine(for: request)

        if !input.isDetectedLanguageSupportedByAppleIntelligence,
           let languageCode = input.detectedLanguageCode {
            throw TranslationPipelineError.unsupportedAppleIntelligenceLanguage(
                detectedLanguageCode: languageCode
            )
        }

        let segmentOutputs = try await engine.translate(
            input,
            onPartialResult: { segmentIndex, partialTranslation in
                onPartialSegmentResult?(segmentIndex, partialTranslation, input.segmentJoinersAfter)
            }
        )
            .sorted { $0.segmentIndex < $1.segmentIndex }

        let translatedText = reconstructTranslatedText(
            segmentTranslationsByIndex: Dictionary(
                uniqueKeysWithValues: segmentOutputs.map { ($0.segmentIndex, $0.translatedText) }
            ),
            joinersAfter: input.segmentJoinersAfter
        )

        return TranslationOutput(
            translatedText: translatedText,
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
}
