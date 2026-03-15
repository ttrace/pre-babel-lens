import Foundation

struct IdentityTranslationEngine: TranslationEngine {
    let name: String = "identity-placeholder"

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        return segments.map { segment in
            SegmentOutput(
                segmentIndex: segment.index,
                sourceText: segment.text,
                translatedText: segment.text
            )
        }
    }
}

struct StubFoundationModelsTranslationEngine: TranslationEngine {
    let name: String = "foundation-models-stub"

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        return segments.map { segment in
            SegmentOutput(
                segmentIndex: segment.index,
                sourceText: segment.text,
                translatedText: "[FM: \\(input.targetLanguage)] \\(segment.text)"
            )
        }
    }
}

struct StubCoreMLTranslationEngine: TranslationEngine {
    let name: String = "coreml-stub"

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        return segments.map { segment in
            SegmentOutput(
                segmentIndex: segment.index,
                sourceText: segment.text,
                translatedText: "[CoreML: \\(input.targetLanguage)] \\(segment.text)"
            )
        }
    }
}
