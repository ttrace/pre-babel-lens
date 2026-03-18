import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

struct AppleIntelligencePreprocessEngine: PreprocessEngine {
    let name: String = "apple-intelligence-preprocess-v1"

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        let startedAt = Date()
        let detection = HeuristicLanguageDetector.detectLanguage(text: request.text)
        let input = TranslationInput(
            sourceLanguage: detection.detectedLanguageCode,
            targetLanguage: request.targetLanguage,
            originalText: request.text,
            detectedLanguageCode: detection.detectedLanguageCode,
            isDetectedLanguageSupportedByAppleIntelligence: detection.isSupportedByAppleIntelligence,
            segments: [],
            segmentJoinersAfter: [],
            protectedTokens: [],
            glossaryMatches: [],
            ambiguityHints: [],
            formatting: FormattingProfile(
                leadingWhitespace: "",
                trailingWhitespace: "",
                newlineCount: 0
            )
        )

        var traces = [
            PreprocessTrace(
                step: "ai-heuristic-language-detection",
                summary: "detected=\(detection.detectedLanguageCode), ai_supported=\(detection.isSupportedByAppleIntelligence), method=\(detection.method)"
            )
        ]

        let elapsedMs = Date().timeIntervalSince(startedAt) * 1000
        traces.append(
            PreprocessTrace(
                step: "ai-heuristic-processing-time",
                summary: String(format: "%.2f ms", elapsedMs)
            )
        )

        return (input: input, traces: traces)
    }
}

struct CompositePreprocessEngine: PreprocessEngine {
    let deterministicEngine: PreprocessEngine
    let appleIntelligenceEngine: PreprocessEngine

    var name: String {
        "\(deterministicEngine.name)+\(appleIntelligenceEngine.name)"
    }

    func analyze(_ request: TranslationRequest) -> (input: TranslationInput, traces: [PreprocessTrace]) {
        let deterministic = deterministicEngine.analyze(request)
        let ai = appleIntelligenceEngine.analyze(request)
        var mergedInput = deterministic.input
        var traces = deterministic.traces + ai.traces

        let deterministicCode = mergedInput.detectedLanguageCode ?? "und"
        let aiCode = ai.input.detectedLanguageCode ?? "und"
        let shouldPromoteAIResult = (deterministicCode == "und" || !mergedInput.isDetectedLanguageSupportedByAppleIntelligence)
            && aiCode != "und"
            && ai.input.isDetectedLanguageSupportedByAppleIntelligence

        if shouldPromoteAIResult {
            mergedInput.sourceLanguage = aiCode
            mergedInput.detectedLanguageCode = aiCode
            mergedInput.isDetectedLanguageSupportedByAppleIntelligence = true
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-language-merge",
                    summary: "promoted detected language from \(deterministicCode) to \(aiCode)"
                )
            )
        } else {
            traces.append(
                PreprocessTrace(
                    step: "ai-heuristic-language-merge",
                    summary: "kept deterministic detected language \(deterministicCode)"
                )
            )
        }

        return (
            input: mergedInput,
            traces: traces
        )
    }
}

private struct HeuristicLanguageDetectionResult {
    let detectedLanguageCode: String
    let isSupportedByAppleIntelligence: Bool
    let method: String
}

private enum HeuristicLanguageDetector {
    private static let englishSignalWords: Set<String> = [
        "the", "and", "you", "for", "with", "from", "this", "that", "was", "were",
        "have", "has", "thank", "thanks", "again", "great", "impressed", "opportunity"
    ]

    static func detectLanguage(text: String) -> HeuristicLanguageDetectionResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: "und",
                isSupportedByAppleIntelligence: false,
                method: "ai-heuristic-empty-input"
            )
        }

        let supportedCodes = Set(AppleIntelligenceLanguageCatalog.supportedLanguageOptions().map(\.code))
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)

        let dominant = normalizeLanguageCode(recognizer.dominantLanguage?.rawValue ?? "und")
        let hypotheses = recognizer.languageHypotheses(withMaximum: 5)
            .map { (normalizeLanguageCode($0.key.rawValue), $0.value) }
            .sorted { $0.1 > $1.1 }

        if let supportedCandidate = hypotheses.first(where: { supportedCodes.contains($0.0) }) {
            if supportedCandidate.1 >= 0.25 {
                return HeuristicLanguageDetectionResult(
                    detectedLanguageCode: supportedCandidate.0,
                    isSupportedByAppleIntelligence: true,
                    method: "ai-heuristic-supported-hypothesis"
                )
            }
        }

        let englishWordCount = englishSignalCount(in: trimmed)
        let asciiLetterRatio = asciiLetterRatio(in: trimmed)
        if englishWordCount >= 3 && asciiLetterRatio >= 0.65 {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: "en",
                isSupportedByAppleIntelligence: supportedCodes.contains("en"),
                method: "ai-heuristic-english-cue"
            )
        }

        if supportedCodes.contains(dominant) {
            return HeuristicLanguageDetectionResult(
                detectedLanguageCode: dominant,
                isSupportedByAppleIntelligence: true,
                method: "ai-heuristic-dominant-supported"
            )
        }

        return HeuristicLanguageDetectionResult(
            detectedLanguageCode: dominant,
            isSupportedByAppleIntelligence: false,
            method: "ai-heuristic-unsupported"
        )
    }

    private static func normalizeLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
    }

    private static func englishSignalCount(in text: String) -> Int {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .reduce(into: 0) { count, token in
                if englishSignalWords.contains(token) {
                    count += 1
                }
            }
    }

    private static func asciiLetterRatio(in text: String) -> Double {
        var asciiLetters = 0
        var allLetters = 0

        for scalar in text.unicodeScalars {
            if CharacterSet.letters.contains(scalar) {
                allLetters += 1
                if scalar.isASCII {
                    asciiLetters += 1
                }
            }
        }

        guard allLetters > 0 else { return 0 }
        return Double(asciiLetters) / Double(allLetters)
    }
}
