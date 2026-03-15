import Foundation

struct FixedTranslationEnginePolicy: TranslationEnginePolicy {
    private let engine: TranslationEngine

    init(engine: TranslationEngine) {
        self.engine = engine
    }

    func resolveEngine(for request: TranslationRequest) -> TranslationEngine {
        engine
    }
}
