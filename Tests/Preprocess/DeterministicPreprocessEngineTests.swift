import Testing
@testable import PreBabelLens

struct DeterministicPreprocessEngineTests {
    @Test
    func sentenceSegmentationGroupsSentencesByCharacterThreshold() {
        let sentenceA = String(repeating: "A", count: 130) + "."
        let sentenceB = String(repeating: "B", count: 130) + "."
        let sentenceC = "Tail."
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "\(sentenceA) \(sentenceB) \(sentenceC)",
            glossary: []
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 2)
        #expect(result.input.segments[0].text == sentenceA)
        #expect(result.input.segments[1].text.contains(sentenceB))
        #expect(result.input.segments[1].text.contains(sentenceC))
    }

    @Test
    func sentenceSegmentationPreservesNewlineAndIndentInsideSegment() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: """
            Line one.

                Line two.
            Line three.
            """,
            glossary: []
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.count == 1)
        #expect(result.input.segmentJoinersAfter.count == 1)
        #expect(result.input.segments[0].text.contains("\n\n    Line two."))
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
    func firstSegmentIsMarkedLeadingForFutureSpecialHandling() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: "First sentence. Second sentence. Third sentence.",
            glossary: [],
            experimentMode: .segmented
        )

        let result = DeterministicPreprocessEngine().analyze(request)

        #expect(result.input.segments.first?.role == .leading)
        #expect(result.input.segments.dropFirst().allSatisfy { $0.role == .regular })
    }

    @Test
    func sentenceSegmentationRoundTripsUnsafeSampleWithoutLosingParagraphBreaks() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: unsafeSampleText,
            glossary: [],
            experimentMode: .segmented
        )

        let result = DeterministicPreprocessEngine().analyze(request)
        let reconstructed = reconstruct(
            segments: result.input.segments,
            joinersAfter: result.input.segmentJoinersAfter
        )

        #expect(reconstructed == unsafeSampleText)
    }

    @Test
    func sentenceSegmentationRoundTripsTrailingBreakSampleWithoutLosingParagraphBreaks() {
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: trailingBreakSampleText,
            glossary: [],
            experimentMode: .segmented
        )

        let result = DeterministicPreprocessEngine().analyze(request)
        let reconstructed = reconstruct(
            segments: result.input.segments,
            joinersAfter: result.input.segmentJoinersAfter
        )

        #expect(reconstructed == trailingBreakSampleText)
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

    private func reconstruct(segments: [TextSegment], joinersAfter: [String]) -> String {
        guard !segments.isEmpty else { return "" }
        return segments.enumerated().map { index, segment in
            let joiner = index < joinersAfter.count ? joinersAfter[index] : ""
            return segment.text + joiner
        }
        .joined()
    }
}

private let unsafeSampleText = """
Today I went to the hospital because of my condition... but the news was devastating 💔
I never imagined I'd reach this point.

The doctors told me that blood clots have started forming in my leg, and that the situation has become very serious, with complications that could lead to amputation, God forbid.

They asked me to buy medication urgently to prevent my condition from worsening, but unfortunately, the treatment costs over $500, an amount I simply cannot afford.

If I don't start treatment immediately, I might lose my leg... and maybe my whole life will change 😢. I also need urgent surgery to save me before it's too late.

I returned to the tent devastated... I sat crying in front of my family, helpless to do anything.
"""

private let trailingBreakSampleText = """
Such a mission could expose U.S. personnel to an array of threats, including Iranian drones and missiles, ground fire and improvised explosives. It was unclear Saturday whether Trump would approve all, some or none of the Pentagon’s plans.

Follow Trump’s second term
Follow
The Trump administration in recent days has vacillated between declaring that the war is winding down and threatening to amplify it. While the president has signaled a desire to negotiate an end to the conflict, White House press secretary Karoline Leavitt warned Tuesday that if the regime in Tehran does not end its nuclear ambitions and cease its threats against the United States and its allies, Trump is “prepared to unleash hell” against them.
"""
