import Foundation
import Testing
@testable import PreBabelLens

struct TranslationViewModelURLHandlingTests {
    @Test
    func translateShowsUserAlertForTranslationServiceConnectionFailure() async throws {
        let counter = TranslationCallCounter()
        let connectionError = NSError(
            domain: NSCocoaErrorDomain,
            code: 4097,
            userInfo: [NSDebugDescriptionErrorKey: "connection to service named com.apple.translation.text"]
        )
        let viewModel = await makeViewModel(
            counter: counter,
            engine: ThrowingTranslationEngine(error: connectionError)
        )
        await MainActor.run {
            viewModel.inputText = "Hello"
        }

        await viewModel.translate()

        await MainActor.run {
            #expect(viewModel.userAlert != nil)
            #expect(viewModel.userAlert?.offersSettingsShortcut == true)
            #expect(!(viewModel.errorMessage ?? "").isEmpty)
        }
    }

    @Test
    func translateShowsUserAlertForAvailableLocalePairsServiceFailureMessage() async throws {
        let counter = TranslationCallCounter()
        let connectionError = NSError(
            domain: NSCocoaErrorDomain,
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Failed to complete availableLocalePairsForTask, using dedicated mach port",
                NSDebugDescriptionErrorKey: "connection to service named com.apple.translation.text",
            ]
        )
        let viewModel = await makeViewModel(
            counter: counter,
            engine: ThrowingTranslationEngine(error: connectionError)
        )
        await MainActor.run {
            viewModel.inputText = "Hello"
        }

        await viewModel.translate()

        await MainActor.run {
            #expect(viewModel.userAlert != nil)
            #expect(viewModel.userAlert?.offersSettingsShortcut == true)
            #expect(!(viewModel.errorMessage ?? "").isEmpty)
        }
    }

    @Test
    @MainActor
    func experimentModePersistsAcrossViewModelInstances() throws {
        let suiteName = "TranslationViewModelURLHandlingTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let counter = TranslationCallCounter()
        let firstViewModel = makeViewModel(counter: counter, userDefaults: defaults)
        firstViewModel.experimentMode = .rawInput

        let secondViewModel = makeViewModel(counter: counter, userDefaults: defaults)
        #expect(secondViewModel.experimentMode == .rawInput)
    }

    @Test
    @MainActor
    func experimentModeFallsBackToSegmentedWhenPersistedValueIsInvalid() throws {
        let suiteName = "TranslationViewModelURLHandlingTests.\(#function)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("invalid-mode", forKey: "appState.experimentMode")

        let counter = TranslationCallCounter()
        let viewModel = makeViewModel(counter: counter, userDefaults: defaults)
        #expect(viewModel.experimentMode == .segmented)
    }

    @Test
    @MainActor
    func initialTargetLanguageUsesPreferredLanguageWhenSupported() {
        let counter = TranslationCallCounter()
        let viewModel = makeViewModel(counter: counter, preferredLanguages: ["fr-FR"])
        #expect(viewModel.targetLanguage.lowercased().hasPrefix("fr"))
    }

    @Test
    @MainActor
    func initialTargetLanguageFallsBackToEnglishWhenPreferredUnsupported() {
        let counter = TranslationCallCounter()
        let viewModel = makeViewModel(counter: counter, preferredLanguages: ["tlh-KX", "zz-ZZ"])
        #expect(viewModel.targetLanguage.lowercased().hasPrefix("en"))
    }

    @Test
    @MainActor
    func initialTargetLanguagePrefersTraditionalChineseWhenRegionImpliesHant() {
        let counter = TranslationCallCounter()
        let viewModel = makeViewModel(counter: counter, preferredLanguages: ["zh-TW"])
        #expect(viewModel.targetLanguage.lowercased() == "zh-hant")
    }

    @Test
    func handleIncomingURLUpdatesInputAndTranslates() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "prebabellens://translate?text=Hello%20from%20URL"))

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText == "Hello from URL")
            #expect(viewModel.translatedText.contains("Hello from URL"))
        }
        #expect(await counter.current() == 1)
    }

    @Test
    func handleIncomingURLSkipsDuplicateText() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "prebabellens://translate?text=Same%20text"))

        await viewModel.handleIncomingURL(url)
        let firstOutput = await MainActor.run { viewModel.translatedText }

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.translatedText == firstOutput)
        }
        #expect(await counter.current() == 1)
    }

    @Test
    func handleIncomingURLAllowsSameTextWhenExperimentModeChanged() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "prebabellens://translate?text=Same%20text"))

        await viewModel.handleIncomingURL(url)
        await MainActor.run {
            viewModel.experimentMode = .segmentedGlossary
        }
        await viewModel.handleIncomingURL(url)

        #expect(await counter.current() == 2)
    }

    @Test
    func handleIncomingURLIgnoresDifferentScheme() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "https://example.com/?text=Hello"))

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText.isEmpty)
            #expect(viewModel.translatedText.isEmpty)
        }
        #expect(await counter.current() == 0)
    }

    @Test
    func handleIncomingURLAcceptsSchemeCaseInsensitive() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "PreBabelLens://translate?text=Hello"))

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText == "Hello")
            #expect(viewModel.translatedText.contains("Hello"))
        }
        #expect(await counter.current() == 1)
    }

    @Test
    func handleIncomingURLUsesPathWhenTextQueryMissing() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "prebabellens://translate/Hello%20from%20path"))

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText == "Hello from path")
            #expect(viewModel.translatedText.contains("Hello from path"))
        }
        #expect(await counter.current() == 1)
    }

    @Test
    func handleIncomingURLPrefersTextQueryOverPath() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(
            URL(string: "prebabellens://translate/Path%20text?text=Query%20text")
        )

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText == "Query text")
            #expect(viewModel.translatedText.contains("Query text"))
        }
        #expect(await counter.current() == 1)
    }

    @Test
    func handleIncomingURLSkipsWhenTextQueryIsBlank() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "prebabellens://translate?text=%20%20%20"))

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText.isEmpty)
            #expect(viewModel.translatedText.isEmpty)
        }
        #expect(await counter.current() == 0)
    }

    @Test
    func handleIncomingURLNormalizesCRLFLineEndings() async throws {
        let counter = TranslationCallCounter()
        let viewModel = await makeViewModel(counter: counter)
        let url = try #require(URL(string: "prebabellens://translate?text=Line1%0D%0ALine2%0DLine3"))

        await viewModel.handleIncomingURL(url)

        await MainActor.run {
            #expect(viewModel.inputText == "Line1\nLine2\nLine3")
            #expect(viewModel.translatedText.contains("Line1\nLine2\nLine3"))
        }
        #expect(await counter.current() == 1)
    }

    @Test
    @MainActor
    func refreshLanguageMenuSourceLanguageSwitchesTargetToPreviousSourceWhenDetectedEqualsTarget() {
        let counter = TranslationCallCounter()
        let viewModel = makeViewModel(counter: counter)

        viewModel.targetLanguage = "ja"
        viewModel.handleSourceTextPasted("Hello world")
        #expect(viewModel.detectedLanguageCode == "en")
        #expect(viewModel.targetLanguage == "ja")

        viewModel.handleSourceTextPasted("こんにちは、世界")

        #expect(viewModel.detectedLanguageCode == "ja")
        #expect(viewModel.targetLanguage == "en")
    }

    @MainActor
    private func makeViewModel(
        counter: TranslationCallCounter,
        userDefaults: UserDefaults? = nil,
        engine: (any TranslationEngine)? = nil,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> TranslationViewModel {
        let resolvedUserDefaults = userDefaults ?? Self.makeIsolatedUserDefaults()
        let selectedEngine = engine ?? CountingTranslationEngine(counter: counter)
        let policy = FixedTranslationEnginePolicy(engine: selectedEngine)
        let orchestrator = TranslationOrchestrator(
            preprocessEngine: DeterministicPreprocessEngine(),
            enginePolicy: policy
        )

        return TranslationViewModel(
            orchestrator: orchestrator,
            userDefaults: resolvedUserDefaults,
            preferredLanguages: preferredLanguages
        )
    }

    @MainActor
    private static func makeIsolatedUserDefaults() -> UserDefaults {
        let suiteName = "TranslationViewModelURLHandlingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private actor TranslationCallCounter {
    private var count: Int = 0

    func increment() -> Int {
        count += 1
        return count
    }

    func current() -> Int {
        count
    }
}

private struct CountingTranslationEngine: TranslationEngine {
    let name: String = "counting-test-engine"
    let counter: TranslationCallCounter

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        let callIndex = await counter.increment()
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText)]
            : input.segments

        return segments.map { segment in
            SegmentOutput(
                segmentIndex: segment.index,
                sourceText: segment.text,
                translatedText: "[call:\(callIndex)] \(segment.text)"
            )
        }
    }
}

private struct ThrowingTranslationEngine: TranslationEngine {
    let name: String = "throwing-test-engine"
    let error: NSError

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        throw error
    }
}
