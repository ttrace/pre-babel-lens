import SwiftUI
#if os(macOS)
import AppKit
#endif
#if canImport(Translation)
import Translation
#endif

@main
struct PreBabelLens: App {
    private let viewModel: TranslationViewModel
#if canImport(Translation)
    private let unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController
#endif
#if os(macOS)
    private let clipboardDoubleCopyDetector: ClipboardDoubleCopyDetector
#endif

    init() {
        #if os(iOS)
        print("[PBL][APP-SWIFTUI] PreBabelLens.init bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
        #endif
        let preprocess = DeterministicPreprocessEngine()
#if canImport(Translation)
        let unsafeRecoveryController = TranslationFrameworkUnsafeRecoveryController()
        let hybridEngine = FoundationModelsTranslationEngine(
            unsafeSegmentRecoveryEngine: unsafeRecoveryController
        )
        let translationFrameworkEngine = TranslationFrameworkPrimaryTranslationEngine(
            recoveryEngine: unsafeRecoveryController
        )
        self.unsafeRecoveryController = unsafeRecoveryController
        let policy = IOSAdaptiveTranslationEnginePolicy(
            translationFrameworkEngine: translationFrameworkEngine,
            hybridEngine: hybridEngine
        )
        let launchInputText = Self.launchInputText()

        self.viewModel = TranslationViewModel(
            orchestrator: TranslationOrchestrator(
                preprocessEngine: preprocess,
                enginePolicy: policy
            ),
            iOSEnginePolicy: policy,
            launchInputText: launchInputText
        )
#else
        let translationEngine = FoundationModelsTranslationEngine()
        let policy = FixedTranslationEnginePolicy(engine: translationEngine)
        let launchInputText = Self.launchInputText()

        self.viewModel = TranslationViewModel(
            orchestrator: TranslationOrchestrator(
                preprocessEngine: preprocess,
                enginePolicy: policy
            ),
            launchInputText: launchInputText
        )
#endif
#if os(macOS)
        let vm = self.viewModel
        self.clipboardDoubleCopyDetector = ClipboardDoubleCopyDetector { text in
            Task { @MainActor in
                Self.activateExistingWindow()
                await vm.handleDoubleCopyText(text)
            }
        }
        self.clipboardDoubleCopyDetector.start()
#endif
    }

    var body: some Scene {
        #if os(macOS)
        mainScene
            .commands {
                CommandGroup(replacing: .newItem) { }
                TranslationMenuCommands(viewModel: viewModel)
            }
        #else
        mainScene
        #endif
    }

    @SceneBuilder
    private var mainScene: some Scene {
#if os(macOS)
        // URLスキーム起動時でも既存ウインドウを再利用し、状態を維持する。
        Window("Pre-Babel Lens", id: "main-window") {
            translationRootView
        }
#else
        WindowGroup {
            translationRootView
        }
#endif
    }

    private var translationRootView: some View {
        Group {
#if canImport(Translation)
            TranslationView(
                viewModel: viewModel,
                unsafeRecoveryController: unsafeRecoveryController
            )
#else
            TranslationView(viewModel: viewModel)
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #if os(macOS)
        .background(WindowAppearanceConfigurator())
        #endif
        .onOpenURL { url in
            Task { @MainActor in
                await viewModel.handleIncomingURL(url)
                #if os(macOS)
                Self.activateExistingWindow()
                #endif
            }
        }
    }

    private static func launchInputText() -> String? {
        let args = Array(ProcessInfo.processInfo.arguments.dropFirst())
        guard !args.isEmpty else { return nil }

        let combined = args.joined(separator: " ")
        let trimmed = combined.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

#if os(macOS)
    @MainActor
    private static func activateExistingWindow() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)

        for window in NSApp.windows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
        }

        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
        }
    }
#endif
}

#if os(macOS)
private struct TranslationMenuCommands: Commands {
    @ObservedObject var viewModel: TranslationViewModel
    @AppStorage("editorFontScaleLevel") private var editorFontScaleLevel: Int = 2

    var body: some Commands {
        CommandMenu(topMenuTitle) {
            Button(translateTitle) {
                Task { await viewModel.translate() }
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(viewModel.isTranslating || viewModel.targetLanguageOptions.isEmpty)

            Button(stopTitle) {
                viewModel.stopTranslation()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!viewModel.isTranslating)

            Divider()

            Button(increaseTextSizeTitle) {
                editorFontScaleLevel = min(4, editorFontScaleLevel + 1)
            }
            .keyboardShortcut("=", modifiers: [.command])

            Button(decreaseTextSizeTitle) {
                editorFontScaleLevel = max(0, editorFontScaleLevel - 1)
            }
            .keyboardShortcut("-", modifiers: [.command])

            Button(resetTextSizeTitle) {
                editorFontScaleLevel = 2
            }
            .keyboardShortcut("0", modifiers: [.command])

            Divider()

            Menu(targetLanguageMenuTitle) {
                if viewModel.isAppleIntelligenceAvailable {
                    Button(
                        viewModel.usesAppleIntelligenceTranslation
                            ? switchToStandardTitle
                            : switchToAITitle
                    ) {
                        if viewModel.usesAppleIntelligenceTranslation {
                            viewModel.switchToStandardTranslation()
                        } else {
                            viewModel.switchToAppleIntelligenceTranslation()
                        }
                    }
                } else {
                    Button(aiUnavailableTitle) { }
                        .disabled(true)
                }

                Divider()

                ForEach(viewModel.targetLanguageOptions) { option in
                    Button {
                        viewModel.targetLanguage = option.code
                    } label: {
                        if option.code == viewModel.targetLanguage {
                            Label(option.menuLabel(showCode: false, style: currentLabelStyle), systemImage: "checkmark")
                        } else {
                            Text(option.menuLabel(showCode: false, style: currentLabelStyle))
                        }
                    }
                }
            }
        }
    }

    private var topMenuTitle: String {
        isJapaneseLocale ? "翻訳" : "Translate"
    }

    private var translateTitle: String {
        isJapaneseLocale ? "翻訳" : "Translate"
    }

    private var stopTitle: String {
        isJapaneseLocale ? "中断" : "Stop"
    }

    private var targetLanguageMenuTitle: String {
        isJapaneseLocale ? "翻訳先言語" : "Target Language"
    }

    private var switchToAITitle: String {
        isJapaneseLocale ? "AI翻訳に切り替え" : "Switch to AI Translation"
    }

    private var switchToStandardTitle: String {
        isJapaneseLocale ? "機械翻訳に切り替え" : "Switch to Standard Translation"
    }

    private var aiUnavailableTitle: String {
        isJapaneseLocale ? "AI翻訳はこのデバイスで利用できません" : "AI translation unavailable on this device"
    }

    private var increaseTextSizeTitle: String {
        isJapaneseLocale ? "文字サイズを大きく" : "Increase Text Size"
    }

    private var decreaseTextSizeTitle: String {
        isJapaneseLocale ? "文字サイズを小さく" : "Decrease Text Size"
    }

    private var resetTextSizeTitle: String {
        isJapaneseLocale ? "文字サイズを標準に戻す" : "Reset Text Size"
    }

    private var isJapaneseLocale: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }

    private var currentLabelStyle: TargetLanguageOption.LabelStyle {
        viewModel.usesAppleIntelligenceTranslation ? .ai : .machine
    }
}

private struct WindowAppearanceConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            configure(window: window)
        }
    }

    private func configure(window: NSWindow) {
        window.isRestorable = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor(
            red: 0.98,
            green: 0.92,
            blue: 0.82,
            alpha: 1.0
        )
    }
}
#endif
