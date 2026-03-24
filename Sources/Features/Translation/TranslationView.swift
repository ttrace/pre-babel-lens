import SwiftUI

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

struct TranslationView: View {
    // #region MARK: MARK:State
    @StateObject private var viewModel: TranslationViewModel
    @AppStorage("developerModeEnabled") private var developerModeEnabled: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    // #endregion

    // #region MARK: Init
    init(viewModel: TranslationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    // #endregion

    // #region MARK: Body
    var body: some View {
        GeometryReader { proxy in
            contentLayout
                .foregroundStyle(colorScheme == .dark ? .white : .primary)
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .background(
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
                )
                #if os(iOS)
                .overlay(alignment: .bottomTrailing) {
                    #if DEBUG
                    Text(debugFrameText(proxySize: proxy.size))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.4), in: Capsule())
                        .padding(8)
                    #endif
                }
                #endif
        }
        .ignoresSafeArea()
        #if os(macOS)
        .frame(minHeight: 680)
        #endif
        .task {
            #if os(macOS)
                if viewModel.consumeLaunchActivationRequest() {
                    NSApp.activate(ignoringOtherApps: true)
                }
            #endif
            await viewModel.translateIfNeededOnLaunch()
        }
    }
    // #endregion

    // #region MARK: Layout
    @ViewBuilder
    private var contentLayout: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Spacer()
                settingsMenu(iconSize: 17, frameSize: 34)
            }
            .padding(.top, 2)

            languagePicker

            if isWideIOSLayout {
                HStack(alignment: .top, spacing: 14) {
                    sourceCard
                    outputCard
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    sourceCard
                    outputCard
                }
            }

            if developerModeEnabled {
                developerPanels
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    private func settingsMenu(iconSize: CGFloat, frameSize: CGFloat) -> some View {
        Menu {
            Toggle("Developer Mode", isOn: $developerModeEnabled)
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
                .frame(minHeight: editorMinHeight)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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

            ScrollView {
                Group {
                    if viewModel.translatedText.isEmpty {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: 1, alignment: .leading)
                    } else {
                        Text(viewModel.translatedText)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(minHeight: editorMinHeight)
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

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 10) {
                    Text(viewModel.statusText)
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.20, green: 0.35, blue: 0.30))
                    Spacer()
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
        .padding(cardOuterPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        #if os(iOS)
        .background(Color.clear)
        #else
        .background(
            colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
            in: RoundedRectangle(cornerRadius: cardCornerRadius)
        )
        #endif
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

    #if os(iOS)
    private func debugFrameText(proxySize: CGSize) -> String {
        #if DEBUG
        let screen = UIScreen.main.bounds.size
        let idiom = UIDevice.current.userInterfaceIdiom == .phone ? "phone" : "pad"
        let hClass = horizontalSizeClass == .regular ? "regular" : "compact"
        return String(
            format: "SWIFTUI-IOS %.0fx%.0f / screen %.0fx%.0f / %@ %@",
            proxySize.width,
            proxySize.height,
            screen.width,
            screen.height,
            idiom,
            hClass
        )
        #else
        return ""
        #endif
    }
    #endif

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
}
