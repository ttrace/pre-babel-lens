import Foundation

struct DeterministicPreprocessEngine: PreprocessEngine {
    let name: String = "deterministic-v1"

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        var traces: [PreprocessTrace] = []
        traces.append(
            PreprocessTrace(step: "experiment-mode", summary: request.experimentMode.rawValue)
        )

        let segments = request.experimentMode.usesSegmentation
            ? SentenceSegmenter.segment(request.text)
            : RawInputSegmenter.segment(request.text)
        traces.append(
            PreprocessTrace(step: "sentence-segmentation", summary: "segments=\(segments.count)")
        )

        let protectedTokens = request.experimentMode.usesProtectedTokens
            ? ProtectedTokenExtractor.extract(from: request.text)
            : []
        traces.append(
            PreprocessTrace(step: "protected-token-extraction", summary: "tokens=\(protectedTokens.count)")
        )

        let glossaryMatches = request.experimentMode.usesGlossary
            ? GlossaryMatcher.match(glossary: request.glossary, in: request.text)
            : []
        traces.append(
            PreprocessTrace(step: "glossary-application", summary: "matches=\(glossaryMatches.count)")
        )

        let ambiguityHints = AmbiguityHintDetector.detect(in: request.text)
        traces.append(
            PreprocessTrace(step: "ambiguity-hinting", summary: "hints=\(ambiguityHints.count)")
        )

        let formatting = FormattingInspector.inspect(request.text)
        traces.append(
            PreprocessTrace(step: "formatting-preservation", summary: "newlines=\(formatting.newlineCount)")
        )

        return (
            TranslationInput(
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                originalText: request.text,
                segments: segments,
                protectedTokens: protectedTokens,
                glossaryMatches: glossaryMatches,
                ambiguityHints: ambiguityHints,
                formatting: formatting
            ),
            traces
        )
    }
}

enum RawInputSegmenter {
    static func segment(_ text: String) -> [TextSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return [TextSegment(index: 0, text: trimmed)]
    }
}

enum SentenceSegmenter {
    static func segment(_ text: String) -> [TextSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parts = trimmed
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: { ".!?。！？".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if parts.isEmpty {
            return [TextSegment(index: 0, text: trimmed)]
        }

        return parts.enumerated().map { index, value in
            TextSegment(index: index, text: value)
        }
    }
}

enum ProtectedTokenExtractor {
    private static let urlRegex = try! NSRegularExpression(pattern: #"https?://[^\s]+"#)
    private static let filePathRegex = try! NSRegularExpression(pattern: #"(?:~?/)?(?:[\w.-]+/)+[\w.-]+"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`[^`]+`"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+(?:[.,]\d+)?\b"#)
    private static let properNounRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z]+\b"#)

    static func extract(from text: String) -> [ProtectedToken] {
        var tokens: [ProtectedToken] = []

        tokens += matches(using: urlRegex, in: text, kind: .url)
        tokens += matches(using: filePathRegex, in: text, kind: .filePath)
        tokens += matches(using: codeRegex, in: text, kind: .codeSnippet)
        tokens += matches(using: numberRegex, in: text, kind: .number)
        tokens += matches(using: properNounRegex, in: text, kind: .properNounCandidate)

        // Keep deterministic order for testability and observability.
        return tokens.sorted {
            text.distance(from: text.startIndex, to: $0.range.lowerBound)
                < text.distance(from: text.startIndex, to: $1.range.lowerBound)
        }
    }

    private static func matches(using regex: NSRegularExpression, in text: String, kind: ProtectedToken.Kind) -> [ProtectedToken] {
        let nsRange = NSRange(text.startIndex..., in: text)

        return regex.matches(in: text, range: nsRange).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            return ProtectedToken(kind: kind, value: String(text[range]), range: range)
        }
    }
}

enum GlossaryMatcher {
    static func match(glossary: [GlossaryEntry], in text: String) -> [GlossaryMatch] {
        guard !glossary.isEmpty else { return [] }

        var matches: [GlossaryMatch] = []
        for entry in glossary where !entry.source.isEmpty {
            let escaped = NSRegularExpression.escapedPattern(for: entry.source)
            let pattern = #"\b\#(escaped)\b"#
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsRange = NSRange(text.startIndex..., in: text)
            regex?.matches(in: text, range: nsRange).forEach { result in
                guard let range = Range(result.range, in: text) else { return }
                matches.append(GlossaryMatch(source: entry.source, target: entry.target, range: range))
            }
        }

        return matches.sorted {
            text.distance(from: text.startIndex, to: $0.range.lowerBound)
                < text.distance(from: text.startIndex, to: $1.range.lowerBound)
        }
    }
}

enum AmbiguityHintDetector {
    static func detect(in text: String) -> [AmbiguityHint] {
        var hints: [AmbiguityHint] = []
        let lowered = text.lowercased()

        if lowered.contains(" it ") || lowered.hasPrefix("it ") || lowered.hasSuffix(" it") {
            hints.append(AmbiguityHint(category: "pronoun", message: "Pronoun 'it' may require explicit referent in target language."))
        }
        if lowered.contains("they") {
            hints.append(AmbiguityHint(category: "pronoun", message: "Pronoun 'they' can be singular or plural."))
        }
        if lowered.contains("you") {
            hints.append(AmbiguityHint(category: "register", message: "Pronoun 'you' can require politeness choice."))
        }

        return hints
    }
}

enum FormattingInspector {
    static func inspect(_ text: String) -> FormattingProfile {
        let leading = String(text.prefix { $0.isWhitespace })
        let trailing = String(text.reversed().prefix { $0.isWhitespace }.reversed())
        let newlineCount = text.reduce(into: 0) { partialResult, char in
            if char == "\n" {
                partialResult += 1
            }
        }

        return FormattingProfile(
            leadingWhitespace: leading,
            trailingWhitespace: trailing,
            newlineCount: newlineCount
        )
    }
}
