import Foundation
import Testing
@testable import PreBabelLens

struct TranslationFrameworkPrimaryTranslationEngineTests {
    @Test
    func preservesNewlineBetweenSentencesInsideSingleSegment() async throws {
        let engine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: PassthroughUnsafeRecoveryEngine()
        )
        let segmentText = "First sentence.\nSecond sentence."
        let input = TranslationInput(
            sourceLanguage: "en",
            targetLanguage: "ja",
            originalText: segmentText,
            segments: [TextSegment(index: 0, text: segmentText)],
            segmentJoinersAfter: [""],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(leadingWhitespace: "", trailingWhitespace: "", newlineCount: 1)
        )

        let outputs = try await engine.translate(input)

        #expect(outputs.count == 1)
        #expect(outputs[0].translatedText == "TF<First sentence.\nSecond sentence.>")
    }

    @Test
    func preservesTripleNewlineBetweenParagraphs() async throws {
        let engine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: PassthroughUnsafeRecoveryEngine()
        )
        let segmentText = """
First paragraph.


Second paragraph.
"""
        let input = TranslationInput(
            sourceLanguage: "en",
            targetLanguage: "ja",
            originalText: segmentText,
            segments: [TextSegment(index: 0, text: segmentText)],
            segmentJoinersAfter: [""],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(leadingWhitespace: "", trailingWhitespace: "", newlineCount: 3)
        )

        let outputs = try await engine.translate(input)

        #expect(outputs.count == 1)
        #expect(outputs[0].translatedText == "TF<First paragraph.\n\n\nSecond paragraph.>")
    }

    @Test
    func preservesTrailingNewlineFromRecoveryOutput() async throws {
        let engine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: TrailingNewlineUnsafeRecoveryEngine()
        )
        let segmentText = "Paragraph line."
        let input = TranslationInput(
            sourceLanguage: "en",
            targetLanguage: "ja",
            originalText: segmentText,
            segments: [TextSegment(index: 0, text: segmentText)],
            segmentJoinersAfter: [""],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(leadingWhitespace: "", trailingWhitespace: "", newlineCount: 0)
        )

        let outputs = try await engine.translate(input)

        #expect(outputs.count == 1)
        #expect(outputs[0].translatedText == "TF<Paragraph line.>\n")
    }

    @Test
    func continuesWithSourceFallbackWhenOneSegmentFails() async throws {
        let engine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: FailsOnSpecificSegmentRecoveryEngine()
        )
        let input = TranslationInput(
            sourceLanguage: "en",
            targetLanguage: "ja",
            originalText: "A. B. C.",
            segments: [
                TextSegment(index: 0, text: "A."),
                TextSegment(index: 1, text: "B."),
                TextSegment(index: 2, text: "C."),
            ],
            segmentJoinersAfter: [" ", " ", ""],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(leadingWhitespace: "", trailingWhitespace: "", newlineCount: 0)
        )

        let outputs = try await engine.translate(input)

        #expect(outputs.count == 3)
        #expect(outputs[0].translatedText == "TF<A.>")
        #expect(outputs[0].isUnsafeFallback == false)
        #expect(outputs[1].translatedText == "B.")
        #expect(outputs[1].isUnsafeFallback == true)
        #expect(outputs[2].translatedText == "TF<C.>")
        #expect(outputs[2].isUnsafeFallback == false)
    }

    @Test
    func marksSegmentAsUnsafeWhenRecoveryReportsInsertedSourceFallback() async throws {
        let engine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: DiagnosticSourceFallbackRecoveryEngine()
        )
        let input = TranslationInput(
            sourceLanguage: "en",
            targetLanguage: "ja",
            originalText: "Sample.",
            segments: [TextSegment(index: 0, text: "Sample.")],
            segmentJoinersAfter: [""],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(leadingWhitespace: "", trailingWhitespace: "", newlineCount: 0)
        )

        let outputs = try await engine.translate(input)

        #expect(outputs.count == 1)
        #expect(outputs[0].translatedText == "TF<Sample.>")
        #expect(outputs[0].isUnsafeFallback == true)
    }

    @Test
    func retriesWithAutoSourceWhenUnsupportedPairingIsReported() async throws {
        let engine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: UnsupportedThenAutoSucceedsRecoveryEngine()
        )
        let input = TranslationInput(
            sourceLanguage: "en",
            targetLanguage: "en-GB",
            originalText: "US spelling",
            segments: [TextSegment(index: 0, text: "US spelling")],
            segmentJoinersAfter: [""],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(leadingWhitespace: "", trailingWhitespace: "", newlineCount: 0)
        )

        let outputs = try await engine.translate(input)

        #expect(outputs.count == 1)
        #expect(outputs[0].translatedText == "TF<US spelling>-auto")
        #expect(outputs[0].isUnsafeFallback == false)
    }
}

private struct PassthroughUnsafeRecoveryEngine: UnsafeSegmentRecoveryEngine {
    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (String) -> Void)?
    ) async -> String? {
        let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : "TF<\(normalized)>"
    }
}

private struct TrailingNewlineUnsafeRecoveryEngine: UnsafeSegmentRecoveryEngine {
    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (String) -> Void)?
    ) async -> String? {
        let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : "TF<\(normalized)>\n"
    }
}

private struct FailsOnSpecificSegmentRecoveryEngine: UnsafeSegmentRecoveryEngine {
    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (String) -> Void)?
    ) async -> String? {
        if sourceText == "B." {
            return nil
        }
        let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : "TF<\(normalized)>"
    }
}

private struct DiagnosticSourceFallbackRecoveryEngine: UnsafeSegmentRecoveryEngine {
    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (String) -> Void)?
    ) async -> String? {
        onDiagnosticEvent?("translation-framework-recovery:source-fallback-inserted chunks=1")
        let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : "TF<\(normalized)>"
    }
}

private struct UnsupportedThenAutoSucceedsRecoveryEngine: UnsafeSegmentRecoveryEngine {
    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (String) -> Void)?
    ) async -> String? {
        let normalized = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if sourceLanguage == "und" {
            return "TF<\(normalized)>-auto"
        }
        onDiagnosticEvent?("translation-framework-recovery:failure-kind=unsupported_language_pairing")
        return nil
    }
}
