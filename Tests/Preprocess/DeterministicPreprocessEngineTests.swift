import Testing
@testable import ChampollionDeckApp

struct DeterministicPreprocessEngineTests {
    @Test
    func sentenceSegmentationSplitsOnPunctuation() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "Hello world. Next sentence!",
            glossary: []
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 2)
        #expect(result.input.segments[0].text == "Hello world")
        #expect(result.input.segments[1].text == "Next sentence")
    }

    @Test
    func protectedTokenExtractionFindsUrlAndCodeAndNumber() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "See https://example.com and run `swift test` 42 times.",
            glossary: []
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.protectedTokens.contains(where: { $0.kind == .url }))
        #expect(result.input.protectedTokens.contains(where: { $0.kind == .codeSnippet }))
        #expect(result.input.protectedTokens.contains(where: { $0.kind == .number && $0.value == "42" }))
    }

    @Test
    func glossaryMatcherCreatesMatches() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "Open the Settings panel.",
            glossary: [GlossaryEntry(source: "Settings", target: "設定")]
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.glossaryMatches.count == 1)
        #expect(result.input.glossaryMatches[0].source == "Settings")
        #expect(result.input.glossaryMatches[0].target == "設定")
    }
}
