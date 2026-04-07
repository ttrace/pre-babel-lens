import SwiftUI

#if os(macOS)
    import AppKit
    import CoreServices
    #if canImport(PDFKit)
        import PDFKit
    #endif
#endif
#if canImport(Translation)
    import Translation
#endif
#if canImport(UIKit)
    import UIKit
#endif

struct TranslationView: View {
    #if os(iOS)
    private enum FocusedField: Hashable {
        case source
    }

    private enum PinchOverlayHost {
        case source
        case output
    }
    #endif

    // #region MARK: MARK:State
    @StateObject private var viewModel: TranslationViewModel
    #if canImport(Translation)
        @ObservedObject private var unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController
    #endif
    @AppStorage("developerModeEnabled") private var developerModeEnabled: Bool = false
    @AppStorage("developerVerboseModeEnabled") private var developerVerboseModeEnabled: Bool = false
    @AppStorage("autoTranslateImportedTextEnabled") private var autoTranslateImportedTextEnabled: Bool = false
    @AppStorage("clutchModeEnabled") private var clutchModeEnabled: Bool = true
    @AppStorage("editorFontScaleLevel") private var editorFontScaleLevel: Int = EditorFontScaleLevel.medium.rawValue
    @State private var importToastMessage: String?
    @State private var toastDismissTask: Task<Void, Never>?
    @State private var isMacCompactLayoutActive: Bool = false
    @State private var isIOSDesktopLayoutActive: Bool = false
    @State private var isCompactStackedLayoutActive: Bool = false
    @State private var isCompactOutputReadingMode: Bool = false
    @State private var isOutputCollapseDragActive: Bool = false
    @State private var didCollapseDuringCurrentDrag: Bool = false
    @State private var hasReachedTopEdgeSinceCollapse: Bool = false
    @State private var currentOutputScrollDistance: CGFloat = 0
    @State private var isOutputExpandSpringArmed: Bool = false
    @State private var clutchSelectedSegmentIndex: Int?
    @State private var sourceHighlightRange: NSRange?
    @State private var clutchSelectionOrigin: ClutchSelectionOrigin?
    #if os(macOS)
    @State private var macTopEdgeWheelMonitor: Any?
    #endif
    #if os(iOS)
    @State private var pinchBaseFontScaleLevel: Int?
    @State private var pinchOverlayHost: PinchOverlayHost?
    @State private var pinchOverlayText: String?
    @State private var pinchOverlayDismissTask: Task<Void, Never>?
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #if os(iOS)
    @FocusState private var focusedField: FocusedField?
    #endif
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
        .onChange(of: viewModel.isTranslating) { _, isTranslating in
            if isTranslating {
                disableCompactOutputReadingModeIfNeeded()
            }
        }
        .onChange(of: viewModel.translatedText) { _, translatedText in
            if translatedText.isEmpty {
                disableCompactOutputReadingModeIfNeeded()
                resetClutchSelection()
            }
        }
        .onChange(of: viewModel.segmentOutputs) { _, _ in
            resetClutchSelection()
        }
        .onChange(of: clutchModeEnabled) { _, enabled in
            if !enabled {
                resetClutchSelection()
            }
        }
        .onChange(of: viewModel.inputText) { _, _ in
            guard clutchModeEnabled else { return }
            guard clutchCanTrackSourceSelection else {
                resetClutchSelection()
                return
            }
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
            #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissKeyboard()
                    }
                }
            }
            #endif
        #else
            #if os(iOS)
            baseView
                .translationViewLifecycleModifiers(
                    viewModel: viewModel,
                    isJapaneseLocale: isJapaneseLocale,
                    handleSharedImportIfNeeded: handleSharedImportIfNeeded
                )
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            dismissKeyboard()
                        }
                    }
                }
            #else
            baseView
                .translationViewLifecycleModifiers(
                    viewModel: viewModel,
                    isJapaneseLocale: isJapaneseLocale,
                    handleSharedImportIfNeeded: {}
                )
            #endif
        #endif
    }
    // #endregion

    // #region MARK: Layout
    @ViewBuilder
    private var contentLayout: some View {
        #if os(iOS)
        GeometryReader { proxy in
            let isPortrait = proxy.size.height > proxy.size.width
            let usesDesktopLikeIOSLayout = !isPortrait && proxy.size.width >= compactLayoutThresholdWidth
            let contentTopPadding: CGFloat = 8
            let contentBottomPadding: CGFloat = 2
            let verticalGap: CGFloat = 14
            let desktopColumnGap: CGFloat = 9
            let contentHorizontalPadding: CGFloat = usesDesktopLikeIOSLayout ? 36 : 12
            let compactStatusBottomMargin: CGFloat = contentHorizontalPadding / 2
            let availableHeight = max(0, proxy.size.height - contentTopPadding - contentBottomPadding)
            let splitHeight = max(
                140,
                (availableHeight - verticalGap - outputStatusReservedHeight - compactStatusBottomMargin) / 2
            )
            let usesStackedCompactLayout = !(usesDesktopLikeIOSLayout || (isWideIOSLayout && !isPortrait))
            let compactHeights = compactStackedHeights(
                availableHeight: availableHeight,
                verticalGap: verticalGap,
                statusReservedHeight: outputStatusReservedHeight,
                bottomMargin: compactStatusBottomMargin,
                defaultSplitHeight: splitHeight
            )

            VStack(alignment: .leading, spacing: 14) {
                if usesDesktopLikeIOSLayout {
                    HStack(alignment: .top, spacing: desktopColumnGap) {
                        sourceCard
                        outputColumnWithStatus()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.bottom, desktopColumnGap)
                } else if isWideIOSLayout && !isPortrait {
                    HStack(alignment: .top, spacing: 14) {
                        sourceCard
                        outputColumnWithStatus()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: verticalGap) {
                        sourceCard
                            .frame(height: compactHeights.sourceHeight)
                        outputColumnWithStatus(contentHeight: compactHeights.outputHeight)
                            .frame(height: compactHeights.outputHeight + outputStatusReservedHeight)
                            .padding(.bottom, compactStatusBottomMargin)
                    }
                }

                if developerModeEnabled {
                    developerPanels
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.top, contentTopPadding)
            .padding(.bottom, contentBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                isIOSDesktopLayoutActive = usesDesktopLikeIOSLayout
                updateCompactStackedLayoutState(isActive: usesStackedCompactLayout)
            }
            .onChange(of: proxy.size) { _, newSize in
                let portrait = newSize.height > newSize.width
                isIOSDesktopLayoutActive = !portrait && newSize.width >= compactLayoutThresholdWidth
                let usesDesktop = !portrait && newSize.width >= compactLayoutThresholdWidth
                let usesWideLandscape = isWideIOSLayout && !portrait
                updateCompactStackedLayoutState(isActive: !(usesDesktop || usesWideLandscape))
            }
            .animation(.easeInOut(duration: 0.24), value: isCompactOutputReadingMode)
        }
        #else
        GeometryReader { proxy in
            let isCompactDesktopLayout = proxy.size.width < compactLayoutThresholdWidth
            let contentTopPadding: CGFloat = 8
            let contentBottomPadding: CGFloat = 2
            let verticalGap: CGFloat = 14
            let headerReservedHeight: CGFloat = 64
            let desktopColumnGap: CGFloat = 18
            let contentHorizontalPadding: CGFloat = isCompactDesktopLayout ? 12 : 36
            let compactStatusBottomMargin: CGFloat = contentHorizontalPadding
            let availableHeight = max(
                0,
                proxy.size.height - contentTopPadding - contentBottomPadding - headerReservedHeight
            )
            let splitHeight = max(
                170,
                (availableHeight - verticalGap - outputStatusReservedHeight - compactStatusBottomMargin) / 2
            )
            let compactHeights = compactStackedHeights(
                availableHeight: availableHeight,
                verticalGap: verticalGap,
                statusReservedHeight: outputStatusReservedHeight,
                bottomMargin: compactStatusBottomMargin,
                defaultSplitHeight: splitHeight
            )

            VStack(alignment: .leading, spacing: isCompactDesktopLayout ? 14 : 18) {
                desktopHeader

                if isCompactDesktopLayout {
                    VStack(alignment: .leading, spacing: verticalGap) {
                        sourceCard
                            .frame(height: compactHeights.sourceHeight)
                        outputColumnWithStatus(contentHeight: compactHeights.outputHeight)
                            .frame(height: compactHeights.outputHeight + outputStatusReservedHeight)
                            .padding(.bottom, compactStatusBottomMargin)
                    }
                } else {
                    HStack(alignment: .top, spacing: desktopColumnGap) {
                        sourceCard
                        outputColumnWithStatus()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.bottom, desktopColumnGap)
                }

                if developerModeEnabled {
                    developerPanels
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, contentHorizontalPadding)
            .padding(.top, contentTopPadding)
            .padding(.bottom, isCompactDesktopLayout ? compactLayoutBottomMargin : contentBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onAppear {
                isMacCompactLayoutActive = isCompactDesktopLayout
                updateCompactStackedLayoutState(isActive: isCompactDesktopLayout)
            }
            .onChange(of: proxy.size.width) { _, newWidth in
                let isCompact = newWidth < compactLayoutThresholdWidth
                isMacCompactLayoutActive = isCompact
                updateCompactStackedLayoutState(isActive: isCompact)
            }
            .animation(.easeInOut(duration: 0.24), value: isCompactOutputReadingMode)
        }
        #endif
    }

    @ViewBuilder
    private var desktopHeader: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: -6) {
                Text("Pre-Babel Lens")
                    .font(.system(size: 32, weight: .black, design: .serif))
                    .minimumScaleFactor(0.8)
                Text("LOCAL TRANSLATOR")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .kerning(3)
                    .foregroundStyle(Color(red: 0.20, green: 0.35, blue: 0.30))
            }
            Spacer()
            if !usesCompactDesktopLayout {
                languagePicker
            }
            if !usesCompactDesktopLayout {
                settingsMenu(iconSize: 24, frameSize: 64)
            }
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
            #if os(macOS)
            Menu {
                translationModeToggleMenuItem
                Divider()
                ForEach(viewModel.targetLanguageOptions) { option in
                    Button {
                        viewModel.targetLanguage = option.code
                    } label: {
                        if option.code == viewModel.targetLanguage {
                            Label(option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle), systemImage: "checkmark")
                        } else {
                            Text(option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle))
                        }
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
            #else
            Picker("Target", selection: $viewModel.targetLanguage) {
                ForEach(viewModel.targetLanguageOptions) { option in
                    Text(option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle)).tag(option.code)
                }
            }
            .pickerStyle(.menu)
            #endif
        }
    }

    @ViewBuilder
    private var inlineLanguageMenu: some View {
        if viewModel.targetLanguageOptions.isEmpty {
            Text("No target")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Menu {
                translationModeToggleMenuItem
                Divider()
                ForEach(viewModel.targetLanguageOptions) { option in
                    Button {
                        viewModel.targetLanguage = option.code
                    } label: {
                        if option.code == viewModel.targetLanguage {
                            Label(option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle), systemImage: "checkmark")
                        } else {
                            Text(option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle))
                        }
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
            #if os(macOS)
            // Keep the same font but remove extra trailing menu-indicator padding.
            .menuIndicator(.hidden)
            #endif
        }
    }

    @ViewBuilder
    private var translationModeToggleMenuItem: some View {
        if viewModel.isAppleIntelligenceAvailable {
            Button(
                viewModel.usesAppleIntelligenceTranslation
                    ? "機械翻訳に切り替え"
                    : "AI翻訳に切り替え"
            ) {
                if viewModel.usesAppleIntelligenceTranslation {
                    viewModel.switchToStandardTranslation()
                } else {
                    viewModel.switchToAppleIntelligenceTranslation()
                }
            }
        } else {
            Button("AI翻訳はこのデバイスで利用できません") { }
                .disabled(true)
        }
    }

    @ViewBuilder
    private func settingsMenu(iconSize: CGFloat, frameSize: CGFloat) -> some View {
        Menu {
            #if os(iOS)
            Toggle(autoTranslateToggleTitle, isOn: $autoTranslateImportedTextEnabled)
            #endif
            Toggle("Clutch", isOn: $clutchModeEnabled)
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

    private var usesCompactDesktopLayout: Bool {
        #if os(macOS)
        isMacCompactLayoutActive
        #else
        false
        #endif
    }

    private var compactLayoutThresholdWidth: CGFloat {
        1133
    }

    private var compactLayoutBottomMargin: CGFloat {
        LayoutTokens.desktop.cardOuterPadding / 2
    }

    private var editorFontPointSize: CGFloat {
        baseBodyFontPointSize * currentFontScale.multiplier
    }

    private var currentFontScale: EditorFontScaleLevel {
        EditorFontScaleLevel(rawValue: editorFontScaleLevel) ?? .medium
    }

    private var baseBodyFontPointSize: CGFloat {
        #if os(iOS)
        UIFont.preferredFont(forTextStyle: .body).pointSize
        #elseif os(macOS)
        NSFont.preferredFont(forTextStyle: .body).pointSize
        #else
        14
        #endif
    }
    // #endregion

    // #region MARK: Subviews
    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Source")
                    .font(.system(size: layoutTokens.sectionTitleFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                Button("Paste", action: pasteInputFromClipboard)
                    .buttonStyle(.bordered)
                Button("Clear") {
                    viewModel.inputText = ""
                }
                .buttonStyle(.bordered)
            }

            sourceEditor
        }
        .padding(cardOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .background(Color.clear)
        #else
        .background {
            if usesCompactDesktopLayout {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7))
            }
        }
        #endif
    }

    @ViewBuilder
    private var sourceEditor: some View {
        #if os(iOS)
        IOSClutchSourceTextEditor(
            text: $viewModel.inputText,
            fontSize: editorFontPointSize,
            highlightedRange: sourceHighlightRange,
            centerOnHighlightIfNeeded: shouldAutoCenterSourceForClutch,
            onCursorLocationChanged: handleSourceCursorLocationChange
        )
            .frame(maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(editorPinchGesture(host: .source), including: .gesture)
            .padding(layoutTokens.editorInnerPadding)
            .font(.system(size: editorFontPointSize))
            .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.30))
            .overlay(
                RoundedRectangle(cornerRadius: editorCornerRadius)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                pinchOverlay(host: .source)
            }
        #else
        MacSourceTextEditor(
            text: $viewModel.inputText,
            fontSize: editorFontPointSize,
            highlightedRange: sourceHighlightRange,
            centerOnHighlightIfNeeded: shouldAutoCenterSourceForClutch,
            onCursorLocationChanged: handleSourceCursorLocationChange
        )
            .frame(minHeight: sourceEditorMinHeight, maxHeight: .infinity, alignment: .top)
            .padding(layoutTokens.editorInnerPadding)
            .font(.system(size: editorFontPointSize))
            .background(
                colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4),
                in: RoundedRectangle(cornerRadius: editorCornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: editorCornerRadius)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
        #endif
    }

    private var outputContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Output")
                    .font(.system(size: layoutTokens.sectionTitleFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                if usesInlineLanguageMenuInOutputCard {
                    inlineLanguageMenu
                }

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
                    #if os(iOS)
                    dismissKeyboard()
                    #endif
                    Task { await viewModel.translate() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isTranslating || viewModel.targetLanguageOptions.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    outputSegmentsView
                        .padding(.top, 12)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .overlay(alignment: .top) {
                            GeometryReader { geometryProxy in
                                Color.clear.preference(
                                    key: OutputScrollOffsetPreferenceKey.self,
                                    value: geometryProxy.frame(in: .named(outputScrollCoordinateSpaceName)).minY
                                )
                            }
                            .frame(height: 0)
                        }
                }
                .onChange(of: clutchSelectedSegmentIndex) { _, segmentIndex in
                    guard clutchModeEnabled else { return }
                    guard let segmentIndex else { return }
                    guard clutchSelectionOrigin != .output else { return }
                    withAnimation(.easeInOut(duration: 0.24)) {
                        proxy.scrollTo(outputSegmentID(for: segmentIndex), anchor: .center)
                    }
                }
            }
            .coordinateSpace(name: outputScrollCoordinateSpaceName)
            .onPreferenceChange(OutputScrollOffsetPreferenceKey.self) { minY in
                handleOutputScrollOffsetChange(minY)
            }
            .scrollDisabled(isOutputScrollLocked)
            .simultaneousGesture(outputCollapseActivationGesture, including: .gesture)
            #if os(iOS)
            .frame(maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(editorPinchGesture(host: .output), including: .gesture)
            #else
            .frame(minHeight: editorMinHeight, maxHeight: .infinity, alignment: .top)
            .onAppear {
                installMacTopEdgeWheelMonitorIfNeeded()
            }
            .onDisappear {
                uninstallMacTopEdgeWheelMonitor()
            }
            #endif
            .clipped()
            #if os(iOS)
            .background(colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.30))
            .overlay(
                RoundedRectangle(cornerRadius: editorCornerRadius)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .overlay(alignment: .top) {
                pinchOverlay(host: .output)
            }
            #else
            .background(
                colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4),
                in: RoundedRectangle(cornerRadius: editorCornerRadius)
            )
            #endif
        }
    }

    @ViewBuilder
    private func outputColumnWithStatus(contentHeight: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let contentHeight {
                outputContent
                    .frame(height: contentHeight, alignment: .top)
            } else {
                outputContent
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            outputStatusPanel
        }
        .padding(cardOuterPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(iOS)
        .background(Color.clear)
        #else
        .background {
            if usesCompactDesktopLayout {
                Color.clear
            } else {
                RoundedRectangle(cornerRadius: cardCornerRadius)
                    .fill(colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7))
            }
        }
        #endif
    }

    @ViewBuilder
    private var outputSegmentsView: some View {
        if viewModel.translatedText.isEmpty {
            Color.clear
                .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
        } else if viewModel.segmentOutputs.isEmpty {
            Text(viewModel.translatedText)
                .font(.system(size: editorFontPointSize))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(viewModel.segmentOutputs.enumerated()), id: \.element.id) { index, segment in
                    Text(outputAttributedText(for: segment, joiner: joinerAfterOutputSegment(at: index)))
                        .font(.system(size: editorFontPointSize))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(clutchOutputHighlightBackground(for: segment.segmentIndex), in: RoundedRectangle(cornerRadius: 6))
                        .id(outputSegmentID(for: segment.segmentIndex))
                        .contentShape(Rectangle())
                        .overlay {
                            #if os(macOS)
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleOutputSegmentTap(segment.segmentIndex)
                                }
                                .allowsHitTesting(clutchModeEnabled)
                            #else
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleOutputSegmentTap(segment.segmentIndex)
                                }
                            #endif
                        }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func outputAttributedText(for segment: SegmentOutput, joiner: String) -> AttributedString {
        var chunk = AttributedString(segment.translatedText + joiner)
        if segment.isUnsafeFallback {
            if segment.isUnsafeRecoveredByTranslationFramework {
                chunk.backgroundColor = unsafeRecoveredSegmentBackgroundColor
                chunk.foregroundColor = unsafeRecoveredSegmentForegroundColor
            } else {
                chunk.backgroundColor = unsafeSegmentBackgroundColor
                chunk.foregroundColor = unsafeSegmentForegroundColor
            }
        }
        return chunk
    }

    private func clutchOutputHighlightBackground(for segmentIndex: Int) -> Color {
        guard clutchModeEnabled, clutchSelectedSegmentIndex == segmentIndex else { return .clear }
        return Color.accentColor.opacity(colorScheme == .dark ? 0.24 : 0.14)
    }

    private var unsafeRecoveredSegmentBackgroundColor: Color {
        Color.blue.opacity(colorScheme == .dark ? 0.34 : 0.18)
    }

    private var unsafeRecoveredSegmentForegroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.96)
            : Color.black.opacity(0.86)
    }

    private var unsafeSegmentBackgroundColor: Color {
        Color.orange.opacity(colorScheme == .dark ? 0.65 : 0.38)
    }

    private var unsafeSegmentForegroundColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.96)
            : Color.black.opacity(0.72)
    }

    private func joinerAfterOutputSegment(at index: Int) -> String {
        guard index < viewModel.segmentJoinersAfter.count else { return "" }
        return viewModel.segmentJoinersAfter[index]
    }

    private struct ClutchSegmentBinding {
        let segmentIndex: Int
        let sourceRange: NSRange
    }

    private enum ClutchSelectionOrigin {
        case source
        case output
    }

    private var clutchSegmentBindings: [ClutchSegmentBinding] {
        guard !viewModel.sourceSegments.isEmpty else { return [] }
        let sortedSegments = viewModel.sourceSegments.sorted { $0.index < $1.index }
        var cursor = 0
        return sortedSegments.enumerated().map { offset, segment in
            let sourceLength = (segment.text as NSString).length
            let range = NSRange(location: cursor, length: sourceLength)
            cursor += sourceLength
            if offset < viewModel.segmentJoinersAfter.count {
                cursor += (viewModel.segmentJoinersAfter[offset] as NSString).length
            }
            return ClutchSegmentBinding(segmentIndex: segment.index, sourceRange: range)
        }
    }

    private var clutchCanTrackSourceSelection: Bool {
        viewModel.inputText == viewModel.sourceTextSnapshotForSegments
    }

    private func outputSegmentID(for segmentIndex: Int) -> String {
        "output-segment-\(segmentIndex)"
    }

    private func handleOutputSegmentTap(_ segmentIndex: Int) {
        guard clutchModeEnabled else { return }
        clutchSelectionOrigin = .output
        clutchSelectedSegmentIndex = segmentIndex
        guard let sourceRange = clutchSegmentBindings.first(where: { $0.segmentIndex == segmentIndex })?.sourceRange else {
            return
        }
        sourceHighlightRange = sourceRange
    }

    private func handleSourceCursorLocationChange(_ utf16Location: Int) {
        guard clutchModeEnabled, clutchCanTrackSourceSelection else {
            sourceHighlightRange = nil
            return
        }

        guard let binding = clutchSegmentBindings.first(where: { binding in
            let lower = binding.sourceRange.location
            let upper = binding.sourceRange.location + binding.sourceRange.length
            return utf16Location >= lower && utf16Location <= upper
        }) else {
            sourceHighlightRange = nil
            return
        }

        sourceHighlightRange = binding.sourceRange
        clutchSelectionOrigin = .source
        clutchSelectedSegmentIndex = binding.segmentIndex
    }

    private var shouldAutoCenterSourceForClutch: Bool {
        clutchSelectionOrigin == .output
    }

    private func resetClutchSelection() {
        clutchSelectedSegmentIndex = nil
        sourceHighlightRange = nil
        clutchSelectionOrigin = nil
    }
    // #endregion

    private var usesInlineLanguageMenuInOutputCard: Bool {
        #if os(iOS)
        true
        #elseif os(macOS)
        usesCompactDesktopLayout
        #else
        false
        #endif
    }

    private var usesIOSLikeFieldStyle: Bool {
        #if os(iOS)
        !isIOSDesktopLayoutActive
        #elseif os(macOS)
        usesCompactDesktopLayout
        #else
        false
        #endif
    }

    private var layoutTokens: LayoutTokens {
        usesIOSLikeFieldStyle ? .iosLike : .desktop
    }

    private var cardOuterPadding: CGFloat {
        #if os(iOS)
        if isIOSDesktopLayoutActive {
            return layoutTokens.cardOuterPadding / 2
        }
        #endif
        return layoutTokens.cardOuterPadding
    }

    private var cardCornerRadius: CGFloat {
        layoutTokens.cardCornerRadius
    }

    private var editorCornerRadius: CGFloat {
        #if os(iOS)
        if isIOSDesktopLayoutActive {
            return 0
        }
        #endif
        return layoutTokens.editorCornerRadius
    }

    private var editorMinHeight: CGFloat {
        layoutTokens.editorMinHeight
    }

    private var sourceEditorMinHeight: CGFloat {
        if isCompactOutputReadingMode && isCompactStackedLayoutActive {
            return compactCollapsedSourceEditorMinHeight
        }
        return editorMinHeight
    }

    private var compactCollapsedSourceEditorMinHeight: CGFloat {
        max(60, editorFontPointSize * 3.2)
    }

    private var compactCollapsedSourceCardHeight: CGFloat {
        let headerHeight: CGFloat = 36
        let editorVerticalPadding = layoutTokens.editorInnerPadding * 2 + 14
        return max(
            96,
            headerHeight
                + compactCollapsedSourceEditorMinHeight
                + editorVerticalPadding
                + compactCollapsedSourceTopPaddingCompensation
                + (cardOuterPadding * 2)
        )
    }

    private var compactCollapsedSourceTopPaddingCompensation: CGFloat { 8 }

    private var outputScrollCoordinateSpaceName: String {
        "output-scroll-area"
    }

    private var compactOutputCollapseTriggerOffset: CGFloat {
        #if os(macOS)
        6
        #else
        28
        #endif
    }
    private var compactOutputExpandReleaseOffset: CGFloat { 8 }

    private var canUseCompactOutputReadingMode: Bool {
        isCompactStackedLayoutActive
            && !viewModel.isTranslating
            && !viewModel.translatedText.isEmpty
    }

    private var isOutputScrollLocked: Bool {
        #if os(macOS)
        return false
        #else
        guard canUseCompactOutputReadingMode else { return false }
        if !isCompactOutputReadingMode {
            return true
        }
        return isOutputCollapseDragActive && didCollapseDuringCurrentDrag
        #endif
    }

    private func compactStackedHeights(
        availableHeight: CGFloat,
        verticalGap: CGFloat,
        statusReservedHeight: CGFloat,
        bottomMargin: CGFloat,
        defaultSplitHeight: CGFloat
    ) -> (sourceHeight: CGFloat, outputHeight: CGFloat) {
        let defaultHeights = (sourceHeight: defaultSplitHeight, outputHeight: defaultSplitHeight)
        guard canUseCompactOutputReadingMode, isCompactOutputReadingMode else {
            return defaultHeights
        }

        let sourceHeight = min(defaultSplitHeight, compactCollapsedSourceCardHeight)
        let outputHeight = availableHeight - verticalGap - statusReservedHeight - bottomMargin - sourceHeight
        let minimumOutputHeight: CGFloat = 140
        guard outputHeight >= minimumOutputHeight else {
            return defaultHeights
        }
        return (sourceHeight, outputHeight)
    }

    private func handleOutputScrollOffsetChange(_ minY: CGFloat) {
        guard canUseCompactOutputReadingMode else {
            disableCompactOutputReadingModeIfNeeded()
            return
        }

        #if os(macOS)
        let scrollDistance = abs(minY)
        #else
        let scrollDistance = max(0, -minY)
        #endif
        currentOutputScrollDistance = scrollDistance
        if !isCompactOutputReadingMode {
            #if os(macOS)
            guard scrollDistance > compactOutputCollapseTriggerOffset else { return }
            withAnimation(.easeInOut(duration: 0.24)) {
                isCompactOutputReadingMode = true
            }
            hasReachedTopEdgeSinceCollapse = false
            #endif
            return
        }

        if !hasReachedTopEdgeSinceCollapse, scrollDistance <= compactOutputExpandReleaseOffset {
            hasReachedTopEdgeSinceCollapse = true
            return
        }

        let topSpringDistance = max(0, minY)
        guard hasReachedTopEdgeSinceCollapse else { return }
        guard isOutputExpandSpringArmed else { return }
        guard topSpringDistance > compactOutputExpandReleaseOffset else { return }
        restoreDefaultFieldSizesFromCompactMode()
    }

    private var outputCollapseActivationGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard canUseCompactOutputReadingMode else { return }
                isOutputCollapseDragActive = true
                if isCompactOutputReadingMode {
                    guard hasReachedTopEdgeSinceCollapse else { return }
                    guard currentOutputScrollDistance <= compactOutputExpandReleaseOffset else { return }
                    guard value.translation.height > 3 else { return }
                    isOutputExpandSpringArmed = true
                    return
                }
                guard value.translation.height < -3 else { return }
                didCollapseDuringCurrentDrag = true
                withAnimation(.easeInOut(duration: 0.24)) {
                    isCompactOutputReadingMode = true
                }
                hasReachedTopEdgeSinceCollapse = currentOutputScrollDistance <= compactOutputExpandReleaseOffset
                isOutputExpandSpringArmed = false
            }
            .onEnded { _ in
                isOutputCollapseDragActive = false
                didCollapseDuringCurrentDrag = false
            }
    }

    private func updateCompactStackedLayoutState(isActive: Bool) {
        isCompactStackedLayoutActive = isActive
        if !isActive {
            disableCompactOutputReadingModeIfNeeded()
        }
    }

    private func disableCompactOutputReadingModeIfNeeded() {
        isOutputCollapseDragActive = false
        didCollapseDuringCurrentDrag = false
        hasReachedTopEdgeSinceCollapse = false
        currentOutputScrollDistance = 0
        isOutputExpandSpringArmed = false
        guard isCompactOutputReadingMode else { return }
        withAnimation(.easeInOut(duration: 0.20)) {
            isCompactOutputReadingMode = false
        }
    }

    private func restoreDefaultFieldSizesFromCompactMode() {
        withAnimation(.easeInOut(duration: 0.24)) {
            isCompactOutputReadingMode = false
        }
        hasReachedTopEdgeSinceCollapse = false
        isOutputExpandSpringArmed = false
    }

    #if os(macOS)
    private func installMacTopEdgeWheelMonitorIfNeeded() {
        guard macTopEdgeWheelMonitor == nil else { return }
        macTopEdgeWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard canUseCompactOutputReadingMode else { return event }
            guard isCompactOutputReadingMode else { return event }
            guard hasReachedTopEdgeSinceCollapse else { return event }
            guard currentOutputScrollDistance <= compactOutputExpandReleaseOffset else { return event }
            guard event.scrollingDeltaY > 0 else { return event }
            isOutputExpandSpringArmed = true
            restoreDefaultFieldSizesFromCompactMode()
            return event
        }
    }

    private func uninstallMacTopEdgeWheelMonitor() {
        guard let macTopEdgeWheelMonitor else { return }
        NSEvent.removeMonitor(macTopEdgeWheelMonitor)
        self.macTopEdgeWheelMonitor = nil
    }
    #endif

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

    private var outputStatusReservedHeight: CGFloat { layoutTokens.outputStatusReservedHeight }

    @ViewBuilder
    private var outputStatusPanel: some View {
        HStack(spacing: 0) {
            outputStatusOverlay
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: outputStatusReservedHeight, maxHeight: outputStatusReservedHeight, alignment: .leading)
        .background(
            colorScheme == .dark ? Color.black.opacity(0.24) : Color.white.opacity(0.30)
        )
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
        }
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
                    .font(.system(size: layoutTokens.statusTextFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(statusHeadlineColor)
                    .lineLimit(1)
                ForEach(viewModel.statusNotices) { notice in
                    statusNoticeLegendRow(notice)
                }
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

    @ViewBuilder
    private func statusNoticeLegendRow(_ notice: TranslationViewModel.StatusNotice) -> some View {
        HStack(spacing: 6) {
            Text(notice.markerText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(noticeForegroundColor(for: notice.style))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    noticeBackgroundColor(for: notice.style),
                    in: Capsule()
                )
            Text(notice.text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func noticeBackgroundColor(for style: TranslationViewModel.StatusNotice.Style) -> Color {
        switch style {
        case .orange:
            return Color.orange.opacity(colorScheme == .dark ? 0.58 : 0.32)
        case .blue:
            return Color.blue.opacity(colorScheme == .dark ? 0.58 : 0.28)
        }
    }

    private func noticeForegroundColor(for style: TranslationViewModel.StatusNotice.Style) -> Color {
        switch style {
        case .orange, .blue:
            return colorScheme == .dark
                ? Color.white.opacity(0.95)
                : Color.black.opacity(0.82)
        }
    }

    private var statusHeadlineColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.92)
            : Color(red: 0.20, green: 0.35, blue: 0.30)
    }

    private var currentTargetLanguageLabel: String {
        if let selected = viewModel.targetLanguageOptions.first(where: { $0.code == viewModel.targetLanguage }) {
            return selected.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle)
        }
        return "Target"
    }

    private var currentLabelStyle: TargetLanguageOption.LabelStyle {
        viewModel.usesAppleIntelligenceTranslation ? .ai : .machine
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

    #if os(macOS)
    #endif

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

    private func dismissKeyboard() {
        focusedField = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    @ViewBuilder
    private func pinchOverlay(host: PinchOverlayHost) -> some View {
        if let pinchOverlayText, pinchOverlayHost == host {
            Text(pinchOverlayText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.78), in: Capsule())
                .padding(.top, 8)
                .transition(.opacity)
        }
    }

    private func editorPinchGesture(host: PinchOverlayHost) -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.01)
            .onChanged { scale in
                if pinchBaseFontScaleLevel == nil {
                    pinchBaseFontScaleLevel = currentFontScale.rawValue
                    pinchOverlayHost = host
                    pinchOverlayDismissTask?.cancel()
                    pinchOverlayText = pinchOverlayLabel
                }

                guard let base = pinchBaseFontScaleLevel else { return }
                let step = Int((log(max(0.01, scale)) / log(1.15)).rounded())
                let updated = (base + step).clamped(to: EditorFontScaleLevel.minimumRawValue...EditorFontScaleLevel.maximumRawValue)
                if editorFontScaleLevel != updated {
                    editorFontScaleLevel = updated
                }
                pinchOverlayHost = host
                pinchOverlayText = pinchOverlayLabel
            }
            .onEnded { _ in
                handlePinchEnded()
            }
    }

    private func handlePinchEnded() {
        pinchBaseFontScaleLevel = nil
        pinchOverlayDismissTask?.cancel()
        pinchOverlayDismissTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    pinchOverlayText = nil
                    pinchOverlayHost = nil
                }
            }
        }
    }

    private var pinchOverlayLabel: String {
        if isJapaneseLocale {
            return "文字サイズ \(currentFontScale.displayName)"
        }
        return "Text Size \(currentFontScale.displayName)"
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

private struct OutputScrollOffsetPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum EditorFontScaleLevel: Int, CaseIterable {
    case extraSmall = 0
    case small = 1
    case medium = 2
    case large = 3
    case extraLarge = 4

    static var minimumRawValue: Int { extraSmall.rawValue }
    static var maximumRawValue: Int { extraLarge.rawValue }

    var multiplier: CGFloat {
        switch self {
        case .extraSmall:
            return 0.8
        case .small:
            return 0.9
        case .medium:
            return 1.0
        case .large:
            return 1.2
        case .extraLarge:
            return 1.4
        }
    }

    var displayName: String {
        switch self {
        case .extraSmall:
            return "XS"
        case .small:
            return "S"
        case .medium:
            return "M"
        case .large:
            return "L"
        case .extraLarge:
            return "XL"
        }
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension TranslationView {
    struct LayoutTokens {
        var sectionTitleFontSize: CGFloat
        var statusTextFontSize: CGFloat
        var editorInnerPadding: CGFloat
        var cardOuterPadding: CGFloat
        var cardCornerRadius: CGFloat
        var editorCornerRadius: CGFloat
        var editorMinHeight: CGFloat
        var outputStatusReservedHeight: CGFloat

        static let iosLike = LayoutTokens(
            sectionTitleFontSize: 18,
            statusTextFontSize: 14,
            editorInnerPadding: 8,
            cardOuterPadding: 0,
            cardCornerRadius: 0,
            editorCornerRadius: 0,
            editorMinHeight: 170,
            outputStatusReservedHeight: 22
        )

        static let desktop = LayoutTokens(
            sectionTitleFontSize: 18,
            statusTextFontSize: 14,
            editorInnerPadding: 8,
            cardOuterPadding: 22,
            cardCornerRadius: 26,
            editorCornerRadius: 18,
            editorMinHeight: 300,
            outputStatusReservedHeight: 22
        )
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

#if os(iOS)
private struct IOSClutchSourceTextEditor: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let highlightedRange: NSRange?
    let centerOnHighlightIfNeeded: Bool
    let onCursorLocationChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCursorLocationChanged: onCursorLocationChanged)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.text = text
        textView.font = UIFont.systemFont(ofSize: fontSize)
        textView.backgroundColor = .clear
        textView.autocorrectionType = .yes
        textView.autocapitalizationType = .sentences
        textView.smartDashesType = .no
        textView.smartQuotesType = .no
        textView.dataDetectorTypes = []
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        context.coordinator.attachTextView(textView)
        textView.inputAccessoryView = context.coordinator.makeKeyboardAccessoryToolbar()
        return textView
    }

    func updateUIView(_ uiView: UITextView, context _: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.font?.pointSize != fontSize {
            uiView.font = UIFont.systemFont(ofSize: fontSize)
        }
        uiView.applyClutchHighlight(highlightedRange, centerIfNeeded: centerOnHighlightIfNeeded)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private let onCursorLocationChanged: (Int) -> Void
        private weak var textView: UITextView?

        init(text: Binding<String>, onCursorLocationChanged: @escaping (Int) -> Void) {
            _text = text
            self.onCursorLocationChanged = onCursorLocationChanged
        }

        func attachTextView(_ textView: UITextView) {
            self.textView = textView
        }

        func makeKeyboardAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()

            let retranslate = UIBarButtonItem(title: "再翻訳", style: .plain, target: nil, action: nil)
            retranslate.isEnabled = false
            let proofread = UIBarButtonItem(title: "AI校正", style: .plain, target: nil, action: nil)
            proofread.isEnabled = false
            let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            let done = UIBarButtonItem(title: "OK", style: .done, target: self, action: #selector(doneTapped))

            toolbar.items = [retranslate, proofread, spacer, done]
            return toolbar
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text ?? ""
            onCursorLocationChanged(textView.selectedRange.location)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            onCursorLocationChanged(textView.selectedRange.location)
        }

        @objc private func doneTapped() {
            textView?.resignFirstResponder()
        }
    }
}

private extension UITextView {
    func applyClutchHighlight(_ range: NSRange?, centerIfNeeded: Bool) {
        let mutable = NSMutableAttributedString(string: text ?? "")
        let fullRange = NSRange(location: 0, length: mutable.length)
        let font = self.font ?? UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize)
        mutable.addAttribute(.font, value: font, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)

        if centerIfNeeded,
            let range,
            range.location >= 0,
            range.length > 0,
            NSMaxRange(range) <= mutable.length
        {
            mutable.addAttribute(.backgroundColor, value: UIColor.systemBlue.withAlphaComponent(0.20), range: range)
        }

        let selected = selectedRange
        attributedText = mutable
        selectedRange = selected

        if
            let range,
            range.location >= 0,
            range.length > 0,
            NSMaxRange(range) <= mutable.length
        {
            centerVisibleRangeIfNeeded(range)
        }
    }

    private func centerVisibleRangeIfNeeded(_ range: NSRange) {
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var targetRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        targetRect.origin.x += textContainerInset.left
        targetRect.origin.y += textContainerInset.top
        guard !targetRect.isEmpty else { return }

        let visibleRect = bounds.inset(by: adjustedContentInset)
        if visibleRect.intersects(targetRect) {
            return
        }

        var y = targetRect.midY - (bounds.height * 0.5)
        let minOffset = -adjustedContentInset.top
        let maxOffset = max(minOffset, contentSize.height - bounds.height + adjustedContentInset.bottom)
        y = min(max(y, minOffset), maxOffset)
        setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: true)
    }
}
#endif

#if os(macOS)
private struct MacSourceTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let highlightedRange: NSRange?
    let centerOnHighlightIfNeeded: Bool
    let onCursorLocationChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCursorLocationChanged: onCursorLocationChanged)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        let textView = DropAwareTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.font = NSFont.systemFont(ofSize: fontSize)
        textView.backgroundColor = NSColor.clear
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.onDropResolvedText = { droppedText in
            context.coordinator.updateTextFromDrop(droppedText)
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context _: Context) {
        guard let textView = nsView.documentView as? DropAwareTextView else { return }
        if textView.string != text {
            textView.string = text
        }
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }
        textView.applyClutchHighlight(highlightedRange, centerIfNeeded: centerOnHighlightIfNeeded)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        private let onCursorLocationChanged: (Int) -> Void

        init(text: Binding<String>, onCursorLocationChanged: @escaping (Int) -> Void) {
            _text = text
            self.onCursorLocationChanged = onCursorLocationChanged
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
            onCursorLocationChanged(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onCursorLocationChanged(textView.selectedRange().location)
        }

        func updateTextFromDrop(_ droppedText: String) {
            guard !droppedText.isEmpty else { return }
            text = droppedText
        }
    }
}

private final class DropAwareTextView: NSTextView {
    private let clutchHighlightAttribute = NSAttributedString.Key.backgroundColor
    private let clutchHighlightColor = NSColor.systemBlue.withAlphaComponent(0.18)
    var onDropResolvedText: ((String) -> Void)?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        registerForDraggedTypes([.fileURL, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        SourceDropImport.resolveText(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let droppedText = SourceDropImport.resolveText(from: sender.draggingPasteboard) else {
            return false
        }
        onDropResolvedText?(droppedText)
        return true
    }

    func applyClutchHighlight(_ range: NSRange?, centerIfNeeded: Bool) {
        guard let textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        textStorage.removeAttribute(clutchHighlightAttribute, range: fullRange)

        guard
            let range,
            range.location >= 0,
            range.length > 0,
            NSMaxRange(range) <= textStorage.length
        else { return }

        textStorage.addAttribute(clutchHighlightAttribute, value: clutchHighlightColor, range: range)
        if centerIfNeeded {
            centerVisibleRangeIfNeeded(range)
        }
    }

    private func centerVisibleRangeIfNeeded(_ range: NSRange) {
        guard
            let layoutManager,
            let textContainer,
            let scrollView = enclosingScrollView
        else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard !glyphRect.isNull, !glyphRect.isInfinite else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        if visibleRect.intersects(glyphRect) {
            return
        }

        var target = glyphRect
        target.origin.y -= max(0, (visibleRect.height - target.height) / 2)
        target.size.height = visibleRect.height
        scrollView.contentView.scrollToVisible(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

private enum SourceDropImport {
    static func resolveText(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                if let text = loadText(from: url), !text.isEmpty {
                    return text
                }
            }
        }

        if let strings = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String] {
            for value in strings {
                if let fileURL = fileURL(fromDroppedText: value),
                   let text = loadText(from: fileURL),
                   !text.isEmpty {
                    return text
                }
            }
            for value in strings {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return value
                }
            }
        }
        return nil
    }

    static func loadText(from fileURL: URL) -> String? {
        let hasSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if hasSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        var encoding: UInt = 0
        if let text = try? NSString(contentsOf: fileURL, usedEncoding: &encoding) {
            let resolved = (text as String).trimmingCharacters(in: .whitespacesAndNewlines)
            if !resolved.isEmpty {
                return text as String
            }
        }

        let lowercasedExtension = fileURL.pathExtension.lowercased()

        if lowercasedExtension == "pdf", let extracted = extractTextFromPDF(fileURL), !extracted.isEmpty {
            return extracted
        }

        if ["doc", "docx", "pages"].contains(lowercasedExtension),
           let extracted = extractTextWithAttributedString(from: fileURL),
           !extracted.isEmpty {
            return extracted
        }

        if let extracted = extractTextWithMetadataImporter(from: fileURL), !extracted.isEmpty {
            return extracted
        }

        return nil
    }

    private static func extractTextWithAttributedString(from fileURL: URL) -> String? {
        if let attributed = try? NSAttributedString(
            url: fileURL,
            options: [:],
            documentAttributes: nil
        ) {
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func extractTextWithMetadataImporter(from fileURL: URL) -> String? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, fileURL as CFURL) else {
            return nil
        }
        guard let attributes = MDItemCopyAttributes(item, [kMDItemTextContent as CFString] as CFArray) as? [String: Any] else {
            return nil
        }
        guard let text = attributes[kMDItemTextContent as String] as? String else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    private static func extractTextFromPDF(_ fileURL: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: fileURL) else { return nil }

        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pages.append(normalizePDFSoftLineBreaks(text))
            }
        }

        let combined = pages.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
        #else
        return nil
        #endif
    }

    private static func normalizePDFSoftLineBreaks(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return text }

        var resultLines: [String] = []
        resultLines.reserveCapacity(lines.count)
        var keepLineBreakBeforeNext = true

        for rawLine in lines {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                if !resultLines.isEmpty, resultLines.last != "" {
                    resultLines.append("")
                }
                keepLineBreakBeforeNext = true
                continue
            }

            guard var last = resultLines.last, !last.isEmpty else {
                resultLines.append(trimmedLine)
                keepLineBreakBeforeNext = shouldKeepLineBreak(afterRawLine: rawLine)
                continue
            }

            if keepLineBreakBeforeNext {
                resultLines.append(trimmedLine)
                keepLineBreakBeforeNext = shouldKeepLineBreak(afterRawLine: rawLine)
                continue
            }

            last += " " + trimmedLine
            resultLines[resultLines.count - 1] = last
            keepLineBreakBeforeNext = shouldKeepLineBreak(afterRawLine: rawLine)
        }

        return resultLines.joined(separator: "\n")
    }

    private static func shouldKeepLineBreak(afterRawLine rawLine: String) -> Bool {
        // Keep the line break only when the line ends with one of:
        // . 。 ？
        // followed by optional trailing spaces before the newline.
        rawLine.range(of: #"[.。？]\s*$"#, options: .regularExpression) != nil
    }

    static func fileURL(fromDroppedText text: String) -> URL? {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            if let resolved = resolveDroppedPathCandidate(line) {
                return resolved
            }
        }
        return nil
    }

    private static func resolveDroppedPathCandidate(_ raw: String) -> URL? {
        let unwrapped = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
        let unquoted = unescapeShellPath(unwrapped)
        guard !unquoted.isEmpty else { return nil }

        if unquoted.hasPrefix("file://"), let url = URL(string: unquoted) {
            return url
        }

        let expanded = NSString(string: unquoted).expandingTildeInPath
        let standardized = NSString(string: expanded).standardizingPath
        let candidates = [expanded, expanded.removingPercentEncoding ?? expanded]
        let standardizedCandidates = [standardized, standardized.removingPercentEncoding ?? standardized]

        for candidate in candidates + standardizedCandidates {
            if FileManager.default.fileExists(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    private static func unescapeShellPath(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\ ", with: " ")
            .replacingOccurrences(of: "\\(", with: "(")
            .replacingOccurrences(of: "\\)", with: ")")
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
            .replacingOccurrences(of: "\\&", with: "&")
            .replacingOccurrences(of: "\\'", with: "'")
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
            .frame(minWidth: 362, minHeight: 680)
            .task {
                viewModel.refreshEnginePreference()
                if viewModel.consumeLaunchActivationRequest() {
                    NSApp.activate(ignoringOtherApps: true)
                }
                await viewModel.translateIfNeededOnLaunch()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                viewModel.refreshEnginePreference()
            }
        #elseif os(iOS)
        self
            .task {
                viewModel.refreshEnginePreference()
                handleSharedImportIfNeeded()
                await viewModel.translateIfNeededOnLaunch()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                viewModel.refreshEnginePreference()
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
