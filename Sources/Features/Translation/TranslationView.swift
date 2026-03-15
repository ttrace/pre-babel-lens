import SwiftUI

struct TranslationView: View {
    @StateObject private var viewModel: TranslationViewModel

    init(viewModel: TranslationViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                TextField("Source (e.g. en)", text: $viewModel.sourceLanguage)
                TextField("Target (e.g. ja)", text: $viewModel.targetLanguage)
                Button("Translate") {
                    Task { await viewModel.translate() }
                }
                .disabled(viewModel.isTranslating)
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80)
            }

            GroupBox("Analysis") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine: \(viewModel.engineName.isEmpty ? "(none)" : viewModel.engineName)")
                    Text("Protected tokens: \(viewModel.protectedTokens.count)")
                    Text("Glossary matches: \(viewModel.glossaryMatches.count)")
                    Text("Ambiguity hints: \(viewModel.ambiguityHints.count)")
                    Text("Trace steps: \(viewModel.traces.count)")
                }
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
}
