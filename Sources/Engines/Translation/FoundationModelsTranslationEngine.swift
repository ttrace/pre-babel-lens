import Foundation

struct FoundationModelsTranslationEngine: TranslationEngine {
    var name: String {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return "foundation-models"
        }
        return "foundation-models-unavailable(os)"
#else
        return "foundation-models-unavailable(toolchain)"
#endif
    }

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(input)
        }
#endif
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(
                input,
                onPartialResult: onPartialResult
            )
        }
#endif
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
    }
}

private enum FoundationModelsIntegrationError: LocalizedError {
    case missingFoundationModelsToolchain

    var errorDescription: String? {
        switch self {
        case .missingFoundationModelsToolchain:
            return "Foundation Models is unavailable in the current build toolchain. Build with Xcode toolchain and retry."
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeTranslator {
    static func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)? = nil
    ) async throws -> [SegmentOutput] {
        try ensureModelAvailability()

        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        let session = LanguageModelSession(instructions: instructions(for: input))
        let sensitiveContentSession = LanguageModelSession(
            instructions: sensitiveContentSafeInstructions(for: input)
        )
        var outputs: [SegmentOutput] = []
        outputs.reserveCapacity(segments.count)

        for segment in segments {
            let prompt = promptForSegment(segment.text, input: input)
            let finalText: String

            do {
                finalText = try await translateSegment(
                    prompt: prompt,
                    sourceText: segment.text,
                    using: session,
                    segmentIndex: segment.index,
                    onPartialResult: onPartialResult
                )
            } catch {
                if isLikelyUnsafeGenerationError(error) {
                    let safePrompt = promptForSensitiveContentSegment(segment.text, input: input)
                    do {
                        finalText = try await translateSegment(
                            prompt: safePrompt,
                            sourceText: segment.text,
                            using: sensitiveContentSession,
                            segmentIndex: segment.index,
                            onPartialResult: onPartialResult
                        )
                    } catch {
                        if isLikelyUnsafeGenerationError(error) {
                            finalText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        } else {
                            throw error
                        }
                    }
                } else {
                    throw error
                }
            }

            outputs.append(
                SegmentOutput(
                    segmentIndex: segment.index,
                    sourceText: segment.text,
                    translatedText: finalText
                )
            )
        }

        return outputs
    }

    private static func translateSegment(
        prompt: String,
        sourceText: String,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> String {
        var latestStreamedText: String?
        var repeatedSnapshotCount = 0
        let maxAllowedCharacters = max(400, min(8_000, sourceText.count * 12))
        let maxSnapshotCount = 240
        let maxStreamingDuration: TimeInterval = 20
        let streamStartedAt = Date()
        var receivedSnapshotCount = 0

        do {
            let stream = session.streamResponse(to: prompt)
            for try await snapshot in stream {
                receivedSnapshotCount += 1

                if latestStreamedText == snapshot.content {
                    repeatedSnapshotCount += 1
                } else {
                    repeatedSnapshotCount = 0
                }

                if repeatedSnapshotCount >= 12 {
                    break
                }

                if receivedSnapshotCount >= maxSnapshotCount {
                    break
                }

                if Date().timeIntervalSince(streamStartedAt) >= maxStreamingDuration {
                    break
                }

                if snapshot.content.count > maxAllowedCharacters {
                    latestStreamedText = String(snapshot.content.prefix(maxAllowedCharacters))
                    break
                }

                latestStreamedText = snapshot.content
                onPartialResult?(segmentIndex, latestStreamedText ?? snapshot.content)
            }
        } catch {
            if let latestStreamedText, !latestStreamedText.isEmpty {
                return latestStreamedText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            throw error
        }

        if let latestStreamedText, !latestStreamedText.isEmpty {
            return latestStreamedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let response = try await session.respond(to: prompt)
        let finalText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        onPartialResult?(segmentIndex, finalText)
        return finalText
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

    private static func sensitiveContentSafeInstructions(for input: TranslationInput) -> String {
        """
        You are a universal translation engine.
        Translate from \(input.sourceLanguage) to \(input.targetLanguage).
        The input can include politics, war, safety, or other sensitive topics.
        Your role is strictly translation, not policy analysis.
        Keep meaning and tone faithful.
        Return only the translated text.
        Do not refuse, summarize, or add warnings.
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

    private static func promptForSensitiveContentSegment(_ segmentText: String, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Task: direct translation only.")
        lines.append("Source language: \(input.sourceLanguage)")
        lines.append("Target language: \(input.targetLanguage)")
        lines.append("")
        lines.append("Source text:")
        lines.append(segmentText)

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("")
            lines.append("Protected tokens (do not translate): \(protectedList)")
        }

        lines.append("")
        lines.append("Output only the translated text:")
        return lines.joined(separator: "\n")
    }

    private static func isLikelyUnsafeGenerationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain.contains("FoundationModels.LanguageModelSession.GenerationError"),
           nsError.code == 2 {
            return true
        }

        let localized = error.localizedDescription.lowercased()
        return localized.contains("unsafe")
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
