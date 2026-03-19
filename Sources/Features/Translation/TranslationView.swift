import SwiftUI

#if os(macOS)
    import AppKit
#endif

struct TranslationView: View {
    // #region MARK: MARK:State
    @StateObject private var viewModel: TranslationViewModel
    @AppStorage("developerModeEnabled") private var developerModeEnabled: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    // #endregion

    // #region MARK: Init
    init(viewModel: TranslationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }
    // #endregion

    // #region MARK: Body
    var body: some View {
        ZStack {
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

            VStack(alignment: .leading, spacing: 18) {
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
                    Menu {
                        Toggle("Developer Mode", isOn: $developerModeEnabled)
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Color(red: 0.35, green: 0.42, blue: 0.34))
                            .frame(width: 64, height: 64)
                            .background(.white.opacity(0.85), in: Circle())
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(.top, 8)

                HStack(alignment: .top, spacing: 18) {
                    sourceCard
                    outputCard
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if developerModeEnabled {
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

                    HStack(alignment: .top, spacing: 12) {
                        GroupBox("Deterministic Analysis") {
                            ScrollView {
                                Text(deterministicAnalysisText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 140)
                        }

                        GroupBox("Heuristic Analysis") {
                            ScrollView {
                                Text(heuristicAnalysisText)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 140)
                        }
                    }

                    GroupBox("Console") {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(viewModel.developerLogs.enumerated()), id: \.offset) { _, line in
                                    Text(line)
                                        .font(.system(size: 12, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(minHeight: 120, maxHeight: 220)
                    }
                }
            }
            .padding(36)
            .foregroundStyle(colorScheme == .dark ? .white : .primary)
        }
        .frame(minWidth: 1000, minHeight: 680)
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
                .frame(minHeight: 300)
                .padding(8)
                .font(.body)
                .background(
                    colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 18)
                )
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 26)
        )
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
            .frame(minHeight: 300)
            .background(
                colorScheme == .dark ? Color.black.opacity(0.3) : Color.white.opacity(0.4),
                in: RoundedRectangle(cornerRadius: 18)
            )

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.body)
                    .foregroundStyle(.red)
            } else {
                Text(viewModel.statusText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(red: 0.20, green: 0.35, blue: 0.30))
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            colorScheme == .dark ? Color.black.opacity(0.5) : Color.white.opacity(0.7),
            in: RoundedRectangle(cornerRadius: 26)
        )
    }
    // #endregion

    // #region MARK: Derived Text
    private var deterministicAnalysisText: String {
        [
            "Engine: \(viewModel.engineName.isEmpty ? "(none)" : viewModel.engineName)",
            "Mode: \(viewModel.experimentMode.displayName)",
            "Detected language (deterministic): \(deterministicDetectedLanguageCode)",
            "Processing time: \(processingTimeText(in: deterministicTraces, preferredStep: "deterministic-processing-time"))",
            "Protected tokens: \(viewModel.protectedTokens.count)",
            "Glossary matches: \(viewModel.glossaryMatches.count)",
            "Ambiguity hints: \(viewModel.ambiguityHints.count)",
            "Trace steps: \(deterministicTraces.count)",
            "Trace details:",
            traceText(for: deterministicTraces),
        ].joined(separator: "\n")
    }

    private var heuristicAnalysisText: String {
        [
            "Processing time: \(processingTimeText(in: heuristicTraces, preferredStep: "ai-heuristic-processing-time"))",
            "Detected language (final): \(viewModel.detectedLanguageCode.isEmpty ? "(none)" : viewModel.detectedLanguageCode)",
            "AI language support: \(viewModel.aiLanguageSupported ? "yes" : "no")",
            "Heuristic trace steps: \(heuristicTraces.count)",
            "Trace details:",
            traceText(for: heuristicTraces),
        ].joined(separator: "\n")
    }

    private var deterministicTraces: [PreprocessTrace] {
        viewModel.traces.filter { !isHeuristicTrace($0) }
    }

    private var heuristicTraces: [PreprocessTrace] {
        viewModel.traces.filter { isHeuristicTrace($0) }
    }

    private func isHeuristicTrace(_ trace: PreprocessTrace) -> Bool {
        let step = trace.step.lowercased()
        let summary = trace.summary.lowercased()
        return step.contains("ai")
            || step.contains("heuristic")
            || summary.contains("heuristic")
            || summary.contains("fm-")
    }

    private func traceText(for traces: [PreprocessTrace]) -> String {
        guard !traces.isEmpty else { return "(none)" }
        return traces.map { "\($0.step): \($0.summary)" }.joined(separator: "\n")
    }

    private var deterministicDetectedLanguageCode: String {
        guard let trace = deterministicTraces.first(where: { $0.step == "language-detection" }) else {
            return "(none)"
        }

        let summary = trace.summary
        guard let start = summary.range(of: "detected=")?.upperBound else {
            return "(none)"
        }
        let rest = summary[start...]
        let code = rest.split(separator: ",").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return code.isEmpty ? "(none)" : code
    }

    private func processingTimeText(in traces: [PreprocessTrace], preferredStep: String) -> String {
        traces.first(where: { $0.step == preferredStep })?.summary ?? "(n/a)"
    }
    // #endregion

    // #region MARK: Clipboard Actions
    private func copyOutputToClipboard() {
        #if os(macOS)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(viewModel.translatedText, forType: .string)
        #endif
    }

    private func pasteInputFromClipboard() {
        #if os(macOS)
            let pasteboard = NSPasteboard.general
            if let text = pasteboard.string(forType: .string), !text.isEmpty {
                viewModel.inputText = text
            }
        #endif
    }
    // #endregion
}
