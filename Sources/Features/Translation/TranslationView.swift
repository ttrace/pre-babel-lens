import SwiftUI

#if os(macOS)
    import AppKit
#endif
#if canImport(Translation)
    import Translation
#endif
#if canImport(UIKit)
    import UIKit
#endif

struct TranslationView: View {
    // #region MARK: MARK:State
    @StateObject private var viewModel: TranslationViewModel
    #if canImport(Translation)
        @ObservedObject private var unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController
    #endif
    @AppStorage("developerModeEnabled") private var developerModeEnabled: Bool = false
    @AppStorage("developerVerboseModeEnabled") private var developerVerboseModeEnabled: Bool = false
    @AppStorage("autoTranslateImportedTextEnabled") private var autoTranslateImportedTextEnabled: Bool = false
    @State private var importToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // #endregion

    // #region MARK: Init
    init(viewModel: TranslationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
        #if canImport(Translation)
        self.unsafeRecoveryController = TranslationFrameworkUnsafeRecoveryController()
        #endif
    }

    #if canImport(Translation)
    init(
        viewModel: TranslationViewModel,
        unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.unsafeRecoveryController = unsafeRecoveryController
    }
    #endif
    // #endregion

    // #region MARK: Body
    var body: some View {
        contentBody
    }

    @ViewBuilder
    private var contentBody: some View {
        let baseView = ZStack(alignment: .top) {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [
                        Color(red: 0.10, green: 0.12, blue: 0.14),
                        Color(red: 0.16, green: 0.19, blue: 0.22),
                    ]
                    : [
                        Color(red: 0.98, green: 0.92, blue: 0.82).opacity(0.98),
                        Color(red: 0.93, green: 0.90, blue: 0.88).opacity(0.98),
                    ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            contentLayout
                .foregroundStyle(colorScheme == .dark ? .white : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            #if os(iOS)
            if let importToastMessage {
                VStack {
                    Spacer()
                    importToast(text: importToastMessage)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 28)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            #endif
        }
        #if canImport(Translation)
        baseView
            .overlay {
                if let configuration = unsafeRecoveryController.configuration {
                    TranslationUnsafeRecoveryTaskHost(
                        configuration: configuration,
                        generation: unsafeRecoveryController.requestGeneration,
                        unsafeRecoveryController: unsafeRecoveryController
                    )
                }
            }
            #if os(iOS)
            .translationViewLifecycleModifiers(
                viewModel: viewModel,
                isJapaneseLocale: isJapaneseLocale,
                handleSharedImportIfNeeded: handleSharedImportIfNeeded
            )
            #else
            .translationViewLifecycleModifiers(
                viewModel: viewModel,
                isJapaneseLocale: isJapaneseLocale,
                handleSharedImportIfNeeded: {}
            )
            #endif
        #else
        baseView
            .translationViewLifecycleModifiers(
                viewModel: viewModel,
                isJapaneseLocale: isJapaneseLocale,
                handleSharedImportIfNeeded: handleSharedImportIfNeeded
            )
        #endif
    }
    // #endregion

    // #region MARK: Layout
    @ViewBuilder
    private var contentLayout: some View {
        #if os(iOS)
        GeometryReader { proxy in
            let contentTopPadding: CGFloat = 8
            let contentBottomPadding: CGFloat = 2
            let verticalGap: CGFloat = 14
            let availableHeight = max(0, proxy.size.height - contentTopPadding - contentBottomPadding)
            let splitHeight = max(140, (availableHeight - verticalGap) / 2)

            VStack(alignment: .leading, spacing: 14) {
                if isWideIOSLayout {
                    HStack(alignment: .top, spacing: 14) {
                        sourceCard
                        outputCard
                    }
                } else {
                    VStack(alignment: .leading, spacing: verticalGap) {
                        sourceCard
                            .frame(height: splitHeight)
                        outputCard
                            .frame(height: splitHeight)
                    }
                }

                if developerModeEnabled {
                    developerPanels
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 12)
            .padding(.top, contentTopPadding)
            .padding(.bottom, contentBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        #else
        VStack(alignment: .leading, spacing: 18) {
            desktopHeader

            HStack(alignment: .top, spacing: 18) {
                sourceCard
                outputCard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if developerModeEnabled {
                developerPanels
            }
        }
        .padding(36)
        .frame(minWidth: 1000)
        #endif
    }

    @ViewBuilder
    private var desktopHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: -6) {
                Text("Pre-Babel Lens")
                    .font(.system(size: 32, weight: .black, design: .serif))
                    .minimumScaleFactor(0.8)
                Text("LOCAL LLM TRANSLATOR")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .kerning(3)
                    .foregroundStyle(Color(red: 0.20, green: 0.35, blue: 0.30))
            }
            Spacer()
            languagePicker
            settingsMenu(iconSize: 24, frameSize: 64)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var mobileHeader: some View {
        EmptyView()
    }

    @ViewBuilder
    private var languagePicker: some View {
        if viewModel.targetLanguageOptions.isEmpty {
            Text("No target languages")
                .foregroundStyle(.secondary)
        } else {
            Picker("Target", selection: $viewModel.targetLanguage) {
                ForEach(viewModel.targetLanguageOptions) { option in
                    Text(option.menuLabel(showCode: developerModeEnabled)).tag(option.code)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var iOSLanguageMenu: some View {
        if viewModel.targetLanguageOptions.isEmpty {
            Text("No target")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Menu {
                ForEach(viewModel.targetLanguageOptions) { option in
                    Button(option.menuLabel(showCode: developerModeEnabled)) {
                        viewModel.targetLanguage = option.code
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(currentTargetLanguageLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func settingsMenu(iconSize: CGFloat, frameSize: CGFloat) -> some View {
        Menu {
            #if os(iOS)
            Toggle(autoTranslateToggleTitle, isOn: $autoTranslateImportedTextEnabled)
            #endif
            Toggle("Developer Mode", isOn: $developerModeEnabled)
            if developerModeEnabled {
                Toggle("Verbose Console", isOn: $developerVerboseModeEnabled)
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(Color(red: 0.35, green: 0.42, blue: 0.34))
                .frame(width: frameSize, height: frameSize)
                .background(.white.opacity(0.85), in: Circle())
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
    }

    @ViewBuilder
    private var developerPanels: some View {
        GroupBox("Process Mode") {
            Picker("Experiment", selection: $viewModel.experimentMode) {
                ForEach(TranslationExperimentMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
        }

        GroupBox("Glossary (source=target)") {
            TextEditor(text: $viewModel.glossaryText)
                .frame(minHeight: 80)
        }

        GroupBox("Indexes") {
            ScrollView {
                Text(indexesText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140)
        }

        GroupBox {
            TextEditor(text: .constant(viewModel.developerLogsText))
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(minHeight: 120, maxHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    colorScheme == .dark ? Color.black.opacity(0.25) : Color.white.opacity(0.45),
                    in: RoundedRectangle(cornerRadius: 12)
                )
        } label: {
            HStack {
                Text("Console")
                Spacer()
                Button("Clear") {
                    viewModel.clearDeveloperLogs()
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.developerLogs.isEmpty)
            }
        }
    }

    private var isWideIOSLayout: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }
    // #endregion

    // #region MARK: Subviews
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Source")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Button("Paste", action: pasteInputFromClipboard)
                    .buttonStyle(.bordered)
                Button("Clear") {
                    viewModel.inputText = ""
                }
                .buttonStyle(.bordered)
            }

            TextEditor(text: $viewModel.inputText)
                .scrollContentBackground(.hidden)
                #if os(iOS)
                .frame(maxHeight: .infinity, alignment: .top)
                #else
                .frame(minHeight: editorMinHeight, maxHeight: .infinity, alignment: .top)
                #endif
                .padding(8)
                .font(.body)
                #if os(iOS)
                .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.30))
                .overlay(
                    RoundedRectangle(cornerRadius: editorCornerRadius)
                        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                )
                #else
                .background(
                    colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: editorCornerRadius)
                )
                #endif

        }
        .padding(cardOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .background(Color.clear)
        #else
        .background(
            colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
            in: RoundedRectangle(cornerRadius: cardCornerRadius)
        )
        #endif
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Output")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                #if os(iOS)
                    iOSLanguageMenu
                #endif

                Button {
                    copyOutputToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .help("Copy output")
                .disabled(viewModel.translatedText.isEmpty)

                Button("Translate") {
                    Task { await viewModel.translate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isTranslating || viewModel.targetLanguageOptions.isEmpty)
            }

            ZStack(alignment: .bottomLeading) {
                ScrollView {
                    Group {
                        if viewModel.translatedText.isEmpty {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
                        } else {
                            Text(styledOutputText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.top, 12)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12 + outputStatusReservedHeight)
                }

                LinearGradient(
                    colors: [
                        outputStatusGradientTopColor,
                        outputStatusBackgroundColor,
                    ],
                    startPoint: UnitPoint(x:0.0, y: 0.0),
                    endPoint: UnitPoint(x:0.0, y: 0.75)
                )
                .frame(maxWidth: .infinity, minHeight: outputStatusBackgroundHeight, maxHeight: outputStatusBackgroundHeight, alignment: .bottom)
                .allowsHitTesting(false)

                outputStatusOverlay
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            #if os(iOS)
            .frame(maxHeight: .infinity, alignment: .top)
            #else
            .frame(minHeight: editorMinHeight, maxHeight: .infinity, alignment: .top)
            #endif
            .clipped()
            #if os(iOS)
            .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.30))
            .overlay(
                RoundedRectangle(cornerRadius: editorCornerRadius)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            #else
            .background(
                colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4),
                in: RoundedRectangle(cornerRadius: editorCornerRadius)
            )
            #endif
        }
        .padding(cardOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .background(Color.clear)
        #else
        .background(
            colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
            in: RoundedRectangle(cornerRadius: cardCornerRadius)
        )
        #endif
    }

    private var styledOutputText: AttributedString {
        guard !viewModel.segmentOutputs.isEmpty else {
            return AttributedString(viewModel.translatedText)
        }

        var result = AttributedString()
        for (index, segment) in viewModel.segmentOutputs.enumerated() {
            var chunk = AttributedString(segment.translatedText + joinerAfterOutputSegment(at: index))
            if segment.isUnsafeFallback {
                chunk.backgroundColor = unsafeSegmentBackgroundColor
                chunk.foregroundColor = unsafeSegmentForegroundColor
            }
            result.append(chunk)
        }
        return result
    }

    private var unsafeSegmentBackgroundColor: Color {
        Color.orange.opacity(colorScheme == .dark ? 0.65 : 0.38)
    }

    private var unsafeSegmentForegroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.82)
            : Color.black.opacity(0.72)
    }

    private func joinerAfterOutputSegment(at index: Int) -> String {
        guard index < viewModel.segmentJoinersAfter.count else { return "" }
        return viewModel.segmentJoinersAfter[index]
    }
    // #endregion

    private var cardOuterPadding: CGFloat {
        #if os(iOS)
        return 0
        #else
        return 22
        #endif
    }

    private var cardCornerRadius: CGFloat {
        #if os(iOS)
        return 0
        #else
        return 26
        #endif
    }

    private var editorCornerRadius: CGFloat {
        #if os(iOS)
        return 0
        #else
        return 18
        #endif
    }

    private var editorMinHeight: CGFloat {
        #if os(iOS)
        return 170
        #else
        return 300
        #endif
    }

    // #region MARK: Derived Text
    private var indexesText: String {
        [
            "Engine: \(viewModel.engineName.isEmpty ? "(none)" : viewModel.engineName)",
            "Mode: \(viewModel.experimentMode.displayName)",
            "Detected language: \(viewModel.detectedLanguageCode.isEmpty ? "(none)" : viewModel.detectedLanguageCode)",
            "Language support index: \(viewModel.aiLanguageSupported ? "supported" : "unsupported")",
            "Processing time index: \(processingTimeIndex)",
            "Protected tokens: \(viewModel.protectedTokens.count)",
            "Glossary matches: \(viewModel.glossaryMatches.count)",
            "Ambiguity hints: \(viewModel.ambiguityHints.count)",
            "Trace steps: \(viewModel.traces.count)",
        ].joined(separator: "\n")
    }

    private var processingTimeIndex: String {
        let timingTrace = viewModel.traces.first(where: { $0.step.contains("processing-time") })
            ?? viewModel.traces.last(where: { $0.step.contains("processing-time") })
        return timingTrace?.summary ?? "(n/a)"
    }
    // #endregion

    private var outputStatusReservedHeight: CGFloat { 46 }
    private var outputStatusBackgroundHeight: CGFloat { 84 }

    private var outputStatusBackgroundColor: Color {
        outputEditorBackgroundColor
    }

    private var outputStatusGradientTopColor: Color {
        outputEditorBackgroundColor.opacity(0.0)
    }

    private var outputEditorBackgroundColor: Color {
        if colorScheme == .dark {
            return Color(red: 68.0 / 255.0, green: 71.0 / 255.0, blue: 79.0 / 255.0)
        }
        #if os(iOS)
        return Color(red: 247.0 / 255.0, green: 238.0 / 255.0, blue: 225.0 / 255.0)
        #else
        return Color(red: 253.0 / 255.0, green: 251.0 / 255.0, blue: 247.0 / 255.0)
        #endif
    }

    @ViewBuilder
    private var outputStatusOverlay: some View {
        if let error = viewModel.errorMessage {
            Text(error)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(1)
        } else {
            HStack(spacing: 10) {
                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.20, green: 0.35, blue: 0.30))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if viewModel.isTranslating {
                    Button {
                        viewModel.stopTranslation()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var currentTargetLanguageLabel: String {
        if let selected = viewModel.targetLanguageOptions.first(where: { $0.code == viewModel.targetLanguage }) {
            return selected.menuLabel(showCode: developerModeEnabled)
        }
        return "Target"
    }

    // #region MARK: Clipboard Actions
    private func copyOutputToClipboard() {
        #if os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(viewModel.translatedText, forType: .string)
        #elseif canImport(UIKit)
            UIPasteboard.general.string = viewModel.translatedText
        #endif
    }

    private func pasteInputFromClipboard() {
        #if os(macOS)
            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                viewModel.inputText = text
            }
        #elseif canImport(UIKit)
            if let text = UIPasteboard.general.string, !text.isEmpty {
                viewModel.inputText = text
            }
        #endif
    }
    // #endregion

    #if os(iOS)
    @ViewBuilder
    private func importToast(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color.black.opacity(0.82), in: Capsule())
    }

    private func handleSharedImportIfNeeded() {
        guard viewModel.importSharedTextIfNeeded() != nil else { return }
        showImportToast()
        guard autoTranslateImportedTextEnabled else { return }
        Task { await viewModel.translate() }
    }

    private func showImportToast() {
        toastDismissTask?.cancel()
        importToastMessage = sharedImportToastTitle
        toastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    importToastMessage = nil
                }
            }
        }
    }

    private var autoTranslateToggleTitle: String {
        isJapaneseLocale ? "共有取り込み後に自動翻訳" : "Auto Translate After Import"
    }

    private var sharedImportToastTitle: String {
        isJapaneseLocale ? "共有テキストを取り込みました" : "Shared text imported."
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    #endif

    private var isJapaneseLocale: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }
}

#if canImport(Translation)
private struct TranslationUnsafeRecoveryTaskHost: View {
    let configuration: TranslationSession.Configuration
    let generation: UUID
    let unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .id(generation)
            .translationTask(configuration) { session in
                await unsafeRecoveryController.processPendingRequest(using: session)
            }
    }
}
#endif

private extension View {
    @ViewBuilder
    func translationViewLifecycleModifiers(
        viewModel: TranslationViewModel,
        isJapaneseLocale: Bool,
        handleSharedImportIfNeeded: @escaping () -> Void
    ) -> some View {
        #if os(macOS)
        self
            .frame(minHeight: 680)
            .task {
                if viewModel.consumeLaunchActivationRequest() {
                    NSApp.activate(ignoringOtherApps: true)
                }
                await viewModel.translateIfNeededOnLaunch()
            }
        #elseif os(iOS)
        self
            .task {
                handleSharedImportIfNeeded()
                await viewModel.translateIfNeededOnLaunch()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                handleSharedImportIfNeeded()
            }
            .alert(item: Binding(get: { viewModel.userAlert }, set: { _ in viewModel.dismissUserAlert() })) { alert in
                if alert.offersSettingsShortcut {
                    return Alert(
                        title: Text(alert.title),
                        message: Text(alert.message),
                        primaryButton: .default(Text(isJapaneseLocale ? "Settings を開く" : "Open Settings")) {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        },
                        secondaryButton: .cancel(Text(isJapaneseLocale ? "閉じる" : "Close")) {
                            viewModel.dismissUserAlert()
                        }
                    )
                }

                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text(isJapaneseLocale ? "OK" : "OK")) {
                        viewModel.dismissUserAlert()
                    }
                )
            }
        #else
        self
            .task {
                await viewModel.translateIfNeededOnLaunch()
            }
        #endif
    }
}
