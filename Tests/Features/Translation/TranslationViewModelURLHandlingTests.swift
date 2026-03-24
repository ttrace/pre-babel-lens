import Foundation
import Testing
@testable import PreBabelLens

struct TranslationViewModelURLHandlingTests {
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

    @MainActor
    private func makeViewModel(counter: TranslationCallCounter) -> TranslationViewModel {
        let engine = CountingTranslationEngine(counter: counter)
        let policy = FixedTranslationEnginePolicy(engine: engine)
        let orchestrator = TranslationOrchestrator(
            preprocessEngine: DeterministicPreprocessEngine(),
            enginePolicy: policy
        )

        return TranslationViewModel(orchestrator: orchestrator)
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
