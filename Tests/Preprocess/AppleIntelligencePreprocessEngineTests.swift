import Testing
@testable import PreBabelLens

struct AppleIntelligencePreprocessEngineTests {
    @Test
    func heuristicLanguageDetectionFindsEnglishForSenseiParagraph() {
        let text = """
        Taku-sensei, Namba-sensei, thank you for creating such an excellent opportunity.

        Hearing two introductions to Indian science fiction by Namba-sensei and Sami Ahmad Khan was a great asset.

        I was impressed by Lavanya Lakshminarayan's attitude of sharing her own work and her earnest attitude towards questions.

        I was deeply impressed by Ebihara's introduction to Japanese science fiction. I nodded in agreement many times, wondering if there are such perspectives.

        And thank you, Samit Basu, for having such a fun time.

        Thanks to all of you, I'm looking forward to seeing Indian science fiction again.

        See you again.
        """

        let request = TranslationRequest(
            sourceLanguage: "und",
            targetLanguage: "ja",
            text: text,
            glossary: []
        )

        let result = AppleIntelligencePreprocessEngine().analyze(request)

        #expect(result.input.detectedLanguageCode == "en")
        #expect(result.input.isDetectedLanguageSupportedByAppleIntelligence == true)
        #expect(result.traces.contains(where: { $0.step == "ai-heuristic-language-detection" }))
    }

    @Test
    func compositePreprocessPromotesAiLanguageWhenDeterministicIsUnd() {
        let text = """
        Taku-sensei, Namba-sensei, thank you for creating such an excellent opportunity.
        See you again.
        """

        let request = TranslationRequest(
            sourceLanguage: "und",
            targetLanguage: "ja",
            text: text,
            glossary: []
        )

        let engine = CompositePreprocessEngine(
            deterministicEngine: DeterministicPreprocessEngine(),
            appleIntelligenceEngine: AppleIntelligencePreprocessEngine()
        )

        let result = engine.analyze(request)

        #expect(result.input.detectedLanguageCode == "en")
        #expect(result.input.sourceLanguage == "en")
        #expect(result.input.isDetectedLanguageSupportedByAppleIntelligence == true)
        #expect(result.traces.contains(where: { $0.step == "ai-heuristic-language-merge" }))
    }
}
