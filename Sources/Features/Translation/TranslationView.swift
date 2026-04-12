import SwiftUI

#if os(macOS)
    import AppKit
    import CoreServices
    #if canImport(PDFKit)
        import PDFKit
    #endif
#endif
#if canImport(Translation)
    @preconcurrency import Translation
#endif
#if canImport(UIKit)
    import UIKit
#endif
#if os(iOS)
    import PhotosUI
    import UniformTypeIdentifiers
    import Vision
    #if canImport(PDFKit)
        import PDFKit
    #endif
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
    #if os(iOS)
    @State private var isFileImportPickerPresented: Bool = false
    @State private var isPhotoPickerPresented: Bool = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    #endif
    @State private var isMacCompactLayoutActive: Bool = false
    @State private var isIOSDesktopLayoutActive: Bool = false
    @State private var isCompactStackedLayoutActive: Bool = false
    @State private var isCompactOutputReadingMode: Bool = false
    @State private var isOutputCollapseDragActive: Bool = false
    @State private var didCollapseDuringCurrentDrag: Bool = false
    @State private var hasReachedTopEdgeSinceCollapse: Bool = false
    @State private var currentOutputScrollDistance: CGFloat = 0
    @State private var isOutputExpandSpringArmed: Bool = false
    @State private var currentSourceScrollDistance: CGFloat = 0
    @State private var previousSourceScrollDistance: CGFloat = 0
    @State private var hasReachedSourceTopEdgeSinceCollapse: Bool = false
    @State private var isSourceExpandSpringArmed: Bool = false
    @State private var clutchSelectedSegmentIndex: Int?
    @State private var sourceHighlightRange: NSRange?
    @State private var clutchSelectionOrigin: ClutchSelectionOrigin?
    @State private var clutchOutputScrollFinalizeTask: Task<Void, Never>?
    @State private var isClutchLayoutLocked: Bool = false
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
            #if canImport(Translation)
            if let configuration = viewModel.tfMenuPreparationConfiguration {
                TFMenuPreparationTaskHost(
                    configuration: configuration,
                    generation: viewModel.tfMenuPreparationGeneration,
                    viewModel: viewModel
                )
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
        .onChange(of: viewModel.inputText) { oldValue, newValue in
            viewModel.handleSourceTextEdited(previousText: oldValue, currentText: newValue)
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
            .fileImporter(
                isPresented: $isFileImportPickerPresented,
                allowedContentTypes: iOSImportContentTypes,
                allowsMultipleSelection: false,
                onCompletion: handleImportedDocumentResult
            )
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItem,
                matching: .images
            )
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                Task {
                    await handlePickedPhotoItem(item)
                }
            }
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
                    Button {
                        dismissKeyboard()
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
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
                .fileImporter(
                    isPresented: $isFileImportPickerPresented,
                    allowedContentTypes: iOSImportContentTypes,
                    allowsMultipleSelection: false,
                    onCompletion: handleImportedDocumentResult
                )
                .photosPicker(
                    isPresented: $isPhotoPickerPresented,
                    selection: $selectedPhotoItem,
                    matching: .images
                )
                .onChange(of: selectedPhotoItem) { _, item in
                    guard let item else { return }
                    Task {
                        await handlePickedPhotoItem(item)
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button {
                            dismissKeyboard()
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
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
            Text(localized("ui.target.none_plural", defaultValue: "No target languages"))
                .foregroundStyle(.secondary)
        } else {
            Menu {
                translationModeToggleMenuItem
                Divider()
                ForEach(viewModel.targetLanguageOptions) { option in
                    Button {
                        viewModel.selectTargetLanguageFromMenu(option.code)
                    } label: {
                        let baseLabel = option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle)
                        let decoratedLabel = decoratedTargetLanguageMenuLabel(baseLabel, targetLanguageCode: option.code)
                        if option.code == viewModel.targetLanguage {
                            Label(decoratedLabel, systemImage: "checkmark")
                        } else {
                            Text(decoratedLabel)
                        }
                    }
                    .disabled(viewModel.isTargetLanguageSelectionDisabled(option.code))
                    #if os(iOS)
                    .opacity(viewModel.isTargetLanguageSelectionDisabled(option.code) ? 0.3 : 1.0)
                    #endif
                    .help(viewModel.targetLanguageSelectionHelpText(for: option.code) ?? "")
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
    private var inlineLanguageMenu: some View {
        if viewModel.targetLanguageOptions.isEmpty {
            Text(localized("ui.target.none", defaultValue: "No target"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Menu {
                translationModeToggleMenuItem
                Divider()
                ForEach(viewModel.targetLanguageOptions) { option in
                    Button {
                        viewModel.selectTargetLanguageFromMenu(option.code)
                    } label: {
                        let baseLabel = option.menuLabel(showCode: developerModeEnabled, style: currentLabelStyle)
                        let decoratedLabel = decoratedTargetLanguageMenuLabel(baseLabel, targetLanguageCode: option.code)
                        if option.code == viewModel.targetLanguage {
                            Label(decoratedLabel, systemImage: "checkmark")
                        } else {
                            Text(decoratedLabel)
                        }
                    }
                    .disabled(viewModel.isTargetLanguageSelectionDisabled(option.code))
                    #if os(iOS)
                    .opacity(viewModel.isTargetLanguageSelectionDisabled(option.code) ? 0.3 : 1.0)
                    #endif
                    .help(viewModel.targetLanguageSelectionHelpText(for: option.code) ?? "")
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

    private func decoratedTargetLanguageMenuLabel(_ baseLabel: String, targetLanguageCode: String) -> String {
        if let mark = viewModel.tfMenuDownloadMark(for: targetLanguageCode) {
            return "\(baseLabel) \(mark)"
        }
        return baseLabel
    }

    @ViewBuilder
    private var translationModeToggleMenuItem: some View {
        if viewModel.isAppleIntelligenceAvailable {
            Button(
                viewModel.usesAppleIntelligenceTranslation
                    ? localized("menu.translate.switch_to_standard", defaultValue: "Switch to Standard Translation")
                    : localized("menu.translate.switch_to_ai", defaultValue: "Switch to AI Translation")
            ) {
                if viewModel.usesAppleIntelligenceTranslation {
                    viewModel.switchToStandardTranslation()
                } else {
                    viewModel.switchToAppleIntelligenceTranslation()
                }
            }
        } else {
            Button(localized("menu.translate.ai_unavailable", defaultValue: "AI translation unavailable on this device")) { }
                .disabled(true)
        }
    }

    @ViewBuilder
    private func settingsMenu(iconSize: CGFloat, frameSize: CGFloat) -> some View {
        Menu {
            #if os(iOS)
            Toggle(autoTranslateToggleTitle, isOn: $autoTranslateImportedTextEnabled)
            #endif
            Toggle(localized("ui.settings.clutch", defaultValue: "Clutch"), isOn: $clutchModeEnabled)
            Toggle(localized("ui.settings.developer_mode", defaultValue: "Developer Mode"), isOn: $developerModeEnabled)
            if developerModeEnabled {
                Toggle(localized("ui.settings.verbose_console", defaultValue: "Verbose Console"), isOn: $developerVerboseModeEnabled)
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
        GroupBox(localized("ui.dev.process_mode", defaultValue: "Process Mode")) {
            Picker(localized("ui.dev.experiment", defaultValue: "Experiment"), selection: $viewModel.experimentMode) {
                ForEach(TranslationExperimentMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
        }

        GroupBox(localized("ui.dev.glossary", defaultValue: "Glossary (source=target)")) {
            TextEditor(text: $viewModel.glossaryText)
                .frame(minHeight: 80)
        }

        GroupBox(localized("ui.dev.indexes", defaultValue: "Indexes")) {
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
                Text(localized("ui.dev.console", defaultValue: "Console"))
                Spacer()
                Button(localized("ui.action.clear", defaultValue: "Clear")) {
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
                Text(localized("ui.section.source", defaultValue: "Source"))
                    .font(.system(size: layoutTokens.sectionTitleFontSize, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                #if os(iOS)
                Menu {
                    Button {
                        presentFileImporter()
                    } label: {
                        Label(
                            localized("ui.import.files", defaultValue: "Files"),
                            systemImage: isFileImportPickerPresented ? "folder.fill" : "folder"
                        )
                    }

                    Button {
                        presentPhotoPicker()
                    } label: {
                        Label(
                            localized("ui.import.album", defaultValue: "Album"),
                            systemImage: isPhotoPickerPresented ? "photo.on.rectangle.angled.fill" : "photo.on.rectangle.angled"
                        )
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .menuOrder(.fixed)
                .buttonStyle(.bordered)
                .accessibilityLabel(localized("ui.action.import", defaultValue: "Import"))
                #endif
                Button(localized("ui.action.paste", defaultValue: "Paste"), action: pasteInputFromClipboard)
                    .buttonStyle(.bordered)
                Button(localized("ui.action.clear", defaultValue: "Clear")) {
                    viewModel.clearSourceTextAndResetLanguageState()
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
            topAlignOnHighlightScroll: shouldTopAlignSourceForClutch,
            lockDownwardScrollForRestore: canUseCompactOutputReadingMode && isCompactOutputReadingMode,
            onDownwardSwipeWhileRestoreLocked: handleSourceRestoreSwipeGesture,
            onScrollStateChanged: handleSourceScrollStateChange,
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
            topAlignOnHighlightScroll: shouldTopAlignSourceForClutch,
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
                Text(localized("ui.section.output", defaultValue: "Output"))
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
                .help(localized("ui.action.copy_output", defaultValue: "Copy output"))
                .disabled(viewModel.translatedText.isEmpty)

                Button(localized("menu.translate.action.translate", defaultValue: "Translate")) {
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
                }
                .onChange(of: clutchSelectedSegmentIndex) { _, segmentIndex in
                    guard clutchModeEnabled else { return }
                    guard let segmentIndex else { return }
                    guard clutchSelectionOrigin != .output else { return }
                    scrollOutputToClutchTarget(segmentIndex: segmentIndex, proxy: proxy)
                }
                .onChange(of: clutchSelectionOrigin) { _, origin in
                    guard clutchModeEnabled else { return }
                    guard origin == .source else { return }
                    guard let segmentIndex = clutchSelectedSegmentIndex else { return }
                    scrollOutputToClutchTarget(segmentIndex: segmentIndex, proxy: proxy)
                }
            }
            .coordinateSpace(name: outputScrollCoordinateSpaceName)
            #if os(iOS)
            .frame(maxHeight: .infinity, alignment: .top)
            .simultaneousGesture(editorPinchGesture(host: .output), including: .gesture)
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
            Text(outputAttributedText)
                .font(.system(size: editorFontPointSize))
                .textSelection(.enabled)
                .environment(\.openURL, OpenURLAction { url in
                    handleOutputOpenURL(url)
                })
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputAttributedText: AttributedString {
        let defaultOutputTextColor: Color = colorScheme == .dark ? .white : .primary
        var combined = AttributedString()
        for index in viewModel.segmentOutputs.indices {
            let segment = viewModel.segmentOutputs[index]
            var chunk = AttributedString(segment.translatedText + joinerAfterOutputSegment(at: index))
            chunk.foregroundColor = defaultOutputTextColor
            if segment.isUnsafeFallback {
                if segment.isUnsafeRecoveredByTranslationFramework {
                    chunk.backgroundColor = unsafeRecoveredSegmentBackgroundColor
                    chunk.foregroundColor = unsafeRecoveredSegmentForegroundColor
                } else {
                    chunk.backgroundColor = unsafeSegmentBackgroundColor
                    chunk.foregroundColor = unsafeSegmentForegroundColor
                }
            }
            if clutchModeEnabled, clutchSelectedSegmentIndex == segment.segmentIndex {
                chunk.backgroundColor = Color(red: 1.0, green: 190.0 / 255.0, blue: 56.0 / 255.0).opacity(0.4)
            }
            if let tapURL = outputSegmentTapURL(for: segment.segmentIndex) {
                chunk.link = tapURL
                chunk.foregroundColor = defaultOutputTextColor
                chunk.underlineStyle = nil
                chunk.underlineColor = .clear
            }
            combined += chunk
        }
        return combined
    }

    private func outputSegmentTapURL(for segmentIndex: Int) -> URL? {
        URL(string: "prebabellens-clutch://segment/\(segmentIndex)")
    }

    private func handleOutputOpenURL(_ url: URL) -> OpenURLAction.Result {
        guard url.scheme == "prebabellens-clutch" else { return .systemAction }
        guard url.host == "segment" else { return .handled }
        guard let segmentIndex = Int(url.lastPathComponent) else { return .handled }
        handleOutputSegmentTap(segmentIndex)
        return .handled
    }

    private func clutchOutputHighlightBackground(for segmentIndex: Int) -> Color {
        guard clutchModeEnabled, clutchSelectedSegmentIndex == segmentIndex else { return .clear }
        return Color(red: 1.0, green: 190.0 / 255.0, blue: 56.0 / 255.0).opacity(0.4)
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
            scheduleSourceDrivenClutchStateUpdate(
                sourceRange: nil,
                selectedSegmentIndex: nil
            )
            return
        }

        guard let binding = clutchSegmentBindings.first(where: { binding in
            let lower = binding.sourceRange.location
            let upper = binding.sourceRange.location + binding.sourceRange.length
            return utf16Location >= lower && utf16Location <= upper
        }) else {
            scheduleSourceDrivenClutchStateUpdate(
                sourceRange: nil,
                selectedSegmentIndex: nil
            )
            return
        }

        scheduleSourceDrivenClutchStateUpdate(
            sourceRange: binding.sourceRange,
            selectedSegmentIndex: binding.segmentIndex
        )
    }

    private func scheduleSourceDrivenClutchStateUpdate(
        sourceRange: NSRange?,
        selectedSegmentIndex: Int?
    ) {
        DispatchQueue.main.async {
            sourceHighlightRange = sourceRange
            clutchSelectionOrigin = selectedSegmentIndex == nil ? nil : .source
            clutchSelectedSegmentIndex = selectedSegmentIndex
        }
    }

    private var shouldAutoCenterSourceForClutch: Bool {
        clutchSelectionOrigin == .output
    }

    private var shouldTopAlignSourceForClutch: Bool {
        isCompactStackedLayoutActive
    }

    private func resetClutchSelection() {
        clutchOutputScrollFinalizeTask?.cancel()
        clutchOutputScrollFinalizeTask = nil
        isClutchLayoutLocked = false
        clutchSelectedSegmentIndex = nil
        sourceHighlightRange = nil
        clutchSelectionOrigin = nil
    }

    private func scrollOutputToClutchTarget(segmentIndex: Int, proxy: ScrollViewProxy) {
        isClutchLayoutLocked = true
        let anchor: UnitPoint = isCompactStackedLayoutActive ? .top : .center
        withAnimation(.easeInOut(duration: 0.24)) {
            proxy.scrollTo(outputSegmentID(for: segmentIndex), anchor: anchor)
        }

        clutchOutputScrollFinalizeTask?.cancel()
        clutchOutputScrollFinalizeTask = Task {
            #if os(iOS)
            // Keep one delayed alignment pass to avoid visible jitter.
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard clutchSelectedSegmentIndex == segmentIndex else { return }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(outputSegmentID(for: segmentIndex), anchor: anchor)
                }
            }
            #else
            try? await Task.sleep(nanoseconds: 280_000_000)
            #endif
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isClutchLayoutLocked = false
            }
        }
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
        // Temporarily disabled by product decision.
        false
    }

    private var isOutputScrollLocked: Bool {
        #if os(macOS)
        return false
        #else
        guard canUseCompactOutputReadingMode else { return false }
        // Keep normal scrolling enabled when fields are in the default (restored) size.
        if !isCompactOutputReadingMode { return false }
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
        guard !isClutchLayoutLocked else { return }
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
    }

    private var outputCollapseActivationGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard canUseCompactOutputReadingMode else { return }
                guard !isClutchLayoutLocked else { return }
                isOutputCollapseDragActive = true
                if isCompactOutputReadingMode {
                    return
                }
                guard value.translation.height < -3 else { return }
                didCollapseDuringCurrentDrag = true
                withAnimation(.easeInOut(duration: 0.24)) {
                    isCompactOutputReadingMode = true
                }
                hasReachedTopEdgeSinceCollapse = currentOutputScrollDistance <= compactOutputExpandReleaseOffset
                hasReachedSourceTopEdgeSinceCollapse = currentSourceScrollDistance <= compactOutputExpandReleaseOffset
                isOutputExpandSpringArmed = false
                isSourceExpandSpringArmed = false
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
        hasReachedSourceTopEdgeSinceCollapse = false
        currentSourceScrollDistance = 0
        previousSourceScrollDistance = 0
        isSourceExpandSpringArmed = false
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
        hasReachedSourceTopEdgeSinceCollapse = false
        isSourceExpandSpringArmed = false
    }

    private func handleSourceScrollStateChange(
        scrollDistanceFromTop: CGFloat,
        topSpringDistance: CGFloat,
        isDragging: Bool
    ) {
        guard canUseCompactOutputReadingMode, isCompactOutputReadingMode else { return }

        let previousDistance = currentSourceScrollDistance
        previousSourceScrollDistance = previousDistance
        currentSourceScrollDistance = scrollDistanceFromTop
        if !isDragging {
            isSourceExpandSpringArmed = false
            return
        }

        let isPullingDownTowardTop = scrollDistanceFromTop + 0.5 < previousDistance
        let isTopSpringActive = topSpringDistance > compactOutputExpandReleaseOffset
        let isPullingDownFromAnyPosition = isPullingDownTowardTop || isTopSpringActive

        guard isPullingDownFromAnyPosition else { return }
        guard !isSourceExpandSpringArmed else { return }
        isSourceExpandSpringArmed = true
        // Match Output behavior: first downward swipe restores field heights.
        restoreDefaultFieldSizesFromCompactMode()
    }

    private func handleSourceRestoreSwipeGesture() {
        guard canUseCompactOutputReadingMode, isCompactOutputReadingMode else { return }
        guard !isSourceExpandSpringArmed else { return }
        isSourceExpandSpringArmed = true
        restoreDefaultFieldSizesFromCompactMode()
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
                        Label(localized("menu.translate.action.stop", defaultValue: "Stop"), systemImage: "stop.fill")
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
        return localized("menu.translate.target_language", defaultValue: "Target Language")
    }

    private var currentLabelStyle: TargetLanguageOption.LabelStyle {
        viewModel.usesAppleIntelligenceTranslation ? .ai : .machine
    }

    private func localized(_ key: String, defaultValue: String) -> String {
        NSLocalizedString(key, bundle: .main, value: defaultValue, comment: "")
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
                viewModel.handleSourceTextPasted(text)
            }
        #elseif canImport(UIKit)
            if let text = UIPasteboard.general.string, !text.isEmpty {
                viewModel.handleSourceTextPasted(text)
            }
        #endif
    }
    // #endregion

    #if os(macOS)
    #endif

    #if os(iOS)
    private var iOSImportContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .image]
        if let txt = UTType(filenameExtension: "txt") {
            types.append(txt)
        }
        if let doc = UTType(filenameExtension: "doc") {
            types.append(doc)
        }
        if let docx = UTType(filenameExtension: "docx") {
            types.append(docx)
        }
        return types
    }

    private func handleImportedDocumentResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                guard let text = loadImportedText(from: url) else {
                    showImportToast(localized("ui.import.ocr_failed", defaultValue: "Could not read text."))
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    showImportToast(localized("ui.import.ocr_failed", defaultValue: "Could not read text."))
                    return
                }
                viewModel.handleSourceTextPasted(text)
            }
        case .failure:
            break
        }
    }

    private func handlePickedPhotoItem(_ item: PhotosPickerItem) async {
        defer {
            Task { @MainActor in
                selectedPhotoItem = nil
            }
        }

        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        guard let text = await recognizeTextInImageData(data) else {
            await MainActor.run {
                showImportToast(localized("ui.import.ocr_failed", defaultValue: "Could not read text."))
            }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run {
                showImportToast(localized("ui.import.ocr_failed", defaultValue: "Could not read text."))
            }
            return
        }
        await MainActor.run {
            viewModel.handleSourceTextPasted(trimmed)
        }
    }

    private func recognizeTextInImageData(_ data: Data) async -> String? {
        let recognitionLanguages = await MainActor.run {
            recognitionLanguageCandidatesForOCR()
        }
        let task = Task.detached(priority: .userInitiated) { () -> String? in
            guard let image = UIImage(data: data) else { return nil }
            guard let cgImage = image.cgImage else { return nil }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if let supportedLanguages = try? request.supportedRecognitionLanguages() {
                var supportedByNormalizedCode: [String: String] = [:]
                for language in supportedLanguages {
                    let normalized = Self.normalizeOCRLanguageCode(language)
                    if !normalized.isEmpty, supportedByNormalizedCode[normalized] == nil {
                        supportedByNormalizedCode[normalized] = language
                    }
                }
                let usable: [String] = recognitionLanguages.compactMap { candidate -> String? in
                    let normalized = Self.normalizeOCRLanguageCode(candidate)
                    guard !normalized.isEmpty else { return nil }
                    return supportedByNormalizedCode[normalized]
                }
                if !usable.isEmpty {
                    request.recognitionLanguages = usable
                }
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }

            guard let observations = request.results else { return nil }
            let lines = observations.compactMap { $0.topCandidates(1).first?.string }
            let joined = lines.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return await task.value
    }

    private func recognitionLanguageCandidatesForOCR() -> [String] {
        var candidates: [String] = []
        let preferredLocaleMap = preferredLocaleByLanguageCode()

        if let preferred = Locale.preferredLanguages.first {
            candidates.append(contentsOf: expandedOCRLanguageCandidates(
                from: preferred,
                preferredLocaleMap: preferredLocaleMap
            ))
        }
        if !viewModel.detectedLanguageCode.isEmpty {
            candidates.append(contentsOf: expandedOCRLanguageCandidates(
                from: viewModel.detectedLanguageCode,
                preferredLocaleMap: preferredLocaleMap
            ))
        }
        if !viewModel.targetLanguage.isEmpty {
            candidates.append(contentsOf: expandedOCRLanguageCandidates(
                from: viewModel.targetLanguage,
                preferredLocaleMap: preferredLocaleMap
            ))
        }

        var seen: Set<String> = []
        return candidates.filter { code in
            guard !code.isEmpty else { return false }
            if seen.contains(code) { return false }
            seen.insert(code)
            return true
        }
    }

    private func normalizedOCRLanguageCode(_ code: String) -> String {
        Self.normalizeOCRLanguageCode(code)
    }

    private nonisolated static func normalizeOCRLanguageCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let hyphenated = trimmed.replacingOccurrences(of: "_", with: "-")
        guard hyphenated.lowercased() != "und" else { return "" }

        let components = hyphenated.split(separator: "-").map(String.init)
        guard let first = components.first, !first.isEmpty else { return "" }

        var normalizedComponents: [String] = [first.lowercased()]
        for component in components.dropFirst() {
            if component.count == 4 {
                normalizedComponents.append(component.prefix(1).uppercased() + component.dropFirst().lowercased())
            } else if component.count == 2 || component.count == 3 {
                normalizedComponents.append(component.uppercased())
            } else {
                normalizedComponents.append(component)
            }
        }

        return normalizedComponents.joined(separator: "-")
    }

    private func expandedOCRLanguageCandidates(
        from rawCode: String,
        preferredLocaleMap: [String: String]
    ) -> [String] {
        let normalized = normalizedOCRLanguageCode(rawCode)
        guard !normalized.isEmpty else { return [] }

        let base = String(normalized.split(separator: "-").first ?? "")
        guard !base.isEmpty else { return [normalized] }

        var expanded: [String] = []
        if let locale = preferredLocaleMap[base], !locale.isEmpty {
            expanded.append(locale)
        }
        expanded.append(normalized)
        expanded.append(base)
        return expanded
    }

    private func preferredLocaleByLanguageCode() -> [String: String] {
        var map: [String: String] = [:]
        for preferred in Locale.preferredLanguages {
            let normalized = normalizedOCRLanguageCode(preferred)
            guard !normalized.isEmpty else { continue }
            let base = String(normalized.split(separator: "-").first ?? "")
            guard !base.isEmpty else { continue }
            if map[base] == nil {
                map[base] = normalized
            }
        }
        return map
    }

    private func loadImportedText(from fileURL: URL) -> String? {
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

        let lowercasedExtension = fileURL.pathExtension.lowercased()

        if isImageExtension(lowercasedExtension),
           let data = try? Data(contentsOf: fileURL) {
            return extractTextFromImageDataOnIOS(data)
        }

        if lowercasedExtension == "pdf",
           let extracted = extractTextFromPDFOnIOS(fileURL),
           !extracted.isEmpty {
            return extracted
        }

        if ["doc", "docx", "pages"].contains(lowercasedExtension),
           let extracted = extractTextWithAttributedStringOnIOS(from: fileURL),
           !extracted.isEmpty {
            return extracted
        }

        if let data = try? Data(contentsOf: fileURL) {
            if let utf8 = String(data: data, encoding: .utf8),
               !utf8.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return utf8
            }
            if let utf16 = String(data: data, encoding: .utf16),
               !utf16.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return utf16
            }
            if let shiftJIS = String(data: data, encoding: .shiftJIS),
               !shiftJIS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return shiftJIS
            }
        }

        return nil
    }

    private func isImageExtension(_ fileExtension: String) -> Bool {
        guard !fileExtension.isEmpty else { return false }
        guard let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    private func extractTextFromImageDataOnIOS(_ data: Data) -> String? {
        guard let image = UIImage(data: data) else { return nil }
        guard let cgImage = image.cgImage else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let supportedLanguages = try? request.supportedRecognitionLanguages() {
            let candidates = recognitionLanguageCandidatesForOCR()
            var supportedByNormalizedCode: [String: String] = [:]
            for language in supportedLanguages {
                let normalized = normalizedOCRLanguageCode(language)
                if !normalized.isEmpty, supportedByNormalizedCode[normalized] == nil {
                    supportedByNormalizedCode[normalized] = language
                }
            }
            let usable: [String] = candidates.compactMap { candidate -> String? in
                let normalized = normalizedOCRLanguageCode(candidate)
                guard !normalized.isEmpty else { return nil }
                return supportedByNormalizedCode[normalized]
            }
            if !usable.isEmpty {
                request.recognitionLanguages = usable
            }
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    private func presentFileImporter() {
        // Present after the menu dismissal animation finishes to avoid
        // UIKit reparenting warnings when launching pickers from Menu actions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isPhotoPickerPresented = false
            isFileImportPickerPresented = true
        }
    }

    private func presentPhotoPicker() {
        // Present after the menu dismissal animation finishes to avoid
        // UIKit reparenting warnings when launching pickers from Menu actions.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            isFileImportPickerPresented = false
            isPhotoPickerPresented = true
        }
    }

    private func extractTextWithAttributedStringOnIOS(from fileURL: URL) -> String? {
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

    private func extractTextFromPDFOnIOS(_ fileURL: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: fileURL) else { return nil }

        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pages.append(normalizePDFSoftLineBreaksOnIOS(text))
            }
        }

        let combined = pages.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
        #else
        return nil
        #endif
    }

    private func normalizePDFSoftLineBreaksOnIOS(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return text }

        let headingDataLengthThreshold = shortHeadingDataThresholdOnIOS(for: lines)
        var resultLines: [String] = []
        resultLines.reserveCapacity(lines.count)
        var previousLineForcesBreak = true
        var verticalWritingMode = false

        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                if !resultLines.isEmpty, resultLines.last != "" {
                    resultLines.append("")
                }
                previousLineForcesBreak = true
                verticalWritingMode = false
                continue
            }

            if !verticalWritingMode {
                let verticalRunCount = consecutiveVerticalCandidateCountOnIOS(from: lineIndex, in: lines)
                if verticalRunCount >= 3 {
                    verticalWritingMode = true
                }
            }

            let isLineEndMarker = shouldKeepLineBreakOnIOS(afterRawLine: rawLine)
            let isBulletLine = isBulletLikeLineOnIOS(trimmedLine)
            let isNumericDataLine = isNumericDataOnlyLineOnIOS(trimmedLine)
            let isShortHeadingDataLine = isShortHeadingOrDataLineOnIOS(
                trimmedLine,
                threshold: headingDataLengthThreshold
            )
            let blocksIncomingSoftJoin = isBulletLine || isNumericDataLine
            let blocksOutgoingSoftJoin = isBulletLine || isNumericDataLine || isShortHeadingDataLine

            if verticalWritingMode {
                if
                    var last = resultLines.last,
                    !last.isEmpty
                {
                    last += trimmedLine
                    resultLines[resultLines.count - 1] = last
                } else {
                    resultLines.append(trimmedLine)
                }
            } else if
                !previousLineForcesBreak,
                !blocksIncomingSoftJoin,
                var last = resultLines.last,
                !last.isEmpty
            {
                if shouldJoinWithoutSpaceOnIOS(previousLine: last) {
                    last += trimmedLine
                } else {
                    last += " " + trimmedLine
                }
                resultLines[resultLines.count - 1] = last
            } else {
                resultLines.append(trimmedLine)
            }

            if isLineEndMarker {
                verticalWritingMode = false
            }
            previousLineForcesBreak = isLineEndMarker || blocksOutgoingSoftJoin
        }

        return resultLines.joined(separator: "\n")
    }

    private func shouldKeepLineBreakOnIOS(afterRawLine rawLine: String) -> Bool {
        guard let trailing = lastNonWhitespaceCharacterOnIOS(in: rawLine) else { return false }
        return isLineEndMarkerCharacterOnIOS(trailing)
    }

    private func isLineEndMarkerCharacterOnIOS(_ character: Character) -> Bool {
        switch character {
        case ".", "。", "!", "?", "！", "？",
             ")", "]", "}", "）", "］", "｝", "〉", "》", "」", "』", "】", "〙", "〗":
            return true
        default:
            return false
        }
    }

    private func isBulletLikeLineOnIOS(_ trimmedLine: String) -> Bool {
        let leadingTrimmed = trimmedLine.trimmingCharacters(in: .whitespaces)
        guard !leadingTrimmed.isEmpty else { return false }

        if let first = leadingTrimmed.first, ["・", "＊", "ー", "-"].contains(first) {
            return true
        }

        var index = leadingTrimmed.startIndex
        var digitCount = 0
        while index < leadingTrimmed.endIndex, leadingTrimmed[index].isNumber {
            digitCount += 1
            index = leadingTrimmed.index(after: index)
        }

        if digitCount > 0, index < leadingTrimmed.endIndex {
            let delimiter = leadingTrimmed[index]
            if delimiter == "." || delimiter == ":" || delimiter == ";" {
                return true
            }
        }
        return false
    }

    private func isNumericDataOnlyLineOnIOS(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.isEmpty else { return false }
        return trimmedLine.range(of: #"^[0-9/:\s]+$"#, options: .regularExpression) != nil
    }

    private func shortHeadingDataThresholdOnIOS(for lines: [String]) -> Int {
        let introMax = lines
            .prefix(30)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .max() ?? 0
        return introMax / 2
    }

    private func isShortHeadingOrDataLineOnIOS(_ trimmedLine: String, threshold: Int) -> Bool {
        guard threshold > 0 else { return false }
        return !trimmedLine.isEmpty && trimmedLine.count <= threshold
    }

    private func consecutiveVerticalCandidateCountOnIOS(from startIndex: Int, in allLines: [String]) -> Int {
        var index = startIndex
        var count = 0
        while index < allLines.count {
            let trimmed = allLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if isSingleCJKVerticalCandidateOnIOS(trimmed) {
                count += 1
                index += 1
            } else {
                break
            }
        }
        return count
    }

    private func isSingleCJKVerticalCandidateOnIOS(_ line: String) -> Bool {
        guard line.count == 1, let first = line.first else { return false }
        return first.unicodeScalars.allSatisfy(isCJKExcludingHangulOnIOS)
    }

    private func shouldJoinWithoutSpaceOnIOS(previousLine: String) -> Bool {
        guard let trailing = lastNonWhitespaceCharacterOnIOS(in: previousLine) else { return false }
        return trailing.unicodeScalars.allSatisfy(isCJKExcludingHangulOnIOS)
    }

    private func lastNonWhitespaceCharacterOnIOS(in text: String) -> Character? {
        text.last(where: { !$0.isWhitespace })
    }

    private func isCJKExcludingHangulOnIOS(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value

        switch value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return false
        default:
            break
        }

        switch value {
        case 0x2E80...0x2EFF,
             0x3000...0x303F,
             0x3040...0x30FF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

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
        showImportToast(sharedImportToastTitle)
    }

    private func showImportToast(_ message: String) {
        toastDismissTask?.cancel()
        importToastMessage = message
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
        localized("ui.settings.auto_translate_after_import", defaultValue: "Auto Translate After Import")
    }

    private var sharedImportToastTitle: String {
        localized("ui.import.shared_text_imported", defaultValue: "Shared text imported.")
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

private struct TFMenuPreparationTaskHost: View {
    let configuration: TranslationSession.Configuration
    let generation: UUID
    @ObservedObject var viewModel: TranslationViewModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .id(generation)
            .translationTask(configuration) { session in
                guard let targetCode = viewModel.tfMenuPreparationTargetCode(for: generation) else { return }
                do {
                    try await TFMenuPreparationRunner.prepare(using: session)
                    viewModel.completeTFMenuPreparation(
                        generation: generation,
                        targetCode: targetCode,
                        errorDescription: nil
                    )
                } catch {
                    viewModel.completeTFMenuPreparation(
                        generation: generation,
                        targetCode: targetCode,
                        errorDescription: (error as NSError).localizedDescription
                    )
                }
            }
    }
}

private final class TFMenuPreparationRunner {
    static func prepare(using session: TranslationSession) async throws {
        try await session.prepareTranslation()
    }
}
#endif

#if os(iOS)
private struct IOSClutchSourceTextEditor: UIViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let highlightedRange: NSRange?
    let centerOnHighlightIfNeeded: Bool
    let topAlignOnHighlightScroll: Bool
    let lockDownwardScrollForRestore: Bool
    let onDownwardSwipeWhileRestoreLocked: () -> Void
    let onScrollStateChanged: (_ scrollDistanceFromTop: CGFloat, _ topSpringDistance: CGFloat, _ isDragging: Bool) -> Void
    let onCursorLocationChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onCursorLocationChanged: onCursorLocationChanged,
            onDownwardSwipeWhileRestoreLocked: onDownwardSwipeWhileRestoreLocked,
            onScrollStateChanged: onScrollStateChanged
        )
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

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        if uiView.font?.pointSize != fontSize {
            uiView.font = UIFont.systemFont(ofSize: fontSize)
        }
        context.coordinator.updateScrollBehavior(lockDownwardScrollForRestore: lockDownwardScrollForRestore)
        context.coordinator.performProgrammaticUpdate {
            uiView.applyClutchHighlight(
                highlightedRange,
                centerIfNeeded: centerOnHighlightIfNeeded,
                topAlignIfNeeded: topAlignOnHighlightScroll
            )
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private let onCursorLocationChanged: (Int) -> Void
        private let onDownwardSwipeWhileRestoreLocked: () -> Void
        private let onScrollStateChanged: (_ scrollDistanceFromTop: CGFloat, _ topSpringDistance: CGFloat, _ isDragging: Bool) -> Void
        private weak var textView: UITextView?
        private var isProgrammaticUpdateInProgress: Bool = false
        private var lockDownwardScrollForRestore: Bool = false
        private var previousContentOffsetY: CGFloat?

        init(
            text: Binding<String>,
            onCursorLocationChanged: @escaping (Int) -> Void,
            onDownwardSwipeWhileRestoreLocked: @escaping () -> Void,
            onScrollStateChanged: @escaping (_ scrollDistanceFromTop: CGFloat, _ topSpringDistance: CGFloat, _ isDragging: Bool) -> Void
        ) {
            _text = text
            self.onCursorLocationChanged = onCursorLocationChanged
            self.onDownwardSwipeWhileRestoreLocked = onDownwardSwipeWhileRestoreLocked
            self.onScrollStateChanged = onScrollStateChanged
        }

        func attachTextView(_ textView: UITextView) {
            self.textView = textView
        }

        func updateScrollBehavior(lockDownwardScrollForRestore: Bool) {
            self.lockDownwardScrollForRestore = lockDownwardScrollForRestore
            if !lockDownwardScrollForRestore {
                previousContentOffsetY = nil
            }
        }

        func performProgrammaticUpdate(_ action: () -> Void) {
            isProgrammaticUpdateInProgress = true
            action()
            isProgrammaticUpdateInProgress = false
        }

        func makeKeyboardAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()

            let spacer = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
            let doneStyle: UIBarButtonItem.Style
            if #available(iOS 26.0, *) {
                doneStyle = .prominent
            } else {
                doneStyle = .done
            }
            let doneImage = UIImage(systemName: "keyboard.chevron.compact.down")
            let done = UIBarButtonItem(image: doneImage, style: doneStyle, target: self, action: #selector(doneTapped))

            toolbar.items = [spacer, done]
            return toolbar
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticUpdateInProgress else { return }
            text = textView.text ?? ""
            // During IME composition, defer clutch tracking until conversion is committed.
            if textView.markedTextRange != nil { return }
            onCursorLocationChanged(textView.selectedRange.location)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isProgrammaticUpdateInProgress else { return }
            // Avoid updating clutch while the user is still composing marked text.
            if textView.markedTextRange != nil { return }
            onCursorLocationChanged(textView.selectedRange.location)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            onCursorLocationChanged(textView.selectedRange.location)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let previousY = previousContentOffsetY ?? scrollView.contentOffset.y
            if lockDownwardScrollForRestore, scrollView.isDragging, scrollView.contentOffset.y < previousY {
                onDownwardSwipeWhileRestoreLocked()
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: previousY), animated: false)
            }
            previousContentOffsetY = scrollView.contentOffset.y
            reportSourceScrollState(from: scrollView)
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            previousContentOffsetY = scrollView.contentOffset.y
            reportSourceScrollState(from: scrollView)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate _: Bool) {
            previousContentOffsetY = scrollView.contentOffset.y
            reportSourceScrollState(from: scrollView)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            previousContentOffsetY = scrollView.contentOffset.y
            reportSourceScrollState(from: scrollView)
        }

        private func reportSourceScrollState(from scrollView: UIScrollView) {
            let topOffset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            let scrollDistanceFromTop = max(0, topOffset)
            let topSpringDistance = max(0, -topOffset)
            onScrollStateChanged(scrollDistanceFromTop, topSpringDistance, scrollView.isDragging)
        }

        @objc private func doneTapped() {
            textView?.resignFirstResponder()
        }
    }
}

private extension UITextView {
    func applyClutchHighlight(_ range: NSRange?, centerIfNeeded: Bool, topAlignIfNeeded: Bool) {
        let textStorage = textStorage
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let font = self.font ?? UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize)
        let selected = selectedRange

        textStorage.beginEditing()
        textStorage.removeAttribute(.backgroundColor, range: fullRange)
        textStorage.addAttribute(.font, value: font, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)

        if
            let range,
            range.location >= 0,
            range.length > 0,
            NSMaxRange(range) <= textStorage.length
        {
            textStorage.addAttribute(
                .backgroundColor,
                value: UIColor(red: 1.0, green: 190.0 / 255.0, blue: 56.0 / 255.0, alpha: 0.4),
                range: range
            )
        }
        textStorage.endEditing()

        if selectedRange != selected {
            selectedRange = selected
        }

        if
            let range,
            range.location >= 0,
            range.length > 0,
            NSMaxRange(range) <= textStorage.length
        {
            scrollHighlightedRangeIfNeeded(
                range,
                centerIfNeeded: centerIfNeeded,
                topAlignIfNeeded: topAlignIfNeeded
            )
        }
    }

    private func scrollHighlightedRangeIfNeeded(
        _ range: NSRange,
        centerIfNeeded: Bool,
        topAlignIfNeeded: Bool
    ) {
        guard centerIfNeeded else { return }
        applyClutchScrollOffset(
            for: range,
            topAlignIfNeeded: topAlignIfNeeded,
            force: false,
            animated: false
        )

        // Keep only one trailing correction pass to minimize shake.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            self?.applyClutchScrollOffset(
                for: range,
                topAlignIfNeeded: topAlignIfNeeded,
                force: true,
                animated: false
            )
        }
    }

    private func applyClutchScrollOffset(
        for range: NSRange,
        topAlignIfNeeded: Bool,
        force: Bool,
        animated: Bool
    ) {
        layoutIfNeeded()

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var targetRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        targetRect.origin.x += textContainerInset.left
        targetRect.origin.y += textContainerInset.top
        guard !targetRect.isEmpty else { return }

        let visibleRect = bounds.inset(by: adjustedContentInset)
        if !force, !topAlignIfNeeded, visibleRect.intersects(targetRect) {
            return
        }

        let y: CGFloat
        if topAlignIfNeeded {
            y = targetRect.minY - adjustedContentInset.top
        } else {
            y = targetRect.midY - (bounds.height * 0.5)
        }
        let minOffset = -adjustedContentInset.top
        let maxOffset = max(minOffset, contentSize.height - bounds.height + adjustedContentInset.bottom)
        let clampedY = min(max(y, minOffset), maxOffset)
        let targetOffset = CGPoint(x: contentOffset.x, y: clampedY)
        setContentOffset(targetOffset, animated: animated)
    }
}
#endif

#if os(macOS)
private struct MacSourceTextEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let highlightedRange: NSRange?
    let centerOnHighlightIfNeeded: Bool
    let topAlignOnHighlightScroll: Bool
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
        let isComposingIME = textView.hasMarkedText()

        // Avoid touching text storage while IME composition is active.
        if !isComposingIME, textView.string != text {
            textView.string = text
        }
        if textView.font?.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
        }
        if isComposingIME {
            return
        }
        textView.applyClutchHighlight(
            highlightedRange,
            centerIfNeeded: centerOnHighlightIfNeeded,
            topAlignIfNeeded: topAlignOnHighlightScroll
        )
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
            if textView.hasMarkedText() {
                return
            }
            onCursorLocationChanged(textView.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if textView.hasMarkedText() {
                return
            }
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
    private let clutchHighlightColor = NSColor(calibratedRed: 1.0, green: 190.0 / 255.0, blue: 56.0 / 255.0, alpha: 0.4)
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
        let pasteboard = sender.draggingPasteboard
        let hasSupportedType = pasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            || pasteboard.canReadObject(forClasses: [NSString.self], options: nil)
        return hasSupportedType ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let droppedText = SourceDropImport.resolveText(from: sender.draggingPasteboard) else {
            return false
        }
        onDropResolvedText?(droppedText)
        return true
    }

    func applyClutchHighlight(_ range: NSRange?, centerIfNeeded: Bool, topAlignIfNeeded: Bool) {
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
            scrollHighlightedRangeIfNeeded(range, topAlignIfNeeded: topAlignIfNeeded)
        }
    }

    private func scrollHighlightedRangeIfNeeded(_ range: NSRange, topAlignIfNeeded: Bool) {
        guard
            let layoutManager,
            let textContainer,
            let scrollView = enclosingScrollView
        else { return }

        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        guard !glyphRect.isNull, !glyphRect.isInfinite else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        if !topAlignIfNeeded, visibleRect.intersects(glyphRect) {
            return
        }

        var target = glyphRect
        if topAlignIfNeeded {
            target.origin.y = glyphRect.minY
        } else {
            target.origin.y -= max(0, (visibleRect.height - target.height) / 2)
            target.size.height = visibleRect.height
        }
        scrollView.contentView.scrollToVisible(target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

enum SourceDropImport {
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

        let headingDataLengthThreshold = shortHeadingDataThreshold(for: lines)
        var resultLines: [String] = []
        resultLines.reserveCapacity(lines.count)
        var previousLineForcesBreak = true
        var verticalWritingMode = false

        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                if !resultLines.isEmpty, resultLines.last != "" {
                    resultLines.append("")
                }
                previousLineForcesBreak = true
                verticalWritingMode = false
                continue
            }

            if !verticalWritingMode {
                let verticalRunCount = consecutiveVerticalCandidateCount(from: lineIndex, in: lines)
                if verticalRunCount >= 3 {
                    verticalWritingMode = true
                }
            }

            let isLineEndMarker = shouldKeepLineBreak(afterRawLine: rawLine)
            let isBulletLine = isBulletLikeLine(trimmedLine)
            let isNumericDataLine = isNumericDataOnlyLine(trimmedLine)
            let isShortHeadingDataLine = isShortHeadingOrDataLine(
                trimmedLine,
                threshold: headingDataLengthThreshold
            )
            let blocksIncomingSoftJoin = isBulletLine || isNumericDataLine
            let blocksOutgoingSoftJoin = isBulletLine || isNumericDataLine || isShortHeadingDataLine

            if verticalWritingMode {
                if
                    var last = resultLines.last,
                    !last.isEmpty
                {
                    last += trimmedLine
                    resultLines[resultLines.count - 1] = last
                } else {
                    resultLines.append(trimmedLine)
                }
            } else if
                !previousLineForcesBreak,
                !blocksIncomingSoftJoin,
                var last = resultLines.last,
                !last.isEmpty
            {
                if shouldJoinWithoutSpace(previousLine: last) {
                    last += trimmedLine
                } else {
                    last += " " + trimmedLine
                }
                resultLines[resultLines.count - 1] = last
            } else {
                resultLines.append(trimmedLine)
            }

            if isLineEndMarker {
                verticalWritingMode = false
            }
            previousLineForcesBreak = isLineEndMarker || blocksOutgoingSoftJoin
        }

        return resultLines.joined(separator: "\n")
    }

    private static func shouldKeepLineBreak(afterRawLine rawLine: String) -> Bool {
        guard let trailing = lastNonWhitespaceCharacter(in: rawLine) else { return false }
        return isLineEndMarkerCharacter(trailing)
    }

    private static func isLineEndMarkerCharacter(_ character: Character) -> Bool {
        switch character {
        case ".", "。", "!", "?", "！", "？",
             ")", "]", "}", "）", "］", "｝", "〉", "》", "」", "』", "】", "〙", "〗":
            return true
        default:
            return false
        }
    }

    private static func isBulletLikeLine(_ trimmedLine: String) -> Bool {
        let leadingTrimmed = trimmedLine.trimmingCharacters(in: .whitespaces)
        guard !leadingTrimmed.isEmpty else { return false }

        if let first = leadingTrimmed.first, ["・", "＊", "ー", "-"].contains(first) {
            return true
        }

        var index = leadingTrimmed.startIndex
        var digitCount = 0
        while index < leadingTrimmed.endIndex, leadingTrimmed[index].isNumber {
            digitCount += 1
            index = leadingTrimmed.index(after: index)
        }

        if digitCount > 0, index < leadingTrimmed.endIndex {
            let delimiter = leadingTrimmed[index]
            if delimiter == "." || delimiter == ":" || delimiter == ";" {
                return true
            }
        }
        return false
    }

    private static func isNumericDataOnlyLine(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.isEmpty else { return false }
        return trimmedLine.range(of: #"^[0-9/:\s]+$"#, options: .regularExpression) != nil
    }

    private static func shortHeadingDataThreshold(for lines: [String]) -> Int {
        let introMax = lines
            .prefix(30)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .max() ?? 0
        return introMax / 2
    }

    private static func isShortHeadingOrDataLine(_ trimmedLine: String, threshold: Int) -> Bool {
        guard threshold > 0 else { return false }
        return !trimmedLine.isEmpty && trimmedLine.count <= threshold
    }

    private static func consecutiveVerticalCandidateCount(from startIndex: Int, in allLines: [String]) -> Int {
        var index = startIndex
        var count = 0
        while index < allLines.count {
            let trimmed = allLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if isSingleCJKVerticalCandidate(trimmed) {
                count += 1
                index += 1
            } else {
                break
            }
        }
        return count
    }

    private static func isSingleCJKVerticalCandidate(_ line: String) -> Bool {
        guard line.count == 1, let first = line.first else { return false }
        return first.unicodeScalars.allSatisfy(isCJKExcludingHangul)
    }

    private static func shouldJoinWithoutSpace(previousLine: String) -> Bool {
        guard let trailing = lastNonWhitespaceCharacter(in: previousLine) else { return false }
        return trailing.unicodeScalars.allSatisfy(isCJKExcludingHangul)
    }

    private static func lastNonWhitespaceCharacter(in text: String) -> Character? {
        text.last(where: { !$0.isWhitespace })
    }

    private static func isCJKExcludingHangul(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value

        switch value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return false
        default:
            break
        }

        switch value {
        case 0x2E80...0x2EFF,
             0x3000...0x303F,
             0x3040...0x30FF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
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
                        primaryButton: .default(Text(NSLocalizedString(
                            "ui.alert.open_settings",
                            bundle: .main,
                            value: "Open Settings",
                            comment: ""
                        ))) {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString(
                            "ui.action.close",
                            bundle: .main,
                            value: "Close",
                            comment: ""
                        ))) {
                            viewModel.dismissUserAlert()
                        }
                    )
                }

                return Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text(NSLocalizedString(
                        "ui.action.ok",
                        bundle: .main,
                        value: "OK",
                        comment: ""
                    ))) {
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
