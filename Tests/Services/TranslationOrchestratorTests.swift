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
        #expect(output.segmentOutputs.contains(where: \.isUnsafeFallback))
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
