import Testing
@testable import PreBabelLens

struct DeterministicPreprocessEngineTests {
    @Test
    func sentenceSegmentationUsesExplicitBoundariesOnly() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "This is a first sentence. Still same context.\n\nThis starts a new explicit block.",
            glossary: []
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 2)
        #expect(result.input.segments[0].text.contains("Still same context."))
        #expect(result.input.segments[1].text == "This starts a new explicit block.")
    }

    @Test
    func sentenceSegmentationSplitsDialogueLines() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: """
            Narrative lead.
            - Speaker A: Hello.
            - Speaker B: Hi.
            """,
            glossary: []
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count >= 2)
        #expect(result.input.segments.contains(where: { $0.text.contains("Speaker A: Hello.") }))
        #expect(result.input.segments.contains(where: { $0.text.contains("Speaker B: Hi.") }))
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

    @Test
    func rawInputModeDisablesSegmentationAndOptionalEnhancements() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "First sentence. Second sentence.",
            glossary: [GlossaryEntry(source: "First", target: "最初")],
            experimentMode: .rawInput
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 1)
        #expect(result.input.protectedTokens.isEmpty)
        #expect(result.input.glossaryMatches.isEmpty)
    }

    @Test
    func segmentedGlossaryModeAppliesGlossaryWithoutProtectedExtraction() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "Settings and https://example.com.",
            glossary: [GlossaryEntry(source: "Settings", target: "設定")],
            experimentMode: .segmentedGlossary
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 1)
        #expect(result.input.glossaryMatches.count == 1)
        #expect(result.input.protectedTokens.isEmpty)
    }

    @Test
    func sentenceSegmentationPreservesNewlineInJoiners() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "Line one.\nLine two.",
            glossary: [],
            experimentMode: .segmented
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 1)
        #expect(result.input.segmentJoinersAfter.count == 1)
    }

    @Test
    func languageDetectionForSenseiParagraphIsStableAcrossToolchains() {
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

        let result = DeterministicPreprocessEngine().analyze(request)

        let detected = result.input.detectedLanguageCode ?? "und"
        #expect(["und", "en"].contains(detected))
        if detected == "en" {
            #expect(result.input.isDetectedLanguageSupportedByAppleIntelligence == true)
        }
    }
}
