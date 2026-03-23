import Foundation

@MainActor
final class TranslationViewModel: ObservableObject {
    enum TranslationStatus: Equatable {
        case ready
        case processing(mode: TranslationExperimentMode)
        case translating(current: Int, total: Int)
        case stopped
        case completed
    }

    @Published var targetLanguage: String
    @Published var experimentMode: TranslationExperimentMode = .segmented
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
    @Published private(set) var status: TranslationStatus = .ready

    let targetLanguageOptions: [TargetLanguageOption]
    private let orchestrator: TranslationOrchestrator
    private var shouldTranslateOnLaunch: Bool = false
    private var shouldActivateAppOnLaunch: Bool = false
    private var partialTranslationsBySegment: [Int: String] = [:]
    private var partialJoinersAfter: [String] = []
    private var lastHandledIncomingURLKey: String?
    private var activeTranslationTask: Task<Void, Never>?
    private var activeTranslationToken: UUID?
    private var pendingTranslationRequestStartedAt: Date?
    private var sessionSequenceNumber: Int = 0
    private var activeMetricsSessionID: String?
    private var activeMetricsRequestStartedAt: Date?
    private var activeMetricsSessionStartedAt: Date?
    private var activeMetricsFirstOutputAt: Date?

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
        await handleExternalTriggerText(text, source: "url")
    }

    func handleDoubleCopyText(_ text: String) async {
        await handleExternalTriggerText(text, source: "double-copy")
    }

    private func handleExternalTriggerText(_ text: String, source: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let deduplicationKey = "\(targetLanguage)\u{1F}\(experimentMode.rawValue)\u{1F}\(trimmed)"
        guard lastHandledIncomingURLKey != deduplicationKey else { return }

        lastHandledIncomingURLKey = deduplicationKey
        inputText = trimmed
        appendDeveloperLog(
            "Incoming \(source) accepted. chars=\(trimmed.count), target=\(targetLanguage), mode=\(experimentMode.rawValue)"
        )
        await translate()
    }

    func translate() async {
        pendingTranslationRequestStartedAt = Date()
        await runManagedTranslation()
    }

    func stopTranslation() {
        activeTranslationTask?.cancel()
        activeTranslationTask = nil
        activeTranslationToken = nil
        isTranslating = false
        status = .stopped
        appendDeveloperLog("Translation stopped by user.")
    }

    private func runManagedTranslation() async {
        activeTranslationTask?.cancel()
        let token = UUID()
        activeTranslationToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTranslation()
        }
        activeTranslationTask = task
        await task.value
        if activeTranslationToken == token {
            activeTranslationTask = nil
            activeTranslationToken = nil
        }
    }

    private func performTranslation() async {
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
            status = .ready
            pendingTranslationRequestStartedAt = nil
            resetSessionMetricsState()
            return
        }

        sessionSequenceNumber += 1
        let sessionID = "S\(sessionSequenceNumber)"
        activeMetricsSessionID = sessionID
        activeMetricsRequestStartedAt = pendingTranslationRequestStartedAt ?? Date()
        activeMetricsSessionStartedAt = nil
        activeMetricsFirstOutputAt = nil
        pendingTranslationRequestStartedAt = nil

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
        status = .processing(mode: experimentMode)

        isTranslating = true
        defer { isTranslating = false }

        do {
            let output = try await orchestrator.translate(
                request,
                onSessionStarted: { [weak self] segmentCount, detectedLanguageCode, targetLanguage, kindSummary in
                    Task { @MainActor in
                        guard let self else { return }
                        self.appendSessionLog(
                            "session-start: segments=\(segmentCount), detected=\(detectedLanguageCode.isEmpty ? "none" : detectedLanguageCode), target=\(targetLanguage), kinds={\(kindSummary)}"
                        )
                        self.recordSessionStarted()
                    }
                },
                onDiagnosticEvent: { [weak self] message in
                    Task { @MainActor in
                        self?.appendSessionLog(message)
                    }
                },
                onPartialSegmentResult: { [weak self] segmentIndex, partialText, joinersAfter in
                    Task { @MainActor in
                        guard let self else { return }
                        self.recordFirstOutputIfNeeded()
                        self.partialTranslationsBySegment[segmentIndex] = partialText
                        self.partialJoinersAfter = joinersAfter
                        self.translatedText = self.reconstructPartialTranslatedText()
                        let totalSegments = max(1, joinersAfter.count)
                        let currentSegment = min(totalSegments, max(1, segmentIndex + 1))
                        self.status = .translating(current: currentSegment, total: totalSegments)
                    }
                },
                onSessionFinished: { [weak self] in
                    Task { @MainActor in
                        self?.recordSessionFinished()
                    }
                }
            )
            recordFirstOutputIfNeeded()
            translatedText = output.translatedText
            traces = output.analysis.traces
            protectedTokens = output.analysis.input.protectedTokens
            glossaryMatches = output.analysis.input.glossaryMatches
            ambiguityHints = output.analysis.input.ambiguityHints
            engineName = output.analysis.engineName
            detectedLanguageCode = output.analysis.input.detectedLanguageCode ?? ""
            aiLanguageSupported = output.analysis.input.isDetectedLanguageSupportedByAppleIntelligence
            errorMessage = nil
            status = .completed
        } catch is CancellationError {
            status = .stopped
            appendSessionLog("translation-cancelled")
        } catch let pipelineError as TranslationPipelineError {
            if let detected = pipelineError.detectedLanguageCode {
                detectedLanguageCode = detected
                aiLanguageSupported = false
            }
            errorMessage = pipelineError.localizedDescription
            status = .ready
            appendSessionLog("pipeline-error: \(pipelineError.localizedDescription)")
        } catch {
            errorMessage = error.localizedDescription
            status = .ready
            appendSessionLog(detailedErrorLog(from: error))
        }

        resetSessionMetricsState()
    }

    var statusText: String {
        switch status {
        case .ready:
            return "Ready"
        case .processing(let mode):
            return "Processing (\(mode.displayName))"
        case .translating(let current, let total):
            return "Translating \(current)/\(total)"
        case .stopped:
            return "Stopped"
        case .completed:
            return "Completed"
        }
    }

    var developerLogsText: String {
        developerLogs.joined(separator: "\n")
    }

    func clearDeveloperLogs() {
        developerLogs.removeAll(keepingCapacity: true)
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

    private func appendSessionLog(_ message: String) {
        if let sessionID = activeMetricsSessionID {
            appendDeveloperLog("[\(sessionID)] \(message)")
            return
        }
        appendDeveloperLog(message)
    }

    private func recordSessionStarted() {
        guard activeMetricsSessionStartedAt == nil else { return }
        let now = Date()
        activeMetricsSessionStartedAt = now

        guard activeMetricsSessionID != nil else { return }
        let timeToSessionStart = milliseconds(from: activeMetricsRequestStartedAt, to: now)
        appendSessionLog("time-to-session-start: \(timeToSessionStart)")
    }

    private func recordFirstOutputIfNeeded() {
        guard activeMetricsFirstOutputAt == nil else { return }
        let now = Date()
        activeMetricsFirstOutputAt = now

        guard activeMetricsSessionID != nil else { return }
        let timeToFirstOutput = milliseconds(from: activeMetricsSessionStartedAt, to: now)
        appendSessionLog("time-to-first-output: \(timeToFirstOutput)")
    }

    private func recordSessionFinished() {
        guard activeMetricsSessionID != nil else { return }
        let now = Date()
        let sessionDuration = milliseconds(from: activeMetricsSessionStartedAt, to: now)
        appendSessionLog("session-duration: \(sessionDuration)")
    }

    private func resetSessionMetricsState() {
        activeMetricsSessionID = nil
        activeMetricsRequestStartedAt = nil
        activeMetricsSessionStartedAt = nil
        activeMetricsFirstOutputAt = nil
    }

    private func milliseconds(from start: Date?, to end: Date) -> String {
        guard let start else { return "(n/a)" }
        return String(format: "%.2f ms", end.timeIntervalSince(start) * 1_000)
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
