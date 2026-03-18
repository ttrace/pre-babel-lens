import Foundation

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var targetLanguage: String
    @Published var experimentMode: TranslationExperimentMode = .rawInput
    @Published var inputText: String = ""
    @Published var glossaryText: String = ""

    @Published var translatedText: String = ""
    @Published var traces: [PreprocessTrace] = []
    @Published var protectedTokens: [ProtectedToken] = []
    @Published var glossaryMatches: [GlossaryMatch] = []
    @Published var ambiguityHints: [AmbiguityHint] = []
    @Published var engineName: String = ""
    @Published var detectedLanguageCode: String = ""
    @Published var aiLanguageSupported: Bool = true
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var developerLogs: [String] = []

    let targetLanguageOptions: [TargetLanguageOption]
    private let orchestrator: TranslationOrchestrator
    private var shouldTranslateOnLaunch: Bool = false
    private var shouldActivateAppOnLaunch: Bool = false
    private var partialTranslationsBySegment: [Int: String] = [:]
    private var partialJoinersAfter: [String] = []
    private var lastHandledIncomingURLKey: String?

    init(orchestrator: TranslationOrchestrator, launchInputText: String? = nil) {
        let options = AppleIntelligenceLanguageCatalog.supportedLanguageOptions()
        self.targetLanguageOptions = options
        if options.contains(where: { $0.code == "ja" }) {
            self.targetLanguage = "ja"
        } else {
            self.targetLanguage = options.first?.code ?? "en"
        }
        self.orchestrator = orchestrator

        if let launchInputText {
            let trimmed = launchInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                self.inputText = trimmed
                self.shouldTranslateOnLaunch = true
                self.shouldActivateAppOnLaunch = true
            }
        }
    }

    func consumeLaunchActivationRequest() -> Bool {
        let shouldActivate = shouldActivateAppOnLaunch
        shouldActivateAppOnLaunch = false
        return shouldActivate
    }

    func translateIfNeededOnLaunch() async {
        guard shouldTranslateOnLaunch else { return }
        shouldTranslateOnLaunch = false
        await translate()
    }

    func handleIncomingURL(_ url: URL) async {
        guard let text = URLLaunchParser.extractText(from: url) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let deduplicationKey = "\(targetLanguage)\u{1F}\(trimmed)"
        guard lastHandledIncomingURLKey != deduplicationKey else { return }

        lastHandledIncomingURLKey = deduplicationKey
        inputText = trimmed
        appendDeveloperLog("Incoming URL accepted. chars=\(trimmed.count), target=\(targetLanguage)")
        await translate()
    }

    func translate() async {
        let request = TranslationRequest(
            sourceLanguage: "und",
            targetLanguage: targetLanguage,
            text: inputText,
            glossary: parseGlossary(glossaryText),
            experimentMode: experimentMode
        )

        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            traces = []
            protectedTokens = []
            glossaryMatches = []
            ambiguityHints = []
            engineName = ""
            detectedLanguageCode = ""
            aiLanguageSupported = true
            errorMessage = nil
            return
        }

        translatedText = ""
        traces = []
        protectedTokens = []
        glossaryMatches = []
        ambiguityHints = []
        engineName = ""
        detectedLanguageCode = ""
        aiLanguageSupported = true
        errorMessage = nil
        partialTranslationsBySegment = [:]
        partialJoinersAfter = []

        isTranslating = true
        defer { isTranslating = false }

        do {
            let output = try await orchestrator.translate(
                request,
                onPartialSegmentResult: { [weak self] segmentIndex, partialText, joinersAfter in
                    Task { @MainActor in
                        guard let self else { return }
                        self.partialTranslationsBySegment[segmentIndex] = partialText
                        self.partialJoinersAfter = joinersAfter
                        self.translatedText = self.reconstructPartialTranslatedText()
                    }
                }
            )
            translatedText = output.translatedText
            traces = output.analysis.traces
            protectedTokens = output.analysis.input.protectedTokens
            glossaryMatches = output.analysis.input.glossaryMatches
            ambiguityHints = output.analysis.input.ambiguityHints
            engineName = output.analysis.engineName
            detectedLanguageCode = output.analysis.input.detectedLanguageCode ?? ""
            aiLanguageSupported = output.analysis.input.isDetectedLanguageSupportedByAppleIntelligence
            errorMessage = nil
            appendDeveloperLog("Translation succeeded. segments=\(output.segmentOutputs.count), detected=\(detectedLanguageCode.isEmpty ? "none" : detectedLanguageCode)")
        } catch let pipelineError as TranslationPipelineError {
            if let detected = pipelineError.detectedLanguageCode {
                detectedLanguageCode = detected
                aiLanguageSupported = false
            }
            errorMessage = pipelineError.localizedDescription
            appendDeveloperLog("Pipeline error: \(pipelineError.localizedDescription)")
        } catch {
            errorMessage = error.localizedDescription
            appendDeveloperLog(detailedErrorLog(from: error))
        }
    }

    private func parseGlossary(_ raw: String) -> [GlossaryEntry] {
        raw
            .split(separator: "\n")
            .compactMap { line -> GlossaryEntry? in
                let parts = line.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
                return GlossaryEntry(source: parts[0], target: parts[1])
            }
    }

    private func reconstructPartialTranslatedText() -> String {
        let ordered = partialTranslationsBySegment.sorted(by: { $0.key < $1.key })
        guard !ordered.isEmpty else { return "" }

        let translatedSegments = ordered.map(\.value)
        if partialJoinersAfter.count >= translatedSegments.count {
            return translatedSegments.enumerated().map { index, text in
                text + normalizedJoiner(partialJoinersAfter[index], forTranslatedSegment: text)
            }.joined()
        }

        return translatedSegments.joined(separator: " ")
    }

    private func normalizedJoiner(_ joiner: String, forTranslatedSegment translatedText: String) -> String {
        guard !joiner.isEmpty else { return joiner }
        guard let last = translatedText.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return joiner
        }

        let terminalPunctuation: Set<Character> = [".", "!", "?", "。", "！", "？"]
        guard terminalPunctuation.contains(last) else { return joiner }

        var chars = Array(joiner)
        while let first = chars.first, terminalPunctuation.contains(first) {
            chars.removeFirst()
        }
        return String(chars)
    }
    private func detailedErrorLog(from error: Error) -> String {
        let nsError = error as NSError
        let userInfoSummary: String
        if nsError.userInfo.isEmpty {
            userInfoSummary = "{}"
        } else {
            userInfoSummary = nsError.userInfo
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
        }

        return [
            "Error: \(error.localizedDescription)",
            "Type: \(String(reflecting: type(of: error)))",
            "Domain: \(nsError.domain)",
            "Code: \(nsError.code)",
            "UserInfo: \(userInfoSummary)",
        ].joined(separator: " | ")
    }

    private func appendDeveloperLog(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        developerLogs.append("[\(timestamp)] \(message)")
        if developerLogs.count > 300 {
            developerLogs.removeFirst(developerLogs.count - 300)
        }
    }
}

private enum URLLaunchParser {
    static func extractText(from url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "prebabellens" else { return nil }

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let textItem = components.queryItems?.first(where: { $0.name == "text" }),
           let value = textItem.value {
            return value
        }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? nil : path.removingPercentEncoding ?? path
    }
}
