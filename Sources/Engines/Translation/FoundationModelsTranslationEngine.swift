import Foundation

struct FoundationModelsTranslationEngine: TranslationEngine {
    var name: String {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return "foundation-models"
        }
        return "foundation-models-fallback(os-unavailable)"
#else
        return "foundation-models-fallback(module-unavailable)"
#endif
    }
    private let fallbackEngine: any TranslationEngine

    init(fallbackEngine: any TranslationEngine = StubFoundationModelsTranslationEngine()) {
        self.fallbackEngine = fallbackEngine
    }

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(input)
        }
#endif
        return try await fallbackEngine.translate(input)
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeTranslator {
    static func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        try ensureModelAvailability()

        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        let session = LanguageModelSession(instructions: instructions(for: input))
        var outputs: [SegmentOutput] = []
        outputs.reserveCapacity(segments.count)

        for segment in segments {
            let prompt = promptForSegment(segment.text, input: input)
            let response = try await session.respond(to: prompt)
            outputs.append(
                SegmentOutput(
                    segmentIndex: segment.index,
                    sourceText: segment.text,
                    translatedText: response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }

        return outputs
    }

    private static func ensureModelAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw FoundationModelsRuntimeError.unavailable(reason: String(describing: reason))
        @unknown default:
            throw FoundationModelsRuntimeError.unavailable(reason: "unknown")
        }
    }

    private static func instructions(for input: TranslationInput) -> String {
        """
        You are a translation engine.
        Translate from \(input.sourceLanguage) to \(input.targetLanguage).
        Return only the translated text.
        Preserve punctuation structure whenever possible.
        Do not include explanations or notes.
        """
    }

    private static func promptForSegment(_ segmentText: String, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Source text:")
        lines.append(segmentText)

        if !input.glossaryMatches.isEmpty {
            let glossaryLines = input.glossaryMatches
                .map { "\($0.source)=\($0.target)" }
            lines.append("")
            lines.append("Glossary constraints (prefer exact target terms):")
            lines.append(contentsOf: glossaryLines)
        }

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("")
            lines.append("Protected tokens (do not translate): \(protectedList)")
        }

        lines.append("")
        lines.append("Translated text:")
        return lines.joined(separator: "\n")
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeError: LocalizedError {
    case unavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Foundation Models is unavailable (\(reason)). Enable Apple Intelligence and finish downloading model assets, then retry."
        }
    }
}
#endif
