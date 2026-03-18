import Foundation

protocol PreprocessEngine: Sendable {
    var name: String { get }
    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace])
}

protocol TranslationEngine: Sendable {
    var name: String { get }
    func translate(_ input: TranslationInput) async throws -> [SegmentOutput]
    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput]
}

protocol TranslationEnginePolicy: Sendable {
    func resolveEngine(for request: TranslationRequest) -> TranslationEngine
}

extension TranslationEngine {
    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput] {
        let outputs = try await translate(input)
        for output in outputs {
            onPartialResult?(output.segmentIndex, output.translatedText)
        }
        return outputs
    }
}
