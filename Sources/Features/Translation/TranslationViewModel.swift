import Foundation

@MainActor
final class TranslationViewModel: ObservableObject {
    enum StatusNoticeKind: Equatable {
        case sameLanguageUntranslatable
        case aiFallbackToMachineTranslation
        case unknownSourceLanguage
    }

    struct StatusNotice: Equatable, Identifiable {
        enum Style: Equatable, Hashable {
            case orange
            case blue
        }

        let id = UUID()
        let markerText: String
        let text: String
        let style: Style
    }

    struct UserAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let inlineMessage: String
        let offersSettingsShortcut: Bool
    }

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
    @Published var segmentOutputs: [SegmentOutput] = []
    @Published var segmentJoinersAfter: [String] = []
    @Published var traces: [PreprocessTrace] = []
    @Published var protectedTokens: [ProtectedToken] = []
    @Published var glossaryMatches: [GlossaryMatch] = []
    @Published var ambiguityHints: [AmbiguityHint] = []
    @Published var engineName: String = ""
    @Published var detectedLanguageCode: String = ""
    @Published var aiLanguageSupported: Bool = true
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?
    @Published var userAlert: UserAlert?
    @Published var developerLogs: [String] = []
    @Published private(set) var statusNotices: [StatusNotice] = []
    @Published private(set) var status: TranslationStatus = .ready
    @Published private(set) var targetLanguageOptions: [TargetLanguageOption] = []
    @Published private(set) var isAppleIntelligenceAvailable: Bool = false
    @Published private(set) var usesAppleIntelligenceTranslation: Bool = false

    private let orchestrator: TranslationOrchestrator
    private let iOSEnginePolicy: IOSAdaptiveTranslationEnginePolicy?
    private var shouldTranslateOnLaunch: Bool = false
    private var shouldActivateAppOnLaunch: Bool = false
    private var partialTranslationsBySegment: [Int: String] = [:]
    private var partialJoinersAfter: [String] = []
    private var lastHandledIncomingURLKey: String?
    private var lastHandledSharedImportKey: String?
    private var activeTranslationTask: Task<Void, Never>?
    private var activeTranslationToken: UUID?
    private var pendingTranslationRequestStartedAt: Date?
    private var sessionSequenceNumber: Int = 0
    private var activeMetricsSessionID: String?
    private var activeMetricsRequestStartedAt: Date?
    private var activeMetricsSessionStartedAt: Date?
    private var activeMetricsFirstOutputAt: Date?

    init(
        orchestrator: TranslationOrchestrator,
        iOSEnginePolicy: IOSAdaptiveTranslationEnginePolicy? = nil,
        launchInputText: String? = nil
    ) {
        self.iOSEnginePolicy = iOSEnginePolicy
        let initialOptions = AppleIntelligenceLanguageCatalog.translationFrameworkLanguageOptions()
        if initialOptions.contains(where: { $0.code == "ja" }) {
            self.targetLanguage = "ja"
        } else {
            self.targetLanguage = initialOptions.first?.code ?? "en"
        }
        self.orchestrator = orchestrator
        refreshEnginePreference()

        if let launchInputText {
            let trimmed = normalizedLineEndings(in: launchInputText)
                .trimmingCharacters(in: .whitespacesAndNewlines)
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

    func refreshEnginePreference() {
        guard let iOSEnginePolicy else {
            isAppleIntelligenceAvailable = false
            usesAppleIntelligenceTranslation = false
            targetLanguageOptions = AppleIntelligenceLanguageCatalog.translationFrameworkLanguageOptions()
            normalizeTargetLanguageSelection()
            return
        }

        isAppleIntelligenceAvailable = iOSEnginePolicy.isFoundationModelsAvailable()
        usesAppleIntelligenceTranslation = iOSEnginePolicy.currentPreferredMode() == .foundationModels && isAppleIntelligenceAvailable
        targetLanguageOptions = usesAppleIntelligenceTranslation
            ? AppleIntelligenceLanguageCatalog.supportedLanguageOptions()
            : AppleIntelligenceLanguageCatalog.translationFrameworkLanguageOptions()
        normalizeTargetLanguageSelection()
    }

    func switchToAppleIntelligenceTranslation() {
        guard let iOSEnginePolicy else { return }
        iOSEnginePolicy.setPreferredMode(.foundationModels)
        refreshEnginePreference()
    }

    func switchToStandardTranslation() {
        guard let iOSEnginePolicy else { return }
        iOSEnginePolicy.setPreferredMode(.translationFramework)
        refreshEnginePreference()
    }

    #if os(iOS)
    @discardableResult
    func importSharedTextIfNeeded() -> String? {
        guard let text = SharedImportStore.consumePendingText() else { return nil }
        let trimmed = normalizedLineEndings(in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard lastHandledSharedImportKey != trimmed else { return nil }
        lastHandledSharedImportKey = trimmed
        inputText = trimmed
        appendDeveloperLog("Incoming share-store accepted. chars=\(trimmed.count)")
        return trimmed
    }
    #endif

    private func handleExternalTriggerText(_ text: String, source: String) async {
        let trimmed = normalizedLineEndings(in: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
        let taskToDrain = activeTranslationTask
        taskToDrain?.cancel()
        activeTranslationTask = nil
        activeTranslationToken = nil
        isTranslating = false
        status = .stopped
        appendDeveloperLog("Translation stopped by user.")

        if let taskToDrain {
            Task { @MainActor [weak self] in
                await taskToDrain.value
                self?.appendDeveloperLog("Previous translation task drained after stop.")
            }
        }
    }

    private func normalizeTargetLanguageSelection() {
        guard !targetLanguageOptions.isEmpty else { return }
        if targetLanguageOptions.contains(where: { $0.code == targetLanguage }) {
            return
        }
        if let japanese = targetLanguageOptions.first(where: { $0.code == "ja" }) {
            targetLanguage = japanese.code
            return
        }
        targetLanguage = targetLanguageOptions[0].code
    }

    private func runManagedTranslation() async {
        if let previousTask = activeTranslationTask {
            previousTask.cancel()
            await previousTask.value
        }
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
        let normalizedInput = normalizedLineEndings(in: inputText)
        if inputText != normalizedInput {
            inputText = normalizedInput
        }

        let request = TranslationRequest(
            sourceLanguage: "und",
            targetLanguage: targetLanguage,
            text: normalizedInput,
            glossary: parseGlossary(glossaryText),
            experimentMode: experimentMode
        )

        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            segmentOutputs = []
            segmentJoinersAfter = []
            traces = []
            protectedTokens = []
            glossaryMatches = []
            ambiguityHints = []
            engineName = ""
            detectedLanguageCode = ""
            aiLanguageSupported = true
            errorMessage = nil
            userAlert = nil
            statusNotices = []
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
        segmentOutputs = []
        segmentJoinersAfter = []
        traces = []
        protectedTokens = []
        glossaryMatches = []
        ambiguityHints = []
        engineName = ""
        detectedLanguageCode = ""
        aiLanguageSupported = true
        errorMessage = nil
        userAlert = nil
        statusNotices = []
        partialTranslationsBySegment = [:]
        partialJoinersAfter = []
        status = .processing(mode: experimentMode)

        isTranslating = true
        defer { isTranslating = false }

        do {
            let output = try await orchestrator.translate(
                request,
                onSessionStarted: { [weak self] segmentCount, tokenizerSentenceCount, detectedLanguageCode, targetLanguage, kindSummary in
                    Task { @MainActor in
                        guard let self else { return }
                        self.appendSessionLog(
                            "session-start: segments=\(segmentCount), tokenizer-sentences=\(tokenizerSentenceCount), detected=\(detectedLanguageCode.isEmpty ? "none" : detectedLanguageCode), target=\(targetLanguage), kinds={\(kindSummary)}"
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
            segmentOutputs = output.segmentOutputs
            segmentJoinersAfter = output.analysis.input.segmentJoinersAfter
            traces = output.analysis.traces
            protectedTokens = output.analysis.input.protectedTokens
            glossaryMatches = output.analysis.input.glossaryMatches
            ambiguityHints = output.analysis.input.ambiguityHints
            engineName = output.analysis.engineName
            detectedLanguageCode = output.analysis.input.detectedLanguageCode ?? ""
            aiLanguageSupported = output.analysis.input.isDetectedLanguageSupportedByAppleIntelligence
            errorMessage = nil
            userAlert = nil
            statusNotices = makeStatusNotices(output: output, request: request)
            status = .completed
        } catch is CancellationError {
            status = .stopped
            statusNotices = []
            appendSessionLog("translation-cancelled")
        } catch let pipelineError as TranslationPipelineError {
            if let detected = pipelineError.detectedLanguageCode {
                detectedLanguageCode = detected
                aiLanguageSupported = false
            }
            if let alert = userAlert(for: pipelineError.localizedDescription) {
                userAlert = alert
                errorMessage = alert.inlineMessage
            } else {
                errorMessage = pipelineError.localizedDescription
            }
            statusNotices = []
            status = .ready
            appendSessionLog("pipeline-error: \(pipelineError.localizedDescription)")
        } catch {
            if let alert = userAlert(for: error.localizedDescription) {
                userAlert = alert
                errorMessage = alert.inlineMessage
            } else {
                errorMessage = error.localizedDescription
            }
            statusNotices = []
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

    func dismissUserAlert() {
        userAlert = nil
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

    private func userAlert(for localizedDescription: String) -> UserAlert? {
        if localizedDescription.contains("current build toolchain") {
            return UserAlert(
                title: isJapaneseLocale ? "Foundation Models を利用できません" : "Foundation Models Unavailable",
                message: isJapaneseLocale
                    ? "現在のビルド環境では Foundation Models を利用できません。Xcode の正式なツールチェーンでビルドし直してから、もう一度お試しください。"
                    : "Foundation Models is unavailable in the current build toolchain. Rebuild the app with the Xcode toolchain and try again.",
                inlineMessage: isJapaneseLocale
                    ? "Foundation Models を利用できません。Xcode で再ビルドしてください。"
                    : "Foundation Models is unavailable. Rebuild with the Xcode toolchain.",
                offersSettingsShortcut: false
            )
        }

        if localizedDescription.contains("requires macOS 26.0+ / iOS 26.0+") {
            return UserAlert(
                title: isJapaneseLocale ? "対応していないOSです" : "Unsupported OS Version",
                message: isJapaneseLocale
                    ? "Foundation Models には macOS 26 以降、または iOS 26 以降が必要です。対応OSにアップデートしてから、もう一度お試しください。"
                    : "Foundation Models requires macOS 26.0+ or iOS 26.0+. Update to a supported OS version and try again.",
                inlineMessage: isJapaneseLocale
                    ? "対応OSが必要です。"
                    : "A supported OS version is required.",
                offersSettingsShortcut: false
            )
        }

        if localizedDescription.contains("Foundation Models is unavailable")
            || localizedDescription.contains("Enable Apple Intelligence")
            || localizedDescription.contains("finish downloading model assets")
        {
            return UserAlert(
                title: isJapaneseLocale ? "Apple Intelligence を確認してください" : "Check Apple Intelligence",
                message: isJapaneseLocale
                    ? "この iPhone では Apple Intelligence の準備が完了していないようです。Settings を開いて Apple Intelligence を有効にし、モデルのダウンロード完了を確認してから、もう一度お試しください。\n\n設定アプリでは「Siri と Apple Intelligence」を確認してください。"
                    : "Apple Intelligence does not appear to be ready on this iPhone yet. Open Settings, make sure Apple Intelligence is enabled, and finish downloading the required model assets before trying again.\n\nIn Settings, check “Siri & Apple Intelligence.”",
                inlineMessage: isJapaneseLocale
                    ? "Apple Intelligence の設定またはダウンロードを確認してください。"
                    : "Check Apple Intelligence settings and model downloads.",
                offersSettingsShortcut: true
            )
        }

        if localizedDescription.contains("language-pack download")
            || localizedDescription.contains("Translation Framework could not complete translation")
        {
            let languagePair = extractLanguagePair(from: localizedDescription)
            let recoveryFailureKind = extractRecoveryFailureKind(from: localizedDescription)
            if let languagePair, normalizedLanguageCode(languagePair.source) == normalizedLanguageCode(languagePair.target) {
                let pairLabel = "\(languagePair.source) -> \(languagePair.target)"
                return UserAlert(
                    title: isJapaneseLocale ? "同一言語ペアです" : "Same Language Pair",
                    message: isJapaneseLocale
                        ? "入力言語と出力言語が同じペアになっています（\(pairLabel)）。別の出力言語を選択して再実行してください。"
                        : "The source and target language are the same (\(pairLabel)). Select a different target language and try again.",
                    inlineMessage: isJapaneseLocale
                        ? "同一言語ペア（\(pairLabel)）のため翻訳できません。"
                        : "Cannot translate with the same language pair (\(pairLabel)).",
                    offersSettingsShortcut: false
                )
            }

            if let languagePair {
                let source = languageAvailabilityLabel(for: languagePair.source, role: .source)
                let target = languageAvailabilityLabel(for: languagePair.target, role: .target)
                switch recoveryFailureKind {
                case "missing_source_language":
                    return UserAlert(
                        title: isJapaneseLocale ? "翻訳言語データを確認してください" : "Check Translation Language Data",
                        message: isJapaneseLocale
                            ? "\(source) がありません。Settingsでダウンロード状況を確認し、完了後に再起動してから再実行してください。"
                            : "\(source) is unavailable. Check download status in Settings, then relaunch and try again.",
                        inlineMessage: isJapaneseLocale
                            ? "\(source) がありません。"
                            : "\(source) is unavailable.",
                        offersSettingsShortcut: false
                    )
                case "missing_target_language":
                    return UserAlert(
                        title: isJapaneseLocale ? "翻訳言語データを確認してください" : "Check Translation Language Data",
                        message: isJapaneseLocale
                            ? "\(target) がありません。Settingsでダウンロード状況を確認し、完了後に再起動してから再実行してください。"
                            : "\(target) is unavailable. Check download status in Settings, then relaunch and try again.",
                        inlineMessage: isJapaneseLocale
                            ? "\(target) がありません。"
                            : "\(target) is unavailable.",
                        offersSettingsShortcut: false
                    )
                case "missing_source_and_target_language":
                    return UserAlert(
                        title: isJapaneseLocale ? "翻訳言語データを確認してください" : "Check Translation Language Data",
                        message: isJapaneseLocale
                            ? "\(source) と \(target) がありません。Settingsでダウンロード状況を確認し、完了後に再起動してから再実行してください。"
                            : "\(source) and \(target) are unavailable. Check download status in Settings, then relaunch and try again.",
                        inlineMessage: isJapaneseLocale
                            ? "\(source) と \(target) がありません。"
                            : "\(source) and \(target) are unavailable.",
                        offersSettingsShortcut: false
                    )
                case "unsupported_language_pairing":
                    return UserAlert(
                        title: isJapaneseLocale ? "翻訳言語ペアを確認してください" : "Check Translation Language Pair",
                        message: isJapaneseLocale
                            ? "言語ペア（\(source) -> \(target)）が利用できません。Settingsで言語データの状況を確認し、必要に応じてダウンロードしてから再実行してください。"
                            : "The language pair (\(source) -> \(target)) is unavailable. Check language data in Settings and download if needed, then try again.",
                        inlineMessage: isJapaneseLocale
                            ? "言語ペア（\(source) -> \(target)）が利用できません。"
                            : "The language pair (\(source) -> \(target)) is unavailable.",
                        offersSettingsShortcut: false
                    )
                default:
                    break
                }
            }

            return UserAlert(
                title: isJapaneseLocale ? "翻訳言語データを確認してください" : "Check Translation Language Data",
                message: isJapaneseLocale
                    ? "対象の言語ペアが利用できません。Settingsでダウンロード状況を確認し、完了後に再起動してから再実行してください。"
                    : "The required language pair is unavailable. Check download status in Settings, then relaunch and try again.",
                inlineMessage: isJapaneseLocale
                    ? "言語データのダウンロード状況をSettingsで確認してください。"
                    : "Check language data download status in Settings.",
                offersSettingsShortcut: false
            )
        }

        return nil
    }

    private var isJapaneseLocale: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
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
        let timestamp = Date().ISO8601Format()
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

    private func extractLanguagePair(from message: String) -> (source: String, target: String)? {
        guard let pairRangeStart = message.lastIndex(of: "("),
              let pairRangeEnd = message[pairRangeStart...].firstIndex(of: ")"),
              pairRangeStart < pairRangeEnd else {
            return nil
        }

        let pairBody = String(message[message.index(after: pairRangeStart)..<pairRangeEnd])
        let parts = pairBody.components(separatedBy: "->")
        guard parts.count == 2 else { return nil }

        let source = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let target = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !target.isEmpty else { return nil }
        return (source: source, target: target)
    }

    private func extractRecoveryFailureKind(from message: String) -> String? {
        let marker = "reason="
        guard let range = message.range(of: marker) else { return nil }
        let suffix = message[range.upperBound...]
        let token = suffix.split(separator: " ").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hyphenIndex = trimmed.firstIndex(of: "-") {
            return String(trimmed[..<hyphenIndex])
        }
        if let underscoreIndex = trimmed.firstIndex(of: "_") {
            return String(trimmed[..<underscoreIndex])
        }
        return trimmed
    }

    private func normalizedLineEndings(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func makeStatusNotices(output: TranslationOutput, request: TranslationRequest) -> [StatusNotice] {
        var noticeKinds: [StatusNoticeKind] = []

        let detected = (output.analysis.input.detectedLanguageCode ?? "").lowercased()
        let target = request.targetLanguage.lowercased()
        let isSameLanguageByCode = !detected.isEmpty
            && detected != "und"
            && normalizedLanguageCode(detected) == normalizedLanguageCode(target)
        let allSegmentsFallbackToSource = !output.segmentOutputs.isEmpty
            && output.segmentOutputs.allSatisfy({ $0.isUnsafeFallback && !$0.isUnsafeRecoveredByTranslationFramework })
            && output.translatedText == request.text

        if output.analysis.engineName == "same-language-fallback"
            || (isSameLanguageByCode && allSegmentsFallbackToSource) {
            noticeKinds.append(.sameLanguageUntranslatable)
        }

        if output.segmentOutputs.contains(where: \.isUnsafeRecoveredByTranslationFramework) {
            noticeKinds.append(.aiFallbackToMachineTranslation)
        }

        if detected == "und",
           output.translatedText == request.text,
           output.segmentOutputs.allSatisfy({ $0.isUnsafeFallback }) {
            noticeKinds.append(.unknownSourceLanguage)
        }

        return noticeKinds.map(statusNotice(for:))
    }

    private func statusNotice(for kind: StatusNoticeKind) -> StatusNotice {
        switch kind {
        case .sameLanguageUntranslatable:
            return StatusNotice(
                markerText: "text",
                text: "同一言語のために翻訳できませんでした",
                style: .orange
            )
        case .aiFallbackToMachineTranslation:
            return StatusNotice(
                markerText: "text",
                text: "AI出力できなかったため機械翻訳しました",
                style: .blue
            )
        case .unknownSourceLanguage:
            return StatusNotice(
                markerText: "text",
                text: "元言語が不明だったため翻訳できませんでした",
                style: .orange
            )
        }
    }

    private enum LanguageRole {
        case source
        case target
    }

    private func languageAvailabilityLabel(for code: String, role: LanguageRole) -> String {
        let normalized = normalizedLanguageCode(code)
        if normalized.isEmpty || normalized == "und" {
            switch role {
            case .source:
                return isJapaneseLocale ? "入力言語" : "source language"
            case .target:
                return isJapaneseLocale ? "出力言語" : "target language"
            }
        }
        return code
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
