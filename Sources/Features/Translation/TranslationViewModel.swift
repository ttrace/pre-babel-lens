import Foundation
#if canImport(Translation)
@preconcurrency import Translation
#endif

enum AppLocalization {
    static func localized(_ key: String, defaultValue: String) -> String {
        for bundle in candidateBundles {
            let value = bundle.localizedString(forKey: key, value: nil, table: nil)
            if value != key {
                return value
            }
        }
        return defaultValue
    }

    private static let candidateBundles: [Bundle] = {
        var bundles: [Bundle] = []
        var seenPaths: Set<String> = []

        func appendBundle(_ bundle: Bundle) {
            let path = bundle.bundlePath
            if seenPaths.insert(path).inserted {
                bundles.append(bundle)
            }
        }

        appendBundle(.main)

        // SwiftPM resources for macOS app builds are packaged under
        // Contents/Resources/*.bundle (for example PreBabelLens_PreBabelLens.bundle).
        // Search only inside the app's own resource directory to avoid touching
        // workspace paths (Documents) that can trigger privacy prompts.
        if let resourceURL = Bundle.main.resourceURL,
           let urls = try? FileManager.default.contentsOfDirectory(
                at: resourceURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
           ) {
            for url in urls where url.pathExtension == "bundle" {
                guard let bundle = Bundle(url: url) else { continue }
                if bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "en") != nil
                    || bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: "ja") != nil
                {
                    appendBundle(bundle)
                }
            }
        }

        appendBundle(Bundle(for: BundleToken.self))

        return bundles
    }()
}

private final class BundleToken {}

@MainActor
final class TranslationViewModel: ObservableObject {
    private enum AppStateKey {
        static let targetLanguage = "appState.targetLanguage"
        static let experimentMode = "appState.experimentMode"
        static let recentTargetLanguages = "appState.recentTargetLanguages"
    }

    enum StatusNoticeKind: Equatable {
        case sameLanguageUntranslatable
        case aiFallbackToMachineTranslation
        case aiFallbackToMachineTranslationUnavailable
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

    enum TFMenuAvailabilityStatus: Equatable {
        case unknown
        case installed
        case supported
        case unsupported
    }

    @Published var targetLanguage: String {
        didSet {
            persistTargetLanguageSelection()
        }
    }
    @Published var experimentMode: TranslationExperimentMode {
        didSet {
            persistExperimentModeSelection()
        }
    }
    @Published var inputText: String = ""
    @Published var glossaryText: String = ""

    @Published var translatedText: String = ""
    @Published var segmentOutputs: [SegmentOutput] = []
    @Published var segmentJoinersAfter: [String] = []
    @Published var sourceSegments: [TextSegment] = []
    @Published var sourceTextSnapshotForSegments: String = ""
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
    @Published private(set) var tfMenuAvailabilityByTarget: [String: TFMenuAvailabilityStatus] = [:]
    @Published private(set) var tfMenuUnsupportedHintMessage: String?
    #if os(macOS)
    @Published var macImportLoadingHUDVisible: Bool = false
    @Published var macImportHUDMessage: String?
    #endif
    #if canImport(Translation)
    @Published private(set) var tfMenuPreparationConfiguration: TranslationSession.Configuration?
    @Published private(set) var tfMenuPreparationGeneration: UUID = UUID()
    #endif

    private let orchestrator: TranslationOrchestrator
    private let iOSEnginePolicy: IOSAdaptiveTranslationEnginePolicy?
    private let userDefaults: UserDefaults
    private let preferredLanguages: [String]
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
    private var tfMenuAvailabilityTask: Task<Void, Never>?
    private var tfMenuInputRefreshTask: Task<Void, Never>?
    private var tfMenuPreparationTargetLanguageCode: String?
    private var lastMenuSourceLanguageCode: String?
    private var recentTargetLanguageCodes: [String]

    init(
        orchestrator: TranslationOrchestrator,
        iOSEnginePolicy: IOSAdaptiveTranslationEnginePolicy? = nil,
        launchInputText: String? = nil,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.userDefaults = userDefaults
        self.iOSEnginePolicy = iOSEnginePolicy
        self.preferredLanguages = preferredLanguages
        self.recentTargetLanguageCodes = userDefaults.stringArray(forKey: AppStateKey.recentTargetLanguages) ?? []
        self.experimentMode = TranslationExperimentMode(
            rawValue: userDefaults.string(forKey: AppStateKey.experimentMode) ?? ""
        ) ?? .segmented
        let initialOptions = AppleIntelligenceLanguageCatalog.translationFrameworkLanguageOptions()
        let persistedTargetLanguage = userDefaults.string(forKey: AppStateKey.targetLanguage)
        if
            let persistedTargetLanguage,
            initialOptions.contains(where: { $0.code == persistedTargetLanguage })
        {
            self.targetLanguage = persistedTargetLanguage
        } else {
            self.targetLanguage = Self.preferredDefaultTargetLanguageCode(
                from: initialOptions,
                preferredLanguages: preferredLanguages
            ) ?? "en-US"
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
        refreshTFMenuAvailabilityIfNeeded()
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

    #if os(macOS)
    func setMacImportLoadingHUDVisible(_ visible: Bool) {
        macImportLoadingHUDVisible = visible
        if visible {
            macImportHUDMessage = nil
        }
    }

    func showMacImportHUDMessage(_ message: String) {
        macImportHUDMessage = message
    }

    func clearMacImportHUDMessage() {
        macImportHUDMessage = nil
    }
    #endif

    func handleDoubleCopyText(_ text: String) async {
        await handleExternalTriggerText(text, source: "double-copy")
    }

    func refreshEnginePreference() {
        guard let iOSEnginePolicy else {
            isAppleIntelligenceAvailable = false
            usesAppleIntelligenceTranslation = false
            targetLanguageOptions = AppleIntelligenceLanguageCatalog.translationFrameworkLanguageOptions()
            normalizeTargetLanguageSelection()
            refreshTFMenuAvailabilityIfNeeded()
            return
        }

        isAppleIntelligenceAvailable = iOSEnginePolicy.isFoundationModelsAvailable()
        usesAppleIntelligenceTranslation = iOSEnginePolicy.currentPreferredMode() == .foundationModels && isAppleIntelligenceAvailable
        targetLanguageOptions = usesAppleIntelligenceTranslation
            ? AppleIntelligenceLanguageCatalog.supportedLanguageOptions()
            : AppleIntelligenceLanguageCatalog.translationFrameworkLanguageOptions()
        normalizeTargetLanguageSelection()
        pruneRecentTargetLanguageCodes()
        refreshTFMenuAvailabilityIfNeeded()
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

    func tfMenuStatus(for targetLanguageCode: String) -> TFMenuAvailabilityStatus {
        guard !usesAppleIntelligenceTranslation else { return .installed }
        return tfMenuAvailabilityByTarget[targetLanguageCode] ?? .unknown
    }

    func tfMenuDownloadMark(for targetLanguageCode: String) -> String? {
        tfMenuStatus(for: targetLanguageCode) == .supported ? "⬇︎" : nil
    }

    func isTargetLanguageSelectionDisabled(_ targetLanguageCode: String) -> Bool {
        tfMenuStatus(for: targetLanguageCode) == .unsupported
    }

    func targetLanguageSelectionHelpText(for targetLanguageCode: String) -> String? {
        switch tfMenuStatus(for: targetLanguageCode) {
        case .supported:
            return localizedDownloadHintText
        case .unsupported:
            return unsupportedPairHintText(for: targetLanguageCode)
        case .unknown, .installed:
            return nil
        }
    }

    func selectTargetLanguageFromMenu(_ targetLanguageCode: String) {
        switch tfMenuStatus(for: targetLanguageCode) {
        case .unsupported:
            tfMenuUnsupportedHintMessage = unsupportedPairHintText(for: targetLanguageCode)
        case .supported:
            targetLanguage = targetLanguageCode
            recordRecentTargetLanguageSelection(targetLanguageCode)
            tfMenuUnsupportedHintMessage = unsupportedPairHintTextIfNeeded()
            #if canImport(Translation)
            requestTFLanguagePackDownload(for: targetLanguageCode)
            #endif
        case .installed, .unknown:
            targetLanguage = targetLanguageCode
            recordRecentTargetLanguageSelection(targetLanguageCode)
            tfMenuUnsupportedHintMessage = unsupportedPairHintTextIfNeeded()
        }
    }

    func recentTargetLanguageOptions(limit: Int = 4) -> [TargetLanguageOption] {
        guard !targetLanguageOptions.isEmpty else { return [] }
        guard limit > 0 else { return [] }

        let optionByCode = Dictionary(uniqueKeysWithValues: targetLanguageOptions.map { ($0.code, $0) })
        return recentTargetLanguageCodes
            .prefix(limit)
            .compactMap { optionByCode[$0] }
    }

    func remainingTargetLanguageOptionsExcludingRecent(limit: Int = 4) -> [TargetLanguageOption] {
        let recentCodes = Set(recentTargetLanguageOptions(limit: limit).map(\.code))
        return targetLanguageOptions.filter { !recentCodes.contains($0.code) }
    }

    func handleSourceTextEdited(previousText: String, currentText: String) {
        guard previousText != currentText else { return }
        scheduleTFMenuAvailabilityRefresh()
    }

    func handleSourceTextPasted(_ text: String) {
        let normalized = normalizedLineEndings(in: text)
        inputText = normalized
        refreshLanguageMenuSourceLanguage()
    }

    func refreshLanguageMenuSourceLanguage() {
        let normalized = normalizedLineEndings(in: inputText)
        if inputText != normalized {
            inputText = normalized
        }

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            detectedLanguageCode = ""
            refreshTFMenuAvailabilityIfNeeded()
            return
        }

        let detection = HeuristicLanguageDetector.detectLanguage(text: normalized)
        let normalizedDetected = normalizedLanguageCode(detection.detectedLanguageCode)
        let normalizedTarget = normalizedLanguageCode(targetLanguage)

        if
            !normalizedDetected.isEmpty,
            normalizedDetected != "und",
            normalizedDetected == normalizedTarget,
            let previousSource = lastMenuSourceLanguageCode,
            previousSource != normalizedDetected,
            let fallbackTargetCode = targetLanguageOptions.first(where: { normalizedLanguageCode($0.code) == previousSource })?.code
        {
            targetLanguage = fallbackTargetCode
        }

        detectedLanguageCode = detection.detectedLanguageCode
        if !normalizedDetected.isEmpty, normalizedDetected != "und" {
            lastMenuSourceLanguageCode = normalizedDetected
        }
        refreshTFMenuAvailabilityIfNeeded()
    }

    func clearSourceTextAndResetLanguageState() {
        resetTranslationRuntimeStateForClear()
        inputText = ""
        translatedText = ""
        segmentOutputs = []
        segmentJoinersAfter = []
        sourceSegments = []
        sourceTextSnapshotForSegments = ""
        traces = []
        protectedTokens = []
        glossaryMatches = []
        ambiguityHints = []
        engineName = ""
        detectedLanguageCode = ""
        errorMessage = nil
        userAlert = nil
        statusNotices = []
        status = .ready
        aiLanguageSupported = true
        tfMenuUnsupportedHintMessage = nil
        lastMenuSourceLanguageCode = nil
        refreshTFMenuAvailabilityIfNeeded()
    }

    var shouldShowIOSTFUnsupportedHint: Bool {
        !usesAppleIntelligenceTranslation
            && tfMenuAvailabilityByTarget.values.contains(.unsupported)
            && !(tfMenuUnsupportedHintMessage ?? "").isEmpty
    }

    var iosTFUnsupportedHintMessage: String {
        tfMenuUnsupportedHintMessage ?? unsupportedPairHintText(for: targetLanguage)
    }

    #if canImport(Translation)
    func tfMenuPreparationTargetCode(for generation: UUID) -> String? {
        guard generation == tfMenuPreparationGeneration else { return nil }
        guard tfMenuPreparationConfiguration != nil else { return nil }
        return tfMenuPreparationTargetLanguageCode
    }

    func completeTFMenuPreparation(
        generation: UUID,
        targetCode: String,
        errorDescription: String?
    ) {
        guard generation == tfMenuPreparationGeneration else { return }
        if let errorDescription {
            appendDeveloperLog("tf-menu: language-pack prepare failed target=\(targetCode) | \(errorDescription)")
        } else {
            appendDeveloperLog("tf-menu: language-pack prepared target=\(targetCode)")
        }
        tfMenuPreparationConfiguration = nil
        tfMenuPreparationTargetLanguageCode = nil
        refreshTFMenuAvailabilityIfNeeded()
    }
    #endif

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
            persistTargetLanguageSelection()
            return
        }
        targetLanguage = Self.preferredDefaultTargetLanguageCode(
            from: targetLanguageOptions,
            preferredLanguages: preferredLanguages
        ) ?? targetLanguageOptions[0].code
    }

    private func recordRecentTargetLanguageSelection(_ code: String) {
        guard !code.isEmpty else { return }
        recentTargetLanguageCodes.removeAll { $0 == code }
        recentTargetLanguageCodes.insert(code, at: 0)
        if recentTargetLanguageCodes.count > 8 {
            recentTargetLanguageCodes = Array(recentTargetLanguageCodes.prefix(8))
        }
        persistRecentTargetLanguageSelections()
    }

    private func pruneRecentTargetLanguageCodes() {
        guard !recentTargetLanguageCodes.isEmpty else { return }
        let validCodes = Set(targetLanguageOptions.map(\.code))
        recentTargetLanguageCodes = recentTargetLanguageCodes.filter { validCodes.contains($0) }
        persistRecentTargetLanguageSelections()
    }

    private func persistTargetLanguageSelection() {
        guard !targetLanguage.isEmpty else { return }
        userDefaults.set(targetLanguage, forKey: AppStateKey.targetLanguage)
    }

    private func persistExperimentModeSelection() {
        userDefaults.set(experimentMode.rawValue, forKey: AppStateKey.experimentMode)
    }

    private func persistRecentTargetLanguageSelections() {
        userDefaults.set(recentTargetLanguageCodes, forKey: AppStateKey.recentTargetLanguages)
    }

    private static func preferredDefaultTargetLanguageCode(
        from options: [TargetLanguageOption],
        preferredLanguages: [String]
    ) -> String? {
        guard !options.isEmpty else { return nil }

        for preferred in preferredLanguages {
            if let matched = matchingTargetLanguageCode(for: preferred, in: options) {
                return matched
            }
        }

        if let englishUS = matchingTargetLanguageCode(for: "en-US", in: options) {
            return englishUS
        }
        if let english = matchingTargetLanguageCode(for: "en", in: options) {
            return english
        }
        return options.first?.code
    }

    private static func matchingTargetLanguageCode(for rawCode: String, in options: [TargetLanguageOption]) -> String? {
        let normalized = normalizedLanguageIdentifier(rawCode)
        guard !normalized.isEmpty else { return nil }

        let optionPairs: [(code: String, normalized: String)] = options.map {
            ($0.code, normalizedLanguageIdentifier($0.code))
        }

        for candidate in preferredLanguageCandidates(from: normalized) {
            if let matched = optionPairs.first(where: { $0.normalized == candidate }) {
                return matched.code
            }
        }

        let base = normalizedLanguageCode(normalized)
        guard !base.isEmpty else { return nil }
        return optionPairs.first(where: { normalizedLanguageCode($0.normalized) == base })?.code
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
            preferredLanguages: preferredLanguages,
            experimentMode: experimentMode,
            usesAITranslation: usesAppleIntelligenceTranslation
        )

        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            segmentOutputs = []
            segmentJoinersAfter = []
            sourceSegments = []
            sourceTextSnapshotForSegments = ""
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
            refreshTFMenuAvailabilityIfNeeded()
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
        sourceSegments = []
        sourceTextSnapshotForSegments = ""
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
            sourceSegments = output.analysis.input.segments
            sourceTextSnapshotForSegments = output.analysis.input.originalText
            traces = output.analysis.traces
            protectedTokens = output.analysis.input.protectedTokens
            glossaryMatches = output.analysis.input.glossaryMatches
            ambiguityHints = output.analysis.input.ambiguityHints
            engineName = output.analysis.engineName
            detectedLanguageCode = output.analysis.input.detectedLanguageCode ?? ""
            refreshTFMenuAvailabilityIfNeeded()
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
                refreshTFMenuAvailabilityIfNeeded()
                aiLanguageSupported = false
            }
            if let alert = userAlert(for: pipelineError) {
                userAlert = alert
                errorMessage = alert.inlineMessage
            } else {
                errorMessage = pipelineError.localizedDescription
            }
            statusNotices = []
            status = .ready
            appendSessionLog("pipeline-error: \(pipelineError.localizedDescription)")
        } catch {
            if let alert = userAlert(for: error) {
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

    private func userAlert(for error: Error) -> UserAlert? {
        let nsError = error as NSError
        let debugDescription = (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
        let combined = "\(debugDescription) \(nsError.localizedDescription)".lowercased()

        let isTranslationServiceConnectionError =
            (nsError.domain == NSCocoaErrorDomain && nsError.code == 4097)
            || combined.contains("com.apple.translation.text")
            || combined.contains("availablelocalepairsfortask")
            || combined.contains("connection to service")
            || combined.contains("translationd")

        if isTranslationServiceConnectionError {
            return UserAlert(
                title: isJapaneseLocale
                    ? "翻訳サービスに接続できません"
                    : "Translation Service Unavailable",
                message: isJapaneseLocale
                    ? "システムの翻訳サービスに接続できませんでした。しばらく待って再試行してください。\n\n改善しない場合は、Settingsで言語データのダウンロード状況を確認し、アプリを再起動してから再度お試しください。"
                    : "Could not connect to the system translation service. Please wait a moment and try again.\n\nIf the issue continues, check language data downloads in Settings, relaunch the app, and try again.",
                inlineMessage: isJapaneseLocale
                    ? "翻訳サービスに接続できません。再試行してください。"
                    : "Translation service is unavailable. Please retry.",
                offersSettingsShortcut: true
            )
        }

        return userAlert(forLocalizedDescription: error.localizedDescription)
    }

    private func userAlert(forLocalizedDescription localizedDescription: String) -> UserAlert? {
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
                    title: localized("alert.same_language_pair.title", defaultValue: "Same Language Pair"),
                    message: String(
                        format: localized(
                            "alert.same_language_pair.message_format",
                            defaultValue: "The source and target language are the same (%@). Select a different target language and try again."
                        ),
                        pairLabel
                    ),
                    inlineMessage: String(
                        format: localized(
                            "alert.same_language_pair.inline_format",
                            defaultValue: "Cannot translate with the same language pair (%@)."
                        ),
                        pairLabel
                    ),
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

    private func resetTranslationRuntimeStateForClear() {
        let taskToDrain = activeTranslationTask
        taskToDrain?.cancel()
        activeTranslationTask = nil
        activeTranslationToken = nil
        isTranslating = false

        if let taskToDrain {
            Task { @MainActor [weak self] in
                await taskToDrain.value
                self?.appendDeveloperLog("clear: previous translation task drained")
            }
        }

        pendingTranslationRequestStartedAt = nil
        partialTranslationsBySegment = [:]
        partialJoinersAfter = []
        tfMenuAvailabilityTask?.cancel()
        tfMenuAvailabilityTask = nil
        tfMenuInputRefreshTask?.cancel()
        tfMenuInputRefreshTask = nil
        #if canImport(Translation)
        tfMenuPreparationConfiguration = nil
        tfMenuPreparationTargetLanguageCode = nil
        tfMenuPreparationGeneration = UUID()
        #endif
        resetSessionMetricsState()
        appendDeveloperLog("clear: runtime cache/session state reset")
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

    private static func normalizedLanguageCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hyphenIndex = trimmed.firstIndex(of: "-") {
            return String(trimmed[..<hyphenIndex])
        }
        if let underscoreIndex = trimmed.firstIndex(of: "_") {
            return String(trimmed[..<underscoreIndex])
        }
        return trimmed
    }

    private static func normalizedLanguageIdentifier(_ code: String) -> String {
        let normalized = code
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        switch normalized {
        case "en-uk":
            return "en-gb"
        default:
            return normalized
        }
    }

    private static func preferredLanguageCandidates(from normalizedIdentifier: String) -> [String] {
        let parts = normalizedIdentifier.split(separator: "-").map(String.init)
        guard let language = parts.first, !language.isEmpty else { return [] }

        var script: String?
        var region: String?

        for part in parts.dropFirst() {
            if part.count == 4 {
                script = part.lowercased()
            } else if part.count == 2 || part.count == 3 {
                region = part.uppercased()
            }
        }

        if script == nil, let inferred = inferredChineseScript(language: language, region: region) {
            script = inferred
        }

        var candidates: [String] = [normalizedIdentifier]
        if let script {
            if let region {
                candidates.append("\(language)-\(script)-\(region.lowercased())")
            }
            candidates.append("\(language)-\(script)")
        }
        if let region {
            candidates.append("\(language)-\(region.lowercased())")
        }
        candidates.append(language)

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    private static func inferredChineseScript(language: String, region: String?) -> String? {
        guard language == "zh", let region else { return nil }
        switch region.uppercased() {
        case "TW", "HK", "MO":
            return "hant"
        case "CN", "SG", "MY":
            return "hans"
        default:
            return nil
        }
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        Self.normalizedLanguageCode(code)
    }

    private func normalizedLanguageIdentifier(_ code: String) -> String {
        Self.normalizedLanguageIdentifier(code)
    }

    private func normalizedLineEndings(in text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private func refreshTFMenuAvailabilityIfNeeded() {
        tfMenuAvailabilityTask?.cancel()

        guard !usesAppleIntelligenceTranslation else {
            tfMenuAvailabilityByTarget = [:]
            tfMenuUnsupportedHintMessage = nil
            return
        }

        guard !targetLanguageOptions.isEmpty else {
            tfMenuAvailabilityByTarget = [:]
            tfMenuUnsupportedHintMessage = nil
            return
        }

        #if canImport(Translation)
        let options = targetLanguageOptions
        let sourceText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedSourceCode = normalizedLanguageCode(detectedLanguageCode)

        tfMenuAvailabilityTask = Task { [weak self] in
            guard let self else { return }
            var updated: [String: TFMenuAvailabilityStatus] = [:]

            for option in options {
                if Task.isCancelled { return }
                let status = await Self.resolveTFMenuAvailabilityStatus(
                    detectedSourceCode: detectedSourceCode,
                    sourceText: sourceText,
                    targetCode: option.code
                )
                updated[option.code] = status
            }

            if Task.isCancelled { return }
            await MainActor.run {
                self.tfMenuAvailabilityByTarget = updated
                self.tfMenuUnsupportedHintMessage = self.unsupportedPairHintTextIfNeeded()
            }
        }
        #else
        tfMenuAvailabilityByTarget = Dictionary(
            uniqueKeysWithValues: targetLanguageOptions.map { ($0.code, .installed) }
        )
        tfMenuUnsupportedHintMessage = nil
        #endif
    }

    private func scheduleTFMenuAvailabilityRefresh() {
        tfMenuInputRefreshTask?.cancel()
        tfMenuInputRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            await MainActor.run {
                self?.refreshTFMenuAvailabilityIfNeeded()
            }
        }
    }

    #if canImport(Translation)
    nonisolated private static func resolveTFMenuAvailabilityStatus(
        detectedSourceCode: String,
        sourceText: String,
        targetCode: String
    ) async -> TFMenuAvailabilityStatus {
        let availability = LanguageAvailability()
        guard let targetLanguage = localeLanguage(from: targetCode) else {
            return .unsupported
        }

        if !detectedSourceCode.isEmpty,
           detectedSourceCode != "und",
           let sourceLanguage = localeLanguage(from: detectedSourceCode)
        {
            let status = await availability.status(from: sourceLanguage, to: targetLanguage)
            return tfMenuAvailabilityStatus(from: status)
        }

        guard !sourceText.isEmpty else {
            return .unknown
        }

        do {
            let status = try await availability.status(for: sourceText, to: targetLanguage)
            return tfMenuAvailabilityStatus(from: status)
        } catch {
            return .unknown
        }
    }

    nonisolated private static func tfMenuAvailabilityStatus(from status: LanguageAvailability.Status) -> TFMenuAvailabilityStatus {
        switch status {
        case .installed:
            return .installed
        case .supported:
            return .supported
        case .unsupported:
            return .unsupported
        @unknown default:
            return .unknown
        }
    }

    private func requestTFLanguagePackDownload(for targetLanguageCode: String) {
        guard let targetLanguage = Self.localeLanguage(from: targetLanguageCode) else { return }

        var configuration = TranslationSession.Configuration(
            source: Self.localeLanguage(from: normalizedLanguageCode(detectedLanguageCode)),
            target: targetLanguage
        )
        configuration.invalidate()
        tfMenuPreparationTargetLanguageCode = targetLanguageCode
        tfMenuPreparationGeneration = UUID()
        tfMenuPreparationConfiguration = configuration
        appendDeveloperLog("tf-menu: request language-pack download target=\(targetLanguageCode)")
    }

    nonisolated private static func localeLanguage(from rawCode: String) -> Locale.Language? {
        let trimmed = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Locale.Language(identifier: trimmed)
    }
    #endif

    private func unsupportedPairHintTextIfNeeded() -> String? {
        guard let firstUnsupportedTarget = tfMenuAvailabilityByTarget.first(where: { $0.value == .unsupported })?.key else {
            return nil
        }
        return unsupportedPairHintText(for: firstUnsupportedTarget)
    }

    private func unsupportedPairHintText(for targetLanguageCode: String) -> String {
        let sourceName = sourceLanguageDisplayNameForMenu()
        let targetName = targetLanguageDisplayNameForMenu(code: targetLanguageCode)
        return String(
            format: localized("tf.menu.unsupported_pair_format", defaultValue: "Cannot translate from %@ to %@."),
            sourceName,
            targetName
        )
    }

    private var localizedDownloadHintText: String {
        localized("tf.menu.download_hint", defaultValue: "Downloads the language pack.")
    }

    private func sourceLanguageDisplayNameForMenu() -> String {
        let normalizedDetected = normalizedLanguageCode(detectedLanguageCode)
        if !normalizedDetected.isEmpty, normalizedDetected != "und" {
            return languageDisplayName(for: normalizedDetected)
        }
        return localized("tf.menu.source_language_fallback", defaultValue: "source language")
    }

    private func targetLanguageDisplayNameForMenu(code: String) -> String {
        let normalized = normalizedLanguageCode(code)
        guard !normalized.isEmpty, normalized != "und" else {
            return localized("tf.menu.target_language_fallback", defaultValue: "target language")
        }
        return languageDisplayName(for: normalized)
    }

    private func languageDisplayName(for code: String) -> String {
        let localeID = Locale.preferredLanguages.first ?? "en"
        let locale = Locale(identifier: localeID)
        return locale.localizedString(forLanguageCode: code) ?? code
    }

    private func localized(_ key: String, defaultValue: String) -> String {
        AppLocalization.localized(key, defaultValue: defaultValue)
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

        let tfRecoveryUnavailableAfterAIFallback = request.usesAITranslation
            && output.segmentOutputs.contains(where: { $0.isUnsafeFallback && !$0.isUnsafeRecoveredByTranslationFramework })
            && !output.segmentOutputs.contains(where: \.isUnsafeRecoveredByTranslationFramework)
            && output.analysis.engineName != "same-language-fallback"
        if tfRecoveryUnavailableAfterAIFallback {
            noticeKinds.append(.aiFallbackToMachineTranslationUnavailable)
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
                text: localized(
                    "status.notice.same_language_untranslatable",
                    defaultValue: "Could not translate because source and target are the same language."
                ),
                style: .orange
            )
        case .aiFallbackToMachineTranslation:
            return StatusNotice(
                markerText: "text",
                text: localized(
                    "status.notice.ai_fallback_to_tf",
                    defaultValue: "AI translation could not complete, so machine translation was used."
                ),
                style: .blue
            )
        case .aiFallbackToMachineTranslationUnavailable:
            return StatusNotice(
                markerText: "text",
                text: localized(
                    "status.notice.ai_fallback_to_tf",
                    defaultValue: "AI translation could not complete, so machine translation was used."
                ),
                style: .orange
            )
        case .unknownSourceLanguage:
            return StatusNotice(
                markerText: "text",
                text: localized(
                    "status.notice.unknown_source_language",
                    defaultValue: "Could not translate because the source language could not be detected."
                ),
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
                return localized("tf.menu.source_language_fallback", defaultValue: "source language")
            case .target:
                return localized("tf.menu.target_language_fallback", defaultValue: "target language")
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
