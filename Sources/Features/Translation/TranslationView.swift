import SwiftUI
#if os(macOS)
import AppKit
#endif

struct TranslationView: View {
    @StateObject private var viewModel: TranslationViewModel

    init(viewModel: TranslationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Spacer()
                Button {
                    copyOutputToClipboard()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy output")
                .disabled(viewModel.translatedText.isEmpty)
            }

            HStack(spacing: 12) {
                if viewModel.targetLanguageOptions.isEmpty {
                    Text("No Apple Intelligence target languages available")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Target", selection: $viewModel.targetLanguage) {
                        ForEach(viewModel.targetLanguageOptions) { option in
                            Text(option.displayLabel).tag(option.code)
                        }
                    }
                    .pickerStyle(.menu)
                }
                Button("Translate") {
                    Task { await viewModel.translate() }
                }
                .disabled(viewModel.isTranslating || viewModel.targetLanguageOptions.isEmpty)
            }

            HStack(spacing: 12) {
                Text("Experiment")
                Picker("Experiment", selection: $viewModel.experimentMode) {
                    ForEach(TranslationExperimentMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                Spacer()
            }

            GroupBox("Input") {
                TextEditor(text: $viewModel.inputText)
                    .frame(minHeight: 120)
            }

            GroupBox("Glossary (source=target)") {
                TextEditor(text: $viewModel.glossaryText)
                    .frame(minHeight: 60)
            }

            GroupBox("Output") {
                ScrollView {
                    Text(viewModel.translatedText.isEmpty ? "(empty)" : viewModel.translatedText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80)
            }

            GroupBox("Analysis") {
                Text(
                    [
                        "Engine: \(viewModel.engineName.isEmpty ? "(none)" : viewModel.engineName)",
                        "Mode: \(viewModel.experimentMode.displayName)",
                        "Detected language: \(viewModel.detectedLanguageCode.isEmpty ? "(none)" : viewModel.detectedLanguageCode)",
                        "AI language support: \(viewModel.aiLanguageSupported ? "yes" : "no")",
                        "Protected tokens: \(viewModel.protectedTokens.count)",
                        "Glossary matches: \(viewModel.glossaryMatches.count)",
                        "Ambiguity hints: \(viewModel.ambiguityHints.count)",
                        "Trace steps: \(viewModel.traces.count)"
                    ].joined(separator: "\n")
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(minWidth: 760, minHeight: 560)
    }

    private func copyOutputToClipboard() {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(viewModel.translatedText, forType: .string)
#endif
    }
}
