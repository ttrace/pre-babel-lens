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

    func translate(_ request: TranslationRequest) async throws -> TranslationOutput {
        let preprocessResult = preprocessEngine.analyze(request)
        let input = preprocessResult.input
        let engine = enginePolicy.resolveEngine(for: request)

        if !input.isDetectedLanguageSupportedByAppleIntelligence,
           let languageCode = input.detectedLanguageCode {
            throw TranslationPipelineError.unsupportedAppleIntelligenceLanguage(
                detectedLanguageCode: languageCode
            )
        }

        let segmentOutputs = try await engine.translate(input)
            .sorted { $0.segmentIndex < $1.segmentIndex }

        let translatedText = segmentOutputs
            .map(\.translatedText)
            .joined(separator: " ")

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
}
