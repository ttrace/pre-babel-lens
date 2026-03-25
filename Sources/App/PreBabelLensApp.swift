import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct PreBabelLens: App {
    private let viewModel: TranslationViewModel
#if os(macOS)
    private let clipboardDoubleCopyDetector: ClipboardDoubleCopyDetector
#endif

    init() {
        let preprocess = DeterministicPreprocessEngine()
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
        TranslationView(viewModel: viewModel)
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
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
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
