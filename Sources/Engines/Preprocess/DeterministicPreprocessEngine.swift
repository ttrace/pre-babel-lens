import Foundation
import NaturalLanguage

struct DeterministicPreprocessEngine: PreprocessEngine {
    let name: String = "deterministic-v1"

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        let startedAt = Date()
        var traces: [PreprocessTrace] = []
        traces.append(
            PreprocessTrace(step: "experiment-mode", summary: request.experimentMode.rawValue)
        )

        let languageDetection = HeuristicLanguageDetector.detectLanguage(text: request.text)
        let detectedLanguage = languageDetection.detectedLanguageCode
        let isSupportedByAppleIntelligence = languageDetection.isSupportedByAppleIntelligence
        traces.append(
            PreprocessTrace(
                step: "language-detection",
                summary: "detected=\(detectedLanguage), ai_supported=\(isSupportedByAppleIntelligence), method=\(languageDetection.method)"
            )
        )

        let segmentation = request.experimentMode.usesSegmentation
            ? SentenceSegmenter.segment(request.text)
            : RawInputSegmenter.segment(request.text)
        traces.append(
            PreprocessTrace(step: "sentence-segmentation", summary: "segments=\(segmentation.segments.count)")
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

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        traces.append(
            PreprocessTrace(
                step: "deterministic-processing-time",
                summary: String(format: "%.2f ms", elapsedMs)
            )
        )

        return (
            TranslationInput(
                sourceLanguage: detectedLanguage,
                targetLanguage: request.targetLanguage,
                originalText: request.text,
                detectedLanguageCode: detectedLanguage,
                isDetectedLanguageSupportedByAppleIntelligence: isSupportedByAppleIntelligence,
                segments: segmentation.segments,
                segmentJoinersAfter: segmentation.joinersAfter,
                protectedTokens: protectedTokens,
                glossaryMatches: glossaryMatches,
                ambiguityHints: ambiguityHints,
                formatting: formatting
            ),
            traces
        )
    }
}

struct HeuristicLanguageDetectionResult {
    var detectedLanguageCode: String
    var isSupportedByAppleIntelligence: Bool
    var method: String
}

enum HeuristicLanguageDetector {
    private static let fallbackSupportedLanguageCodes: Set<String> = [
        "da", "de", "en", "es", "fr", "it", "ja", "ko",
        "nb", "nl", "pt", "sv", "tr", "vi", "zh"
    ]

    static func detectLanguage(text: String) -> HeuristicLanguageDetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: "und",
                isSupportedByAppleIntelligence: false,
                method: "heuristic-empty-input"
            )
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let dominant = recognizer.dominantLanguage.map { normalizeLanguageCode($0.rawValue) } ?? "und"
        let supported = supportedLanguageCodes()

        if supported.contains(dominant) {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: dominant,
                isSupportedByAppleIntelligence: true,
                method: "heuristic-dominant-supported"
            )
        }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            .map { (normalizeLanguageCode($0.key.rawValue), $0.value) }
            .sorted { $0.1 > $1.1 }

        if let supportedCandidate = hypotheses.first(where: { supported.contains($0.0) }) {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: supportedCandidate.0,
                isSupportedByAppleIntelligence: true,
                method: "heuristic-hypothesis-supported"
            )
        }

        return HeuristicLanguageDetectionResult(
            detectedLanguageCode: dominant,
            isSupportedByAppleIntelligence: false,
            method: "heuristic-unsupported"
        )
    }

    private static func supportedLanguageCodes() -> Set<String> {
        return fallbackSupportedLanguageCodes
    }

    private static func normalizeLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
    }
}

enum RawInputSegmenter {
    static func segment(_ text: String) -> SegmentationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SegmentationResult(segments: [], joinersAfter: [])
        }
        return SegmentationResult(
            segments: [TextSegment(index: 0, text: trimmed)],
            joinersAfter: [""]
        )
    }
}

enum SentenceSegmenter {
    static func segment(_ text: String) -> SegmentationResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SegmentationResult(segments: [], joinersAfter: [])
        }

        var segments: [TextSegment] = []
        var joinersAfter: [String] = []

        let blocks = splitByBlankLines(in: trimmed)
        for block in blocks {
            let blockSegments = segmentBlock(block.text)
            guard !blockSegments.isEmpty else {
                if !joinersAfter.isEmpty {
                    joinersAfter[joinersAfter.count - 1] += block.delimiterAfter
                }
                continue
            }

            for (indexInBlock, blockSegment) in blockSegments.enumerated() {
                segments.append(
                    TextSegment(
                        index: segments.count,
                        text: blockSegment.text,
                        kind: blockSegment.kind
                    )
                )
                let intraBlockJoiner = indexInBlock < blockSegments.count - 1 ? "\n" : ""
                joinersAfter.append(intraBlockJoiner)
            }

            joinersAfter[joinersAfter.count - 1] += block.delimiterAfter
        }

        if segments.isEmpty {
            return SegmentationResult(
                segments: [TextSegment(index: 0, text: trimmed)],
                joinersAfter: [""]
            )
        }

        if joinersAfter.count < segments.count {
            joinersAfter.append(contentsOf: Array(repeating: "", count: segments.count - joinersAfter.count))
        }

        return SegmentationResult(segments: segments, joinersAfter: joinersAfter)
    }

    private static func segmentBlock(_ blockText: String) -> [KindedSegment] {
        let lines = blockText.components(separatedBy: "\n")
        guard !lines.isEmpty else { return [] }

        var segments: [KindedSegment] = []
        var cursor = 0

        while cursor < lines.count {
            let current = lines[cursor]
            if isBylineLeadLine(current) {
                append(lines: lines, start: cursor, end: cursor + 1, kind: .general, to: &segments)
                cursor += 1
                continue
            }

            if isDialogueLine(current) {
                let end = runEnd(from: cursor, in: lines, where: isDialogueLine)
                let safeEnd = max(cursor + 1, min(end, lines.count))
                append(lines: lines, start: cursor, end: safeEnd, kind: .dialogue, to: &segments)
                cursor = safeEnd
                continue
            }

            let uiLabelsEnd = runEnd(from: cursor, in: lines, where: isTwoWordsOrFewerLine)
            if uiLabelsEnd - cursor >= 2 {
                let safeEnd = min(uiLabelsEnd, lines.count)
                append(lines: lines, start: cursor, end: safeEnd, kind: .uiLabels, to: &segments)
                cursor = safeEnd
                continue
            }

            let shortNonPeriodEnd = runEnd(from: cursor, in: lines, where: isShortNonPeriodLine)
            if shortNonPeriodEnd > cursor {
                let safeEnd = min(shortNonPeriodEnd, lines.count)
                let range = cursor..<safeEnd
                let kind: SegmentKind = range.count == 1 ? .heading : .lists
                append(lines: lines, start: range.lowerBound, end: range.upperBound, kind: kind, to: &segments)
                cursor = safeEnd
                continue
            }

            var generalEnd = cursor + 1
            while generalEnd < lines.count {
                if isBylineLeadLine(lines[generalEnd]) {
                    break
                }
                if isDialogueLine(lines[generalEnd]) {
                    break
                }
                let nextUILabelsEnd = runEnd(from: generalEnd, in: lines, where: isTwoWordsOrFewerLine)
                if nextUILabelsEnd - generalEnd >= 2 {
                    break
                }
                if isShortNonPeriodLine(lines[generalEnd]) {
                    break
                }
                generalEnd += 1
            }

            let safeEnd = max(cursor + 1, min(generalEnd, lines.count))
            append(lines: lines, start: cursor, end: safeEnd, kind: .general, to: &segments)
            cursor = safeEnd
        }

        return segments
    }

    private static func append(
        lines: [String],
        start: Int,
        end: Int,
        kind: SegmentKind,
        to segments: inout [KindedSegment]
    ) {
        guard !lines.isEmpty else { return }
        let safeStart = max(0, min(start, lines.count))
        let safeEnd = max(safeStart, min(end, lines.count))
        guard safeStart < safeEnd else { return }
        let range = safeStart..<safeEnd
        let text = lines[range].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        segments.append(KindedSegment(text: text, kind: kind))
    }

    private static func runEnd(
        from start: Int,
        in lines: [String],
        where predicate: (String) -> Bool
    ) -> Int {
        var index = start
        while index < lines.count, predicate(lines[index]) {
            index += 1
        }
        return index
    }

    private static func splitByBlankLines(in text: String) -> [BlankLineBlock] {
        let regex = try! NSRegularExpression(pattern: #"\n[ \t]*\n+"#)
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)

        if matches.isEmpty {
            return [BlankLineBlock(text: text, delimiterAfter: "")]
        }

        var blocks: [BlankLineBlock] = []
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            let chunk = String(text[cursor..<range.lowerBound])
            let delimiter = String(text[range])

            if !chunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(BlankLineBlock(text: chunk, delimiterAfter: delimiter))
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1].delimiterAfter += delimiter
            }
            cursor = range.upperBound
        }

        let tail = String(text[cursor..<text.endIndex])
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blocks.append(BlankLineBlock(text: tail, delimiterAfter: ""))
        } else if !blocks.isEmpty {
            blocks[blocks.count - 1].delimiterAfter += tail
        }

        return blocks
    }

    private static func isDialogueLine(_ line: String) -> Bool {
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        return dialogueLineRegex.firstMatch(in: line, range: nsRange) != nil
    }

    private static func isTwoWordsOrFewerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return wordCount(in: trimmed) <= 2
    }

    private static func isShortNonPeriodLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !endsWithPeriod(trimmed) else { return false }
        return wordCount(in: trimmed) <= 15
    }

    private static func isBylineLeadLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard wordCount(in: trimmed) <= 12 else { return false }

        let lowered = trimmed.lowercased()
        for marker in bylineLeadWords {
            if lowered == marker { continue }
            if lowered.hasPrefix(marker + " ") || lowered.hasPrefix(marker + ":") {
                return true
            }
        }

        return false
    }

    private static func endsWithPeriod(_ line: String) -> Bool {
        guard let last = line.last else { return false }
        return last == "." || last == "。"
    }

    private static func wordCount(in line: String) -> Int {
        line
            .split(whereSeparator: \.isWhitespace)
            .count
    }

    private static let dialogueLineRegex = try! NSRegularExpression(
        pattern: #"^\s*(?:(?:[-—•*]\s+\S)|(?:[「『“"']\S)|(?:[A-Za-z][A-Za-z0-9 _-]{0,20}:\s))"#
    )

    // Conservative byline markers for line-initial "By ..." style credits.
    private static let bylineLeadWords: Set<String> = [
        "by",      // English
        "por",     // Spanish / Portuguese
        "par",     // French
        "von",     // German
        "door",    // Dutch
        "av",      // Swedish / Norwegian / Danish
        "af",      // Danish/Norwegian variant
        "od",      // Polish/Czech/Slovak style variant
    ]
}

private struct KindedSegment {
    var text: String
    var kind: SegmentKind
}

private struct BlankLineBlock {
    var text: String
    var delimiterAfter: String
}

struct SegmentationResult {
    var segments: [TextSegment]
    var joinersAfter: [String]
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
