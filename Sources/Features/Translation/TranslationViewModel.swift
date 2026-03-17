import Foundation

@MainActor
final class TranslationViewModel: ObservableObject {
    @Published var targetLanguage: String
    @Published var experimentMode: TranslationExperimentMode = .segmentedGlossaryProtected
    @Published var inputText: String = ""
    @Published var glossaryText: String = ""

    @Published var translatedText: String = ""
    @Published var traces: [PreprocessTrace] = []
    @Published var protectedTokens: [ProtectedToken] = []
    @Published var glossaryMatches: [GlossaryMatch] = []
    @Published var ambiguityHints: [AmbiguityHint] = []
    @Published var engineName: String = ""
    @Published var detectedLanguageCode: String = ""
    @Published var aiLanguageSupported: Bool = true
    @Published var isTranslating: Bool = false
    @Published var errorMessage: String?

    let targetLanguageOptions: [TargetLanguageOption]
    private let orchestrator: TranslationOrchestrator

    init(orchestrator: TranslationOrchestrator) {
        let options = AppleIntelligenceLanguageCatalog.supportedLanguageOptions()
        self.targetLanguageOptions = options
        if options.contains(where: { $0.code == "ja" }) {
            self.targetLanguage = "ja"
        } else {
            self.targetLanguage = options.first?.code ?? "en"
        }
        self.orchestrator = orchestrator
    }

    func translate() async {
        let request = TranslationRequest(
            sourceLanguage: "und",
            targetLanguage: targetLanguage,
            text: inputText,
            glossary: parseGlossary(glossaryText),
            experimentMode: experimentMode
        )

        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            translatedText = ""
            traces = []
            protectedTokens = []
            glossaryMatches = []
            ambiguityHints = []
            engineName = ""
            detectedLanguageCode = ""
            aiLanguageSupported = true
            errorMessage = nil
            return
        }

        isTranslating = true
        defer { isTranslating = false }

        do {
            let output = try await orchestrator.translate(request)
            translatedText = output.translatedText
            traces = output.analysis.traces
            protectedTokens = output.analysis.input.protectedTokens
            glossaryMatches = output.analysis.input.glossaryMatches
            ambiguityHints = output.analysis.input.ambiguityHints
            engineName = output.analysis.engineName
            detectedLanguageCode = output.analysis.input.detectedLanguageCode ?? ""
            aiLanguageSupported = output.analysis.input.isDetectedLanguageSupportedByAppleIntelligence
            errorMessage = nil
        } catch let pipelineError as TranslationPipelineError {
            if let detected = pipelineError.detectedLanguageCode {
                detectedLanguageCode = detected
                aiLanguageSupported = false
            }
            errorMessage = pipelineError.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
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
}
