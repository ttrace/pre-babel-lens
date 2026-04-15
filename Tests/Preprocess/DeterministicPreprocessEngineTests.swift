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
        #expect(result.input.segments[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == sentenceA)
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
    func sentenceSegmentationDoesNotCreateWhitespaceOnlySegment() {
        let text = """
        “When the Pope says God is never on the side of those who wield the sword, there is more than a thousand-year tradition of Just War Theory in Christianity.”

        “Just as I have to be careful when speaking about public policy as Vice President, the Pope should be very careful when speaking about theology.”
        """
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: text,
            glossary: [],
            experimentMode: .segmented
        )

        let result = DeterministicPreprocessEngine().analyze(request)
        let reconstructed = reconstruct(
            segments: result.input.segments,
            joinersAfter: result.input.segmentJoinersAfter
        )

        #expect(result.input.segments.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        #expect(reconstructed == text)
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
PixVerse
@PixVerse_
fuck fuck fuck Ad９ag4
Powg47yhw
er-Up Wk Day 2. pping moe f９r builders.

Such a mission could expose U.S. personnel to an array of threats, including Iranian drones and missiles, ground fire and improvised explosives. It was unclear Saturday whether Trump would approve all, some or none of the Pentagon’s plans.

Follow Trump’s second term
Follow
The Trump administration in recent days has vacillated between declaring that the war is winding down and threatening to amplify it. While the president has signaled a desire to negotiate an end to the conflict, White House press secretary Karoline Leavitt warned Tuesday that if the regime in Tehran does not end its nuclear ambitions and cease its threats against the United States and its allies, Trump is “prepared to unleash hell” against them.
"""

private let exceededContextWindowTranslationText: String = """
The other day, I finally submitted the iPhone version of Pre-Babel Lens—a local translation app I’ve been building using Apple Intelligence’s on-device LLM, Foundation Models—to App Store Connect. As of 21:55, the first build has just entered review. If all goes well, it should be available on the App Store by tomorrow.

Pre-Babel Lens has a somewhat classic translation app interface. The source text goes in the top field, and when you press the translate button, the translated text appears in the bottom field.

The source field functions as an editor, so you can type directly into it, paste text, or send text via the share feature from other apps. You can also share files that allow text extraction and load their contents into the app (I plan to add this to the Mac version as well).

The biggest feature is that it uses an on-device LLM for translation, so it works even without an internet connection. Whether you’re on a plane, on a ferry out at sea, or passing through long tunnels on the Tokaido Shinkansen, you can quickly grasp the contents of emails or documents you receive. I haven’t taken it abroad yet, but it should work reliably even in countries where internet access is restricted. Since no data is transmitted, you can safely translate confidential documents.

Using services tied closely to your identity, like Google Translate, and repeatedly feeding them documents that make you wonder “Is this really safe?” can feel a bit unsettling. But with Pre-Babel Lens, you don’t have to worry. Not a single sentence leaves your device. That’s exactly why I built this app.

That said, it’s not without limitations. Apple Intelligence has fairly strict policies.

For example, it won’t translate content related to minors’ actions. It also refuses to translate content involving violence, abuse, or discrimination. Even in political content, expressions that demean specific nations are not translated. Whether it’s Israel, China, Russia, the United States, or Japan, the model tends to avoid translating mocking or insulting expressions based on national attributes.

These restrictions are deeply embedded in the model itself, so there’s nothing app developers can do about them. In some cases, removing certain words allows translation to proceed, but the current version doesn’t attempt that level of inference. These constraints also seem to place a significant burden on Apple Intelligence itself—when triggered, processing slows down, and issues like dropped tags can occur.

Interestingly, despite being fundamentally different from humans, it almost feels human in how it “gets tired” under stressful tasks. That said, it’s not something to laugh off. In the released app, when a restriction is triggered, the translation session is restarted to prevent performance degradation.

If you’re curious, you might want to experiment and see what kinds of limitations exist. Since the app doesn’t communicate externally, there’s no risk of getting banned from a service for trying. From what I’ve observed, the restrictions are determined not at the word level but based on context. Impressive for an LLM—but inconvenient for a translation app. To address this, Pre-Babel Lens includes a feature that highlights and reinserts any source text that couldn’t be translated.

These restrictions frequently come up with international news about conflicts. Of course, if you’re in an environment where you can access real-time news online, it’s probably better to use standard translation tools or cloud-based AI. I’ll continue exploring ways to work around these limitations.

Apple’s OS also includes a dedicated Translation Framework, used in browser translation and the built-in Translate app. Since it uses probabilistic models, it can handle most content—certainly more than rule-based translation systems from around 2010—but it doesn’t consider nuance and context as deeply as large language models. Still, one idea is to fall back to the Translation Framework only for the parts that fail. That’s something to explore going forward.

Continuing with limitations: Apple Intelligence currently supports only 15 languages. These are Danish, German, English, Spanish, French, Italian, Japanese, Korean, Norwegian, Dutch, Portuguese, Swedish, Turkish, Vietnamese, and Chinese. There’s nothing I can do to expand this list. Personally, I’d love to see support for languages like Russian, Arabic, Thai, Bengali, and Hindi.

This is actually my first time building an iOS app entirely on my own. It’s also my first time using Swift (despite having written that “Hello, World!” before). I developed it using Codex, but honestly, setting up the tools and development environment was far more challenging than writing the code itself.

Submitting to the App Store is also completely different from how it was 15 years ago. Some things have become more convenient, but the toolchain—like code signing—feels increasingly complex, almost to the point where you need a specialist. TestFlight, which used to feel like a shady third-party sideloading tool, has become a fully legitimate platform. It’s still a lot of work, though. That said, with Codex (and probably tools like Claude Code), even these procedural hurdles can be handled. It really feels like the world is changing.

While I was writing this blog post, the version I initially submitted passed review (!). By the time you read this, the release version will likely already be available on the App Store. Pre-Babel Lens is available as a free Mac version and a paid iPhone version (150 yen). The source code is also available on GitHub, so if you’re interested in building it yourself, feel free to fork it and give it a try.
"""
