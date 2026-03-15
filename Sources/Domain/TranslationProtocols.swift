import Foundation

protocol PreprocessEngine: Sendable {
    var name: String { get }
    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace])
}

protocol TranslationEngine: Sendable {
    var name: String { get }
    func translate(_ input: TranslationInput) async throws -> [SegmentOutput]
}

protocol TranslationEnginePolicy: Sendable {
    func resolveEngine(for request: TranslationRequest) -> TranslationEngine
}
