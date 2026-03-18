import Testing
@testable import PreBabelLens

struct EnginePolicyTests {
    @Test
    func fixedPolicyAlwaysReturnsConfiguredEngine() {
        let engine = StubCoreMLTranslationEngine()
        let policy = FixedTranslationEnginePolicy(engine: engine)

        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "Hello",
            glossary: []
        )

        let selected = policy.resolveEngine(for: request)
        #expect(selected.name == "coreml-stub")
    }
}
