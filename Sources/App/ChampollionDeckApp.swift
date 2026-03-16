import SwiftUI

@main
struct ChampollionDeckApp: App {
    private let viewModel: TranslationViewModel

    init() {
        let preprocess = DeterministicPreprocessEngine()
        let translationEngine = FoundationModelsTranslationEngine()
        let policy = FixedTranslationEnginePolicy(engine: translationEngine)

        self.viewModel = TranslationViewModel(
            orchestrator: TranslationOrchestrator(
                preprocessEngine: preprocess,
                enginePolicy: policy
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            TranslationView(viewModel: viewModel)
        }
    }
}
