import Foundation
import Testing
@testable import PreBabelLens

struct TranslationOrchestratorTests {
    @Test
    func unsafeFallbackSampleReconstructsOriginalParagraphBoundaries() async throws {
        let engine = UnsafeSampleEchoEngine()
        let orchestrator = TranslationOrchestrator(
            preprocessEngine: DeterministicPreprocessEngine(),
            enginePolicy: FixedTranslationEnginePolicy(engine: engine)
        )
        let request = TranslationRequest(
            sourceLanguage: "en",
            targetLanguage: "ja",
            text: unsafeSampleText,
            glossary: [],
            experimentMode: .segmented
        )

        let output = try await orchestrator.translate(request)

        #expect(output.translatedText == unsafeSampleText)
        #expect(output.containsUnsafeFallback == true)
        #expect(output.segmentOutputs.contains(where: { $0.isUnsafeFallback }))
    }
}

private struct UnsafeSampleEchoEngine: TranslationEngine {
    let name: String = "unsafe-sample-echo"

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        return segments.map { segment in
            SegmentOutput(
                segmentIndex: segment.index,
                sourceText: segment.text,
                translatedText: segment.text,
                isUnsafeFallback: segment.text.contains("blood clots")
            )
        }
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
