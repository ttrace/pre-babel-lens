import Foundation
import NaturalLanguage

struct FoundationModelsTranslationEngine: DiagnosticCapableTranslationEngine {
    private let unsafeSegmentRecoveryEngine: UnsafeSegmentRecoveryEngine

    init(unsafeSegmentRecoveryEngine: UnsafeSegmentRecoveryEngine = NoOpUnsafeSegmentRecoveryEngine()) {
        self.unsafeSegmentRecoveryEngine = unsafeSegmentRecoveryEngine
    }

    var name: String {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return "foundation-models"
        }
        return "foundation-models-unavailable(os)"
#else
        return "foundation-models-unavailable(toolchain)"
#endif
    }

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(
                input,
                unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine
            )
        }
        throw FoundationModelsIntegrationError.unsupportedOperatingSystem
#else
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
#endif
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(
                input,
                unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                onPartialResult: onPartialResult
            )
        }
        throw FoundationModelsIntegrationError.unsupportedOperatingSystem
#else
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
#endif
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> [SegmentOutput] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            return try await FoundationModelsRuntimeTranslator.translate(
                input,
                unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent
            )
        }
        throw FoundationModelsIntegrationError.unsupportedOperatingSystem
#else
        throw FoundationModelsIntegrationError.missingFoundationModelsToolchain
#endif
    }
}

private enum FoundationModelsIntegrationError: LocalizedError {
    case missingFoundationModelsToolchain
    case unsupportedOperatingSystem

    var errorDescription: String? {
        switch self {
        case .missingFoundationModelsToolchain:
            return "Foundation Models is unavailable in the current build toolchain. Build with Xcode toolchain and retry."
        case .unsupportedOperatingSystem:
            return "Foundation Models requires macOS 26.0+ / iOS 26.0+. Please run this app on a supported OS version."
        }
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(macOS 26.0, iOS 26.0, *)
private actor FoundationModelsTranslationGate {
    private struct Waiter {
        var id: UUID
        var continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func withLock<T>(_ operation: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        if !isLocked {
            isLocked = true
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            return
        }

        let next = waiters.removeFirst().continuation
        next.resume(returning: ())
    }

    private func cancelWaiter(id: UUID) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: idx)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeTranslator {
    private static let lineBreakMarker = "</br>"
    private static let translationGate = FoundationModelsTranslationGate()
    private static let maxSegmentsPerSession = 6
    private static let maxEstimatedContextCostPerSession = 12_000
    private static let largePromptCharsThreshold = 2_200
    private static let segmentWordTimeoutSafetyFactor = 1.5
    private static let minimumSegmentTimeoutMs = 3_000.0
    private static let streamChunkStallTimeoutMs = 5_000.0
    private static let repetitionGuardMinChunkCount = 10
    private static let repetitionGuardOutputWordMultiplier = 3
    private static let semanticRepetitionLookbackChunks = 3
    private static let semanticRepetitionMinSignatureLength = 12
    private static let nonWordExplosionLookbackChunks = 3
    private static let nonWordExplosionMinAddedChars = 24
    private static let monoCharExplosionLookbackChunks = 2
    private static let monoCharExplosionMinAddedChars = 24

    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct StructuredTranslationPayload {
        @Guide(description: "Target language code.")
        var targetLanguage: String
        @Guide(description: "Translated HTML-like text only in the language specified by `targetLanguage`. Keep the same sentence count as the source text. STYLE REQUIREMENT: Preserve all `</br>` tokens exactly as in source (same count, same position even on the line head).")
        var translation: String
    }

    private struct StructuredTranslationResult: Sendable {
        var translation: String
        var outputBreakTagCount: Int
    }

    static func translate(
        _ input: TranslationInput,
        unsafeSegmentRecoveryEngine: UnsafeSegmentRecoveryEngine,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)? = nil,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)? = nil
    ) async throws -> [SegmentOutput] {
        try await translationGate.withLock {
            try ensureModelAvailability()
            onDiagnosticEvent?("session-model: usecase=general, guardrails=permissive-content-transformations")

            let segments = input.segments.isEmpty
                ? [TextSegment(index: 0, text: input.originalText, role: .leading)]
                : input.segments

            // Reuse one session per translation request to reduce per-segment setup overhead.
            var session = makeTranslationSession(for: input)
            var sessionSegmentCount = 0
            var sessionEstimatedContextCost = 0
            var firstSegmentMsPerWord: Double?

            var outputs: [SegmentOutput] = []
            outputs.reserveCapacity(segments.count)

            for segment in segments {
                try Task.checkCancellation()
                let segmentStartedAt = Date()
                let shouldStreamPartialForSegment = (onPartialResult != nil)
                let prompt = promptForSegment(segment, input: input)
                let nextPromptChars = prompt.count
                if shouldRefreshSessionProactively(
                    usedSegmentCount: sessionSegmentCount,
                    usedEstimatedContextCost: sessionEstimatedContextCost,
                    nextPromptChars: nextPromptChars
                ) {
                    session = makeTranslationSession(for: input)
                    sessionSegmentCount = 0
                    sessionEstimatedContextCost = 0
                    onDiagnosticEvent?("segment=\(segment.index): proactive-session-refresh-before-context-window-limit")
                }
                var finalResult: StructuredTranslationResult
                var isUnsafeFallback = false
                var isUnsafeRecoveredByTranslationFramework = false
                var shouldSkipSentenceDropRetry = false
                var didResetSessionForNextSegment = false
                let segmentTimeoutBudgetMs = timeoutBudgetMs(
                    forSegmentIndex: segment.index,
                    firstSegmentMsPerWord: firstSegmentMsPerWord,
                    segmentText: segment.text
                )

                do {
                    finalResult = try await translateStructuredSegmentWithOptionalTimeout(
                        prompt: prompt,
                        sourceText: segment.text,
                        expectedTargetLanguage: input.targetLanguage,
                        preprocessKind: segment.kind,
                        shouldStreamPartial: shouldStreamPartialForSegment,
                        using: session,
                        segmentIndex: segment.index,
                        onPartialResult: onPartialResult,
                        onDiagnosticEvent: onDiagnosticEvent,
                        timeoutBudgetMs: segmentTimeoutBudgetMs
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if isUnsafeContentError(error) {
                        isUnsafeFallback = true
                        shouldSkipSentenceDropRetry = true
                        onDiagnosticEvent?("segment=\(segment.index): unsafe-no-retry-source-returned (\(error.localizedDescription))")
                        let unsafeRecovery = await recoverUnsafeTranslationIfPossible(
                            sourceText: segment.text,
                            input: input,
                            segmentIndex: segment.index,
                            preprocessKind: segment.kind,
                            unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                            onDiagnosticEvent: onDiagnosticEvent
                        )
                        isUnsafeRecoveredByTranslationFramework = unsafeRecovery.usedTranslationFrameworkRecovery
                        finalResult = StructuredTranslationResult(
                            translation: unsafeRecovery.translation,
                            outputBreakTagCount: 0
                        )
                        session = makeTranslationSession(for: input)
                        sessionSegmentCount = 0
                        sessionEstimatedContextCost = 0
                            didResetSessionForNextSegment = true
                            onDiagnosticEvent?("segment=\(segment.index): session-reset-after-unsafe-fallback")
                    } else if let mismatch = structuredTargetMismatchDetails(error) {
                        onDiagnosticEvent?(
                            "segment=\(segment.index): structured-target-mismatch expected=\(mismatch.expected), actual=\(mismatch.actual)"
                        )
                        onDiagnosticEvent?(
                            "segment=\(segment.index): structured-target-mismatch-fallback-via-translation-framework"
                        )
                        isUnsafeFallback = true
                        shouldSkipSentenceDropRetry = true
                        let unsafeRecovery = await recoverUnsafeTranslationIfPossible(
                            sourceText: segment.text,
                            input: input,
                            segmentIndex: segment.index,
                            preprocessKind: segment.kind,
                            unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                            onDiagnosticEvent: onDiagnosticEvent
                        )
                        isUnsafeRecoveredByTranslationFramework = unsafeRecovery.usedTranslationFrameworkRecovery
                        finalResult = StructuredTranslationResult(
                            translation: unsafeRecovery.translation,
                            outputBreakTagCount: 0
                        )
                        session = await resetSessionForNextSegment(
                            input: input,
                            segmentIndex: segment.index,
                            prewarmForTranslationFrameworkFallback: isUnsafeRecoveredByTranslationFramework,
                            onDiagnosticEvent: onDiagnosticEvent
                        )
                        sessionSegmentCount = 0
                        sessionEstimatedContextCost = 0
                        didResetSessionForNextSegment = true
                        onDiagnosticEvent?("segment=\(segment.index): session-reset-after-structured-target-mismatch-fallback")
                    } else if isContextWindowExceededError(error) {
                        if let repetition = repetitionGuardDetails(error) {
                            onDiagnosticEvent?(
                                "segment=\(segment.index): repetition-guard-triggered mode=\(repetition.mode), chunks=\(repetition.chunks), source-words=\(repetition.sourceWords), output-words=\(repetition.outputWords)"
                            )
                            onDiagnosticEvent?(
                                "segment=\(segment.index): repetition-fallback-via-translation-framework"
                            )
                            isUnsafeFallback = true
                            shouldSkipSentenceDropRetry = true
                            let unsafeRecovery = await recoverUnsafeTranslationIfPossible(
                                sourceText: segment.text,
                                input: input,
                                segmentIndex: segment.index,
                                preprocessKind: segment.kind,
                                unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                                onDiagnosticEvent: onDiagnosticEvent
                            )
                            isUnsafeRecoveredByTranslationFramework = unsafeRecovery.usedTranslationFrameworkRecovery
                            finalResult = StructuredTranslationResult(
                                translation: unsafeRecovery.translation,
                                outputBreakTagCount: 0
                            )
                        session = await resetSessionForNextSegment(
                            input: input,
                            segmentIndex: segment.index,
                            prewarmForTranslationFrameworkFallback: isUnsafeRecoveredByTranslationFramework,
                            onDiagnosticEvent: onDiagnosticEvent
                        )
                        sessionSegmentCount = 0
                        sessionEstimatedContextCost = 0
                        didResetSessionForNextSegment = true
                            onDiagnosticEvent?("segment=\(segment.index): session-reset-after-repetition-fallback")
                        } else if let timeoutMs = timeoutMsIfSegmentTimeout(error) {
                            onDiagnosticEvent?(
                                "segment=\(segment.index): timeout-triggered-ms=\(String(format: "%.2f", timeoutMs))"
                            )
                            onDiagnosticEvent?(
                                "segment=\(segment.index): timeout-skip-session-refresh-retry"
                            )
                            onDiagnosticEvent?(
                                "segment=\(segment.index): timeout-fallback-via-translation-framework"
                            )
                            isUnsafeFallback = true
                            shouldSkipSentenceDropRetry = true
                            let unsafeRecovery = await recoverUnsafeTranslationIfPossible(
                                sourceText: segment.text,
                                input: input,
                                segmentIndex: segment.index,
                                preprocessKind: segment.kind,
                                unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                                onDiagnosticEvent: onDiagnosticEvent
                            )
                            isUnsafeRecoveredByTranslationFramework = unsafeRecovery.usedTranslationFrameworkRecovery
                            finalResult = StructuredTranslationResult(
                                translation: unsafeRecovery.translation,
                                outputBreakTagCount: 0
                            )
                            session = await resetSessionForNextSegment(
                                input: input,
                                segmentIndex: segment.index,
                                prewarmForTranslationFrameworkFallback: isUnsafeRecoveredByTranslationFramework,
                                onDiagnosticEvent: onDiagnosticEvent
                            )
                            sessionSegmentCount = 0
                            sessionEstimatedContextCost = 0
                            didResetSessionForNextSegment = true
                            onDiagnosticEvent?("segment=\(segment.index): session-reset-after-timeout-fallback")
                        } else {
                            onDiagnosticEvent?("segment=\(segment.index): context-window-exceeded-refresh-session-and-retry")
                            session = makeTranslationSession(for: input)
                            sessionSegmentCount = 0
                            sessionEstimatedContextCost = 0
                            do {
                                finalResult = try await translateStructuredSegmentWithOptionalTimeout(
                                    prompt: prompt,
                                sourceText: segment.text,
                                expectedTargetLanguage: input.targetLanguage,
                                preprocessKind: segment.kind,
                                shouldStreamPartial: shouldStreamPartialForSegment,
                                using: session,
                                segmentIndex: segment.index,
                                onPartialResult: onPartialResult,
                                    onDiagnosticEvent: onDiagnosticEvent,
                                    timeoutBudgetMs: segmentTimeoutBudgetMs
                                )
                                onDiagnosticEvent?("segment=\(segment.index): resumed-after-session-refresh")
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                isUnsafeFallback = isUnsafeContentError(error)
                                shouldSkipSentenceDropRetry = isUnsafeFallback
                                onDiagnosticEvent?("segment=\(segment.index): retry-after-session-refresh-failed-source-returned (\(error.localizedDescription))")
                                let unsafeRecovery = await recoverUnsafeTranslationIfPossible(
                                    sourceText: segment.text,
                                    input: input,
                                    segmentIndex: segment.index,
                                    preprocessKind: segment.kind,
                                    unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                                    onDiagnosticEvent: onDiagnosticEvent
                                )
                                isUnsafeRecoveredByTranslationFramework = unsafeRecovery.usedTranslationFrameworkRecovery
                                finalResult = StructuredTranslationResult(
                                    translation: unsafeRecovery.translation,
                                    outputBreakTagCount: 0
                                )
                                if isUnsafeFallback {
                            session = await resetSessionForNextSegment(
                                input: input,
                                segmentIndex: segment.index,
                                prewarmForTranslationFrameworkFallback: isUnsafeRecoveredByTranslationFramework,
                                onDiagnosticEvent: onDiagnosticEvent
                            )
                            sessionSegmentCount = 0
                            sessionEstimatedContextCost = 0
                            didResetSessionForNextSegment = true
                                    onDiagnosticEvent?("segment=\(segment.index): session-reset-after-unsafe-fallback")
                                } else if isContextWindowExceededError(error) {
                                    session = await resetSessionForNextSegment(
                                        input: input,
                                        segmentIndex: segment.index,
                                        prewarmForTranslationFrameworkFallback: isUnsafeRecoveredByTranslationFramework,
                                        onDiagnosticEvent: onDiagnosticEvent
                                    )
                                    sessionSegmentCount = 0
                                    sessionEstimatedContextCost = 0
                                    didResetSessionForNextSegment = true
                                    onDiagnosticEvent?("segment=\(segment.index): session-reset-after-context-window-retry-failure")
                                }
                            }
                        }
                    } else {
                        onDiagnosticEvent?("segment=\(segment.index): no-retry-source-returned (\(error.localizedDescription))")
                        finalResult = StructuredTranslationResult(
                            translation: sourceFallbackTranslation(
                                sourceText: segment.text
                            ),
                            outputBreakTagCount: 0
                        )
                    }
                }

                if isUnsafeFallback {
                    onPartialResult?(segment.index, finalResult.translation)
                    let segmentDurationMs = Date().timeIntervalSince(segmentStartedAt) * 1_000
                    let segmentDurationString = String(format: "%.2f", segmentDurationMs)
                    if segment.index == 0, firstSegmentMsPerWord == nil {
                        let wordCount = wordTokenCountByNLTokenizer(segment.text)
                        firstSegmentMsPerWord = segmentDurationMs / Double(max(1, wordCount))
                        let timeoutMs = timeoutBudgetMs(
                            forSegmentIndex: 1,
                            firstSegmentMsPerWord: firstSegmentMsPerWord,
                            segmentText: segment.text
                        ) ?? minimumSegmentTimeoutMs
                        onDiagnosticEvent?(
                            "segment=\(segment.index): timeout-baseline-ms=\(segmentDurationString), words=\(wordCount), ms-per-word=\(String(format: "%.2f", firstSegmentMsPerWord ?? 0)), next-timeout-ms=\(String(format: "%.2f", timeoutMs))"
                        )
                    }
                    onDiagnosticEvent?(
                        "segment=\(segment.index), unsafe-fallback=true, tf-recovered=\(isUnsafeRecoveredByTranslationFramework), duration-ms=\(segmentDurationString)"
                    )
                    outputs.append(
                        SegmentOutput(
                            segmentIndex: segment.index,
                            sourceText: segment.text,
                            translatedText: finalResult.translation,
                            isUnsafeFallback: true,
                            isUnsafeRecoveredByTranslationFramework: isUnsafeRecoveredByTranslationFramework
                        )
                    )
                    if !didResetSessionForNextSegment {
                        sessionSegmentCount += 1
                        sessionEstimatedContextCost += estimatedContextCost(forPromptChars: nextPromptChars)
                    }
                    if segment.role == .leading, !didResetSessionForNextSegment {
                        session = makeTranslationSession(for: input)
                        sessionSegmentCount = 0
                        sessionEstimatedContextCost = 0
                        onDiagnosticEvent?("segment=\(segment.index): session-reset-after-leading-segment")
                    }
                    continue
                }

                let inputSentenceCount = sentenceCountByNLTokenizer(segment.text)
                let outputSentenceCount = sentenceCountByNLTokenizer(finalResult.translation)
                if !shouldSkipSentenceDropRetry && shouldRetryForSentenceDrop(
                    inputSentenceCount: inputSentenceCount,
                    outputSentenceCount: outputSentenceCount
                ) {
                    onDiagnosticEvent?("segment=\(segment.index): sentence-count-drop-detected retry-once")
                    onDiagnosticEvent?("segment=\(segment.index): sentence-count-drop-fallback-via-translation-framework")
                    isUnsafeFallback = true
                    shouldSkipSentenceDropRetry = true
                    let unsafeRecovery = await recoverUnsafeTranslationIfPossible(
                        sourceText: segment.text,
                        input: input,
                        segmentIndex: segment.index,
                        preprocessKind: segment.kind,
                        unsafeSegmentRecoveryEngine: unsafeSegmentRecoveryEngine,
                        onDiagnosticEvent: onDiagnosticEvent
                    )
                    isUnsafeRecoveredByTranslationFramework = unsafeRecovery.usedTranslationFrameworkRecovery
                    finalResult = StructuredTranslationResult(
                        translation: unsafeRecovery.translation,
                        outputBreakTagCount: 0
                    )
                    session = await resetSessionForNextSegment(
                        input: input,
                        segmentIndex: segment.index,
                        prewarmForTranslationFrameworkFallback: isUnsafeRecoveredByTranslationFramework,
                        onDiagnosticEvent: onDiagnosticEvent
                    )
                    sessionSegmentCount = 0
                    sessionEstimatedContextCost = 0
                    didResetSessionForNextSegment = true
                    onDiagnosticEvent?("segment=\(segment.index): session-reset-after-sentence-drop-fallback")

                    onPartialResult?(segment.index, finalResult.translation)
                    let segmentDurationMs = Date().timeIntervalSince(segmentStartedAt) * 1_000
                    let segmentDurationString = String(format: "%.2f", segmentDurationMs)
                    if segment.index == 0, firstSegmentMsPerWord == nil {
                        let wordCount = wordTokenCountByNLTokenizer(segment.text)
                        firstSegmentMsPerWord = segmentDurationMs / Double(max(1, wordCount))
                        let timeoutMs = timeoutBudgetMs(
                            forSegmentIndex: 1,
                            firstSegmentMsPerWord: firstSegmentMsPerWord,
                            segmentText: segment.text
                        ) ?? minimumSegmentTimeoutMs
                        onDiagnosticEvent?(
                            "segment=\(segment.index): timeout-baseline-ms=\(segmentDurationString), words=\(wordCount), ms-per-word=\(String(format: "%.2f", firstSegmentMsPerWord ?? 0)), next-timeout-ms=\(String(format: "%.2f", timeoutMs))"
                        )
                    }
                    onDiagnosticEvent?(
                        "segment=\(segment.index), unsafe-fallback=true, tf-recovered=\(isUnsafeRecoveredByTranslationFramework), duration-ms=\(segmentDurationString)"
                    )
                    outputs.append(
                        SegmentOutput(
                            segmentIndex: segment.index,
                            sourceText: segment.text,
                            translatedText: finalResult.translation,
                            isUnsafeFallback: true,
                            isUnsafeRecoveredByTranslationFramework: isUnsafeRecoveredByTranslationFramework
                        )
                    )
                    continue
                }
                let inputBreakCount = lineBreakTagCount(in: sourceTextForPrompt(segment.text))
                let outputBreakCount = finalResult.outputBreakTagCount
                let segmentDurationMs = Date().timeIntervalSince(segmentStartedAt) * 1_000
                let segmentDurationString = String(format: "%.2f", segmentDurationMs)
                if segment.index == 0, firstSegmentMsPerWord == nil {
                    let wordCount = wordTokenCountByNLTokenizer(segment.text)
                    firstSegmentMsPerWord = segmentDurationMs / Double(max(1, wordCount))
                    let timeoutMs = timeoutBudgetMs(
                        forSegmentIndex: 1,
                        firstSegmentMsPerWord: firstSegmentMsPerWord,
                        segmentText: segment.text
                    ) ?? minimumSegmentTimeoutMs
                    onDiagnosticEvent?(
                        "segment=\(segment.index): timeout-baseline-ms=\(segmentDurationString), words=\(wordCount), ms-per-word=\(String(format: "%.2f", firstSegmentMsPerWord ?? 0)), next-timeout-ms=\(String(format: "%.2f", timeoutMs))"
                    )
                }
                onDiagnosticEvent?(
                    "segment=\(segment.index), sentence-counts={input=\(inputSentenceCount), output=\(outputSentenceCount)}, br-counts={input=\(inputBreakCount), output=\(outputBreakCount)}, duration-ms=\(segmentDurationString)"
                )

                outputs.append(
                    SegmentOutput(
                        segmentIndex: segment.index,
                        sourceText: segment.text,
                        translatedText: finalResult.translation,
                        isUnsafeFallback: isUnsafeFallback
                    )
                )
                if !didResetSessionForNextSegment {
                    sessionSegmentCount += 1
                    sessionEstimatedContextCost += estimatedContextCost(forPromptChars: nextPromptChars)
                }
                if segment.role == .leading, !didResetSessionForNextSegment {
                    session = makeTranslationSession(for: input)
                    sessionSegmentCount = 0
                    sessionEstimatedContextCost = 0
                    onDiagnosticEvent?("segment=\(segment.index): session-reset-after-leading-segment")
                }
            }

            return outputs
        }
    }

    private static func translateStructuredSegmentWithRetry(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        preprocessKind: SegmentKind,
        shouldStreamPartial: Bool,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?,
        stallTimeoutMs: Double
    ) async throws -> StructuredTranslationResult {
        if verboseLoggingEnabled {
            let sourceForLog = sanitizedForLog(sourceText) ?? "(empty)"
            let promptForLog = sanitizedForLog(prompt) ?? "(empty)"
            onDiagnosticEvent?("verbose model-input segment=\(segmentIndex), sourceChars=\(sourceText.count), promptChars=\(prompt.count), source=\(sourceForLog), prompt=\(promptForLog)")
        }
        do {
            return try await translateSegment(
                prompt: prompt,
                sourceText: sourceText,
                expectedTargetLanguage: expectedTargetLanguage,
                shouldStreamPartial: shouldStreamPartial,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent,
                stallTimeoutMs: stallTimeoutMs
            )
        } catch let error as FoundationModelsStructuredOutputError {
            if case .targetLanguageMismatch(let expected, let actual) = error {
                throw FoundationModelsRuntimeError.structuredOutputTargetMismatch(
                    expected: expected,
                    actual: actual
                )
            }
            onDiagnosticEvent?("segment=\(segmentIndex): structured-output-no-retry-source-returned (\(error.localizedDescription))")
            return StructuredTranslationResult(
                translation: sourceFallbackTranslation(
                    sourceText: sourceText
                ),
                outputBreakTagCount: 0
            )
        }
    }

    private static func translateStructuredSegmentWithOptionalTimeout(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        preprocessKind: SegmentKind,
        shouldStreamPartial: Bool,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?,
        timeoutBudgetMs: Double?
    ) async throws -> StructuredTranslationResult {
        let stallTimeoutMs = timeoutBudgetMs ?? streamChunkStallTimeoutMs
        return try await translateStructuredSegmentWithRetry(
            prompt: prompt,
            sourceText: sourceText,
            expectedTargetLanguage: expectedTargetLanguage,
            preprocessKind: preprocessKind,
            shouldStreamPartial: shouldStreamPartial,
            using: session,
            segmentIndex: segmentIndex,
            onPartialResult: onPartialResult,
            onDiagnosticEvent: onDiagnosticEvent,
            stallTimeoutMs: stallTimeoutMs
        )
    }

    private static func translateSegment(
        prompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        shouldStreamPartial: Bool,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?,
        stallTimeoutMs: Double
    ) async throws -> StructuredTranslationResult {
        let sourceWordCount = wordTokenCountByNLTokenizer(sourceText)
        let payload = try await streamSegmentResponse(
            prompt: prompt,
            using: session,
            segmentIndex: segmentIndex,
            onPartialResult: shouldStreamPartial ? onPartialResult : nil,
            stallTimeoutMs: stallTimeoutMs,
            sourceWordCount: sourceWordCount
        )
        if verboseLoggingEnabled {
            let translationForLog = sanitizedForLog(payload.translation) ?? "(empty)"
            onDiagnosticEvent?(
                "verbose model-output segment=\(segmentIndex), payload={targetLanguage=\(payload.targetLanguage), translationChars=\(payload.translation.count), translation=\(translationForLog)}"
            )
        }
        let result = try validateStructuredTranslation(
            payload: payload,
            expectedTargetLanguage: expectedTargetLanguage,
            sourceText: sourceText
        )
        onPartialResult?(segmentIndex, result.translation)
        return result
    }

    private static func streamSegmentResponse(
        prompt: String,
        using session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        stallTimeoutMs: Double,
        sourceWordCount: Int
    ) async throws -> StructuredTranslationPayload {
        let stream = session.streamResponse(
            to: prompt,
            generating: StructuredTranslationPayload.self,
            includeSchemaInPrompt: true
        )
        let progress = StreamChunkProgress()
        let currentTask = withUnsafeCurrentTask { $0 }
        let stallWatchdogTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 250_000_000)
                let elapsedMs = await progress.elapsedSinceLastChunkMs()
                if elapsedMs >= stallTimeoutMs {
                    await progress.markTimedOut()
                    currentTask?.cancel()
                    break
                }
            }
        }
        defer { stallWatchdogTask.cancel() }

        var latestSnapshot: LanguageModelSession.ResponseStream<StructuredTranslationPayload>.Snapshot?
        var lastPartialTranslation: String?
        var observedChunkCount = 0
        var recentChunkSignatures: [String] = []
        var lastNormalizedPartialForDelta: String?
        var consecutiveNonWordExplosionChunks = 0
        var consecutiveNonWordExplosionChars = 0
        var consecutiveMonoCharExplosionChunks = 0
        var consecutiveMonoCharExplosionChars = 0

        do {
            for try await snapshot in stream {
                latestSnapshot = snapshot
                await progress.bump()
                observedChunkCount += 1

                guard let partialTranslation = extractPartialTranslation(
                    fromRawJSON: snapshot.rawContent.jsonString
                ) else {
                    continue
                }

                let normalizedPartial = normalizeBreakTagsToNewline(in: partialTranslation)
                let outputWordCount = wordTokenCountByNLTokenizer(normalizedPartial)
                if observedChunkCount >= repetitionGuardMinChunkCount,
                   outputWordCount > max(1, sourceWordCount) * repetitionGuardOutputWordMultiplier
                {
                    throw FoundationModelsRuntimeError.suspectedStreamRepetition(
                        sourceWords: sourceWordCount,
                        outputWords: outputWordCount,
                        chunks: observedChunkCount,
                        mode: "word-count-multiplier"
                    )
                }

                let chunkDelta = chunkDeltaForRepetitionDetection(
                    previous: lastNormalizedPartialForDelta,
                    current: normalizedPartial
                )
                if isLikelyNonWordExplosionChunk(chunkDelta) {
                    consecutiveNonWordExplosionChunks += 1
                    consecutiveNonWordExplosionChars += chunkDelta.count
                } else {
                    consecutiveNonWordExplosionChunks = 0
                    consecutiveNonWordExplosionChars = 0
                }
                if consecutiveNonWordExplosionChunks >= nonWordExplosionLookbackChunks,
                   consecutiveNonWordExplosionChars >= nonWordExplosionMinAddedChars
                {
                    throw FoundationModelsRuntimeError.suspectedStreamRepetition(
                        sourceWords: sourceWordCount,
                        outputWords: outputWordCount,
                        chunks: observedChunkCount,
                        mode: "nonword-explosion-\(nonWordExplosionLookbackChunks)"
                    )
                }
                if isLikelyMonotoneCharacterExplosionChunk(chunkDelta) {
                    consecutiveMonoCharExplosionChunks += 1
                    consecutiveMonoCharExplosionChars += chunkDelta.count
                } else {
                    consecutiveMonoCharExplosionChunks = 0
                    consecutiveMonoCharExplosionChars = 0
                }
                if consecutiveMonoCharExplosionChunks >= monoCharExplosionLookbackChunks,
                   consecutiveMonoCharExplosionChars >= monoCharExplosionMinAddedChars
                {
                    throw FoundationModelsRuntimeError.suspectedStreamRepetition(
                        sourceWords: sourceWordCount,
                        outputWords: outputWordCount,
                        chunks: observedChunkCount,
                        mode: "monochar-explosion-\(monoCharExplosionLookbackChunks)"
                    )
                }
                let chunkSignature = semanticSignatureForRepetitionDetection(chunkDelta)
                if isRepeatedRecentChunkSignature(
                    chunkSignature,
                    recentChunkSignatures: recentChunkSignatures
                ) {
                    throw FoundationModelsRuntimeError.suspectedStreamRepetition(
                        sourceWords: sourceWordCount,
                        outputWords: outputWordCount,
                        chunks: observedChunkCount,
                        mode: "semantic-lookback-\(semanticRepetitionLookbackChunks)"
                    )
                }
                if !chunkSignature.isEmpty {
                    recentChunkSignatures.append(chunkSignature)
                    if recentChunkSignatures.count > semanticRepetitionLookbackChunks {
                        recentChunkSignatures.removeFirst(recentChunkSignatures.count - semanticRepetitionLookbackChunks)
                    }
                }
                lastNormalizedPartialForDelta = normalizedPartial
                guard normalizedPartial != lastPartialTranslation else { continue }
                lastPartialTranslation = normalizedPartial
                onPartialResult?(segmentIndex, normalizedPartial)
            }
        } catch is CancellationError {
            if await progress.didTimeout {
                throw FoundationModelsRuntimeError.segmentProcessingTimeout(
                    timeoutMs: stallTimeoutMs
                )
            }
            throw CancellationError()
        }

        guard let latestSnapshot else {
            throw FoundationModelsStructuredOutputError.invalidFormat(content: "(empty stream)")
        }

        return try StructuredTranslationPayload(latestSnapshot.rawContent)
    }

    private static func extractPartialTranslation(fromRawJSON raw: String) -> String? {
        guard let translationKeyRange = raw.range(of: #""translation""#) else { return nil }
        let tail = raw[translationKeyRange.upperBound...]
        guard let colon = tail.firstIndex(of: ":") else { return nil }
        var cursor = raw.index(after: colon)

        while cursor < raw.endIndex, raw[cursor].isWhitespace {
            cursor = raw.index(after: cursor)
        }
        guard cursor < raw.endIndex, raw[cursor] == "\"" else { return nil }
        cursor = raw.index(after: cursor)

        var result = ""
        var escaping = false
        while cursor < raw.endIndex {
            let char = raw[cursor]
            if escaping {
                switch char {
                case "\"":
                    result.append("\"")
                case "n":
                    result.append("\n")
                case "t":
                    result.append("\t")
                case "r":
                    result.append("\r")
                case "\\":
                    result.append("\\")
                default:
                    result.append(char)
                }
                escaping = false
            } else {
                if char == "\\" {
                    escaping = true
                } else if char == "\"" {
                    break
                } else {
                    result.append(char)
                }
            }
            cursor = raw.index(after: cursor)
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func ensureModelAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            throw FoundationModelsRuntimeError.unavailable(reason: String(describing: reason))
        @unknown default:
            throw FoundationModelsRuntimeError.unavailable(reason: "unknown")
        }
    }

    private static func instructions(for input: TranslationInput) -> String {
        """
        You are a translation engine for \(input.sourceLanguage) -> \(input.targetLanguage).
        Return translated text only.
        Do not omit content.
        Keep sentence count unchanged.
        Preserve all `</br>` tokens exactly (same count and order).
        Keep punctuation/structure when possible.
        """
    }

    private static func sensitiveContentSafeInstructions(for input: TranslationInput) -> String {
        """
        You are a universal translation engine.
        Translate from \(input.sourceLanguage) to \(input.targetLanguage).
        The input can include politics, war, safety, or other sensitive topics.
        Your role is strictly translation, not policy analysis.
        Keep meaning and tone faithful.
        Do not refuse, summarize, or add warnings.
        If any part cannot be translated due to safety restrictions, keep only that part in the original language and annotate it with "原文ママ" inside "translation".
        """
    }

    private static func promptForSegment(_ segment: TextSegment, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Translate this segment.")

        if !input.glossaryMatches.isEmpty {
            let glossaryLines = input.glossaryMatches
                .map { "\($0.source)=\($0.target)" }
            lines.append("Glossary (prefer exact targets):")
            lines.append(contentsOf: glossaryLines)
        }

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("Do not translate tokens: \(protectedList)")
        }

        lines.append("Source:")
        lines.append(sourceTextForPrompt(segment.text))
        return lines.joined(separator: "\n")
    }

    private static func promptForSensitiveContentSegment(_ segment: TextSegment, input: TranslationInput) -> String {
        var lines: [String] = []
        lines.append("Task: direct translation only.")
        lines.append("Source language: \(input.sourceLanguage)")
        lines.append("Target language: \(input.targetLanguage)")

        if !input.protectedTokens.isEmpty {
            let protectedList = input.protectedTokens
                .map(\.value)
                .joined(separator: ", ")
            lines.append("")
            lines.append("Protected tokens (do not translate): \(protectedList)")
        }

        lines.append("")
        lines.append("The source is HTML-like text.")
        lines.append("STRICT REQUIREMENT: Preserve all `</br>` tokens exactly as in source (same count and order). Do not replace, remove, or add `</br>`.")
        lines.append("Translate every sentence in the source text; do not omit any part.")
        lines.append("Keep the same number of sentences as the source text.")
        lines.append("Important: translation must be translated source text only.")
        lines.append("")
        lines.append("Source text:")
        lines.append(sourceTextForPrompt(segment.text))
        return lines.joined(separator: "\n")
    }

    private static func strictPromptForSegment(
        sourceText: String,
        expectedTargetLanguage: String
    ) -> String {
        """
        Translate this text strictly.
        Rules:
        - target language: \(expectedTargetLanguage)
        - source is HTML-like text
        - STRICT REQUIREMENT: preserve all `</br>` tokens exactly as in source (same count and order)
        - do not replace, remove, or add `</br>`
        - translate every sentence in the source text; do not omit any part
        - keep the same number of sentences as the source text; do not merge, split, summarize, or drop sentences
        - output translation only, no notes or placeholders
        - translation must not be the kind label (for example: heading, general, dialogue, ui-labels, lists, codes_or_path)

        Source text:
        \(sourceTextForPrompt(sourceText))
        """
    }

    private static func fallbackSafeSegmentTranslation(
        safePrompt: String,
        sourceText: String,
        expectedTargetLanguage: String,
        preprocessKind: SegmentKind,
        session: LanguageModelSession,
        segmentIndex: Int,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async -> StructuredTranslationResult {
        do {
            return try await translateStructuredSegmentWithRetry(
                prompt: safePrompt,
                sourceText: sourceText,
                expectedTargetLanguage: expectedTargetLanguage,
                preprocessKind: preprocessKind,
                shouldStreamPartial: false,
                using: session,
                segmentIndex: segmentIndex,
                onPartialResult: onPartialResult,
                onDiagnosticEvent: onDiagnosticEvent,
                stallTimeoutMs: streamChunkStallTimeoutMs
            )
        } catch {
            onDiagnosticEvent?("segment=\(segmentIndex): fallback-failed-source-returned (\(error.localizedDescription))")
            return StructuredTranslationResult(
                translation: sourceFallbackTranslation(
                    sourceText: sourceText
                ),
                outputBreakTagCount: 0
            )
        }
    }

    private static func validateStructuredTranslation(
        payload: StructuredTranslationPayload,
        expectedTargetLanguage: String,
        sourceText: String
    ) throws -> StructuredTranslationResult {
        let actualCode = normalizedLanguageCode(payload.targetLanguage)
        let expectedCode = normalizedLanguageCode(expectedTargetLanguage)
        guard actualCode == expectedCode else {
            throw FoundationModelsStructuredOutputError.targetLanguageMismatch(
                expected: expectedCode,
                actual: actualCode
            )
        }
        let trimmed = payload.translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FoundationModelsStructuredOutputError.emptyTranslation
        }
        let sanitized = sanitizeStructuredLeakage(in: trimmed)
        guard !isPlaceholderTranslation(sanitized) else {
            throw FoundationModelsStructuredOutputError.placeholderTranslation(value: sanitized)
        }
        let sourcePromptText = sourceTextForPrompt(sourceText)
        let completed = appendMissingTrailingBreakMarkers(
            from: sourcePromptText,
            to: sanitized
        )
        let outputBreakTagCount = lineBreakTagCount(in: completed)
        let normalizedTranslation = normalizeBreakTagsToNewline(in: completed)
        return StructuredTranslationResult(
            translation: normalizedTranslation,
            outputBreakTagCount: outputBreakTagCount
        )
    }

    private static func sourceTextForPrompt(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: lineBreakMarker)
    }

    private static func sentenceCountByNLTokenizer(_ text: String) -> Int {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = normalized

        var count = 0
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { _, _ in
            count += 1
            return true
        }
        return max(1, count)
    }

    private static func shouldRetryForSentenceDrop(
        inputSentenceCount: Int,
        outputSentenceCount: Int
    ) -> Bool {
        guard inputSentenceCount > 0 else { return false }
        if inputSentenceCount == 2 && outputSentenceCount == 1 {
            return false
        }
        return outputSentenceCount * 2 < inputSentenceCount
    }

    private static func normalizeBreakTagsToNewline(in text: String) -> String {
        var normalized = text
        normalized = replaceRegex(
            pattern: #"(?i)</\s*p\s*>\s*<\s*p(?:\s+[^>]*)?\s*>"#,
            in: normalized,
            with: "\n"
        )
        normalized = replaceRegex(
            pattern: #"(?i)</\s*p\s*>"#,
            in: normalized,
            with: "\n"
        )
        normalized = replaceRegex(
            pattern: #"(?i)<\s*p(?:\s+[^>]*)?\s*>"#,
            in: normalized,
            with: ""
        )
        normalized = replaceRegex(
            pattern: #"(?i)<\s*/?\s*br(?:\s*/)?\s*>"#,
            in: normalized,
            with: "\n"
        )
        return normalized
    }

    private static func lineBreakTagCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let pattern = #"(?i)(<\s*/?\s*br(?:\s*/)?\s*>|</\s*p\s*>\s*<\s*p(?:\s+[^>]*)?\s*>|</\s*p\s*>)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: fullRange)
    }

    private static func appendMissingTrailingBreakMarkers(from sourceText: String, to outputText: String) -> String {
        let requiredTrailingBreaks = trailingBreakMarkerCount(in: sourceText)
        guard requiredTrailingBreaks > 0 else { return outputText }

        let actualTrailingBreaks = trailingBreakMarkerCount(in: outputText)
        guard actualTrailingBreaks < requiredTrailingBreaks else { return outputText }

        return outputText + String(repeating: lineBreakMarker, count: requiredTrailingBreaks - actualTrailingBreaks)
    }

    private static func trailingBreakMarkerCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var count = 0
        var remainder = text[...]
        while remainder.hasSuffix(lineBreakMarker) {
            count += 1
            remainder = remainder.dropLast(lineBreakMarker.count)
        }
        return count
    }

    private static func replaceRegex(pattern: String, in text: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: replacement)
    }

    private static func isPlaceholderTranslation(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let placeholders: Set<String> = [
            "<translated text>",
            "<translation>",
            "[translated text]",
            "[translation]",
            "(translated text)",
            "(translation)",
            "{translated text}",
            "{translation}",
        ]
        return placeholders.contains(normalized)
    }

    private static func sanitizeStructuredLeakage(in text: String) -> String {
        // Guard against occasional structured-output collapse where extra JSON/meta text
        // leaks into `translation` (for example: ..."}Author2024-...).
        let leakagePattern = #"(?:\"|”)?\}\s*[\p{L}\p{N}]"#
        guard let leakageRange = text.range(of: leakagePattern, options: .regularExpression) else {
            return text
        }

        let head = String(text[..<leakageRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"”"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return head
    }

    private static func normalizedLanguageCode(_ raw: String) -> String {
        raw
            .lowercased()
            .split(separator: "-")
            .first
            .map(String.init) ?? raw.lowercased()
    }

    private static func shouldRetryOrFallbackForGeneration(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain.contains("FoundationModels.LanguageModelSession.GenerationError") {
            return true
        }

        let reflectedType = String(reflecting: type(of: error))
        if reflectedType.contains("LanguageModelSession.GenerationError")
            || reflectedType.contains("GenerationError")
        {
            return true
        }

        let localized = error.localizedDescription.lowercased()
        return localized.contains("unsafe")
            || localized.contains("safety")
            || localized.contains("content")
            || localized.contains("policy")
    }

    private static func isUnsafeContentError(_ error: Error) -> Bool {
        var queue: [NSError] = [error as NSError]
        var visited = Set<String>()

        while let current = queue.popLast() {
            let key = "\(current.domain)#\(current.code)#\(current.localizedDescription)"
            if visited.contains(key) {
                continue
            }
            visited.insert(key)

            if isUnsafeSignal(current) {
                return true
            }

            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                queue.append(underlying)
            }
            if let detailed = current.userInfo["NSDetailedErrors"] as? [NSError] {
                queue.append(contentsOf: detailed)
            }
            if let multiple = current.userInfo["NSMultipleUnderlyingErrorsKey"] as? [NSError] {
                queue.append(contentsOf: multiple)
            }
        }

        return false
    }

    private static func isUnsafeSignal(_ error: NSError) -> Bool {
        let domain = error.domain.lowercased()
        let description = error.localizedDescription.lowercased()
        let failureReason = (error.userInfo[NSLocalizedFailureReasonErrorKey] as? String ?? "")
            .lowercased()
        let recoverySuggestion = (error.userInfo[NSLocalizedRecoverySuggestionErrorKey] as? String ?? "")
            .lowercased()
        let combined = [description, failureReason, recoverySuggestion].joined(separator: " ")

        // Foundation Models generation errors may surface as numeric codes with little text.
        if domain.contains("languagemodelsession.generationerror"), error.code == 2 {
            return true
        }

        return combined.contains("unsafe")
            || combined.contains("safety")
            || combined.contains("policy")
            || combined.contains("content filter")
            || combined.contains("prohibited")
            || combined.contains("restricted")
            || combined.contains("disallowed")
            || combined.contains("moderation")
    }

    private static func sourceFallbackTranslation(sourceText: String) -> String {
        sourceText
    }

    private static func recoverUnsafeTranslationIfPossible(
        sourceText: String,
        input: TranslationInput,
        segmentIndex: Int,
        preprocessKind: SegmentKind,
        unsafeSegmentRecoveryEngine: UnsafeSegmentRecoveryEngine,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async -> (translation: String, usedTranslationFrameworkRecovery: Bool) {
        onDiagnosticEvent?("segment=\(segmentIndex): attempting-translation-framework-recovery")

        if let recovered = await unsafeSegmentRecoveryEngine.recoverUnsafeTranslation(
            sourceText: sourceText,
            sourceLanguage: input.detectedLanguageCode ?? input.sourceLanguage,
            targetLanguage: input.targetLanguage,
            onDiagnosticEvent: onDiagnosticEvent
        ) {
            let completed = normalizeRecoveredUnsafeTranslation(
                recovered,
                sourceText: sourceText
            )
            onDiagnosticEvent?("segment=\(segmentIndex): translation-framework-recovery-succeeded")
            return (completed, true)
        }

        onDiagnosticEvent?("segment=\(segmentIndex): translation-framework-recovery-unavailable-source-returned")
        return (sourceFallbackTranslation(sourceText: sourceText), false)
    }

    private static func makeTranslationSession(for input: TranslationInput) -> LanguageModelSession {
        let model = SystemLanguageModel(
            useCase: .general,
            guardrails: .permissiveContentTransformations
        )
        return LanguageModelSession(
            model: model,
            instructions: instructions(for: input)
        )
    }

    private static func resetSessionForNextSegment(
        input: TranslationInput,
        segmentIndex: Int,
        prewarmForTranslationFrameworkFallback: Bool,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async -> LanguageModelSession {
        let nextSession = makeTranslationSession(for: input)
        guard prewarmForTranslationFrameworkFallback else { return nextSession }

        onDiagnosticEvent?("segment=\(segmentIndex): prewarm-started-after-tf-fallback")
        nextSession.prewarm()
        onDiagnosticEvent?("segment=\(segmentIndex): prewarm-finished-after-tf-fallback")
        return nextSession
    }

    private static func normalizeRecoveredUnsafeTranslation(
        _ recoveredText: String,
        sourceText: String
    ) -> String {
        let sourcePromptText = sourceTextForPrompt(sourceText)
        let recoveredPromptText = sourceTextForPrompt(recoveredText)
        let completed = appendMissingTrailingBreakMarkers(
            from: sourcePromptText,
            to: recoveredPromptText
        )
        return normalizeBreakTagsToNewline(in: completed)
    }

    private static func isContextWindowExceededError(_ error: Error) -> Bool {
        if let runtimeError = error as? FoundationModelsRuntimeError {
            if case .segmentProcessingTimeout = runtimeError {
                return true
            }
            if case .suspectedStreamRepetition = runtimeError {
                return true
            }
        }
        let localized = error.localizedDescription.lowercased()
        return localized.contains("context window")
            || localized.contains("exceeded model context window size")
    }

    private static func repetitionGuardDetails(_ error: Error) -> (sourceWords: Int, outputWords: Int, chunks: Int, mode: String)? {
        guard let runtimeError = error as? FoundationModelsRuntimeError else { return nil }
        guard case .suspectedStreamRepetition(let sourceWords, let outputWords, let chunks, let mode) = runtimeError else {
            return nil
        }
        return (sourceWords, outputWords, chunks, mode)
    }

    private static func timeoutMsIfSegmentTimeout(_ error: Error) -> Double? {
        guard let runtimeError = error as? FoundationModelsRuntimeError else { return nil }
        guard case .segmentProcessingTimeout(let timeoutMs) = runtimeError else { return nil }
        return timeoutMs
    }

    private static func structuredTargetMismatchDetails(_ error: Error) -> (expected: String, actual: String)? {
        guard let runtimeError = error as? FoundationModelsRuntimeError else { return nil }
        guard case .structuredOutputTargetMismatch(let expected, let actual) = runtimeError else {
            return nil
        }
        return (expected, actual)
    }

    private static func shouldRefreshSessionProactively(
        usedSegmentCount: Int,
        usedEstimatedContextCost: Int,
        nextPromptChars: Int
    ) -> Bool {
        guard usedSegmentCount > 0 else { return false }
        if usedSegmentCount >= maxSegmentsPerSession {
            return true
        }
        if nextPromptChars >= largePromptCharsThreshold {
            return true
        }
        let nextEstimatedContextCost = estimatedContextCost(forPromptChars: nextPromptChars)
        return usedEstimatedContextCost + nextEstimatedContextCost > maxEstimatedContextCostPerSession
    }

    private static func estimatedContextCost(forPromptChars promptChars: Int) -> Int {
        // Rough budget heuristic:
        // - prompt text itself
        // - model response tokens
        // - internal schema/instruction overhead
        // Use a conservative multiplier to rotate before hard window failures.
        (promptChars * 2) + 400
    }

    private static func timeoutBudgetMs(
        forSegmentIndex segmentIndex: Int,
        firstSegmentMsPerWord: Double?,
        segmentText: String
    ) -> Double? {
        guard segmentIndex > 0 else { return nil }
        guard let firstSegmentMsPerWord else { return nil }
        let segmentWordCount = wordTokenCountByNLTokenizer(segmentText)
        let expectedMs = firstSegmentMsPerWord * Double(max(1, segmentWordCount))
        return max(expectedMs * segmentWordTimeoutSafetyFactor, minimumSegmentTimeoutMs)
    }

    private static func wordTokenCountByNLTokenizer(_ text: String) -> Int {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return 0 }

        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = normalized

        var count = 0
        tokenizer.enumerateTokens(in: normalized.startIndex..<normalized.endIndex) { _, _ in
            count += 1
            return true
        }
        return max(1, count)
    }

    private static func semanticSignatureForRepetitionDetection(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        var buffer = String()
        buffer.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                buffer.unicodeScalars.append(scalar)
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                buffer.append(" ")
            }
        }
        let collapsed = buffer
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }

    private static func isRepeatedRecentChunkSignature(
        _ chunkSignature: String,
        recentChunkSignatures: [String]
    ) -> Bool {
        guard chunkSignature.count >= semanticRepetitionMinSignatureLength else { return false }
        return recentChunkSignatures.contains(chunkSignature)
    }

    private static func chunkDeltaForRepetitionDetection(
        previous: String?,
        current: String
    ) -> String {
        guard let previous else { return current }
        if current.hasPrefix(previous) {
            return String(current.dropFirst(previous.count))
        }

        let prefixLength = commonPrefixLength(previous, current)
        if prefixLength > 0 {
            return String(current.dropFirst(prefixLength))
        }
        return current
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var li = lhs.startIndex
        var ri = rhs.startIndex
        while li < lhs.endIndex, ri < rhs.endIndex, lhs[li] == rhs[ri] {
            count += 1
            li = lhs.index(after: li)
            ri = rhs.index(after: ri)
        }
        return count
    }

    private static func isLikelyNonWordExplosionChunk(_ delta: String) -> Bool {
        guard !delta.isEmpty else { return false }
        guard wordTokenCountByNLTokenizer(delta) == 0 else { return false }

        var nonWhitespaceCount = 0
        var newlineCount = 0
        for scalar in delta.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                newlineCount += 1
                continue
            }
            if CharacterSet.whitespaces.contains(scalar) {
                continue
            }
            nonWhitespaceCount += 1
        }
        return newlineCount >= 2 || nonWhitespaceCount >= 6
    }

    private static func isLikelyMonotoneCharacterExplosionChunk(_ delta: String) -> Bool {
        let normalized = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count >= 8 else { return false }

        var histogram: [UnicodeScalar: Int] = [:]
        var total = 0
        for scalar in normalized.unicodeScalars {
            histogram[scalar, default: 0] += 1
            total += 1
        }
        guard total > 0, let maxCount = histogram.values.max() else { return false }
        return Double(maxCount) / Double(total) >= 0.9
    }

    private static func sanitizedForLog(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.replacingOccurrences(of: "\n", with: "\\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }

        let limit = 1_500
        guard compact.count > limit else { return compact }

        let headCount = 1_000
        let tailCount = 350
        let omitted = compact.count - headCount - tailCount
        let head = compact.prefix(headCount)
        let tail = compact.suffix(tailCount)
        return "\(head)...(truncated \(omitted) chars)...\(tail)"
    }

    private static var verboseLoggingEnabled: Bool {
        UserDefaults.standard.bool(forKey: "developerVerboseModeEnabled")
    }
}

@available(macOS 26.0, iOS 26.0, *)
private actor StreamChunkProgress {
    private var lastChunkAt = Date()
    private(set) var didTimeout = false

    func bump() {
        lastChunkAt = Date()
    }

    func elapsedSinceLastChunkMs() -> Double {
        Date().timeIntervalSince(lastChunkAt) * 1_000
    }

    func markTimedOut() {
        didTimeout = true
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsStructuredOutputError: LocalizedError {
    case invalidFormat(content: String)
    case targetLanguageMismatch(expected: String, actual: String)
    case emptyTranslation
    case placeholderTranslation(value: String)

    var isRetryable: Bool {
        switch self {
        case .invalidFormat:
            return true
        case .targetLanguageMismatch:
            return true
        case .emptyTranslation:
            return true
        case .placeholderTranslation:
            return true
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidFormat:
            return "Model output was not valid structured translation content."
        case .targetLanguageMismatch(let expected, let actual):
            return "Structured output target mismatch. expected=\(expected), actual=\(actual)"
        case .emptyTranslation:
            return "Structured output translation was empty."
        case .placeholderTranslation(let value):
            return "Structured output translation was placeholder text (\(value))."
        }
    }
}

@available(macOS 26.0, iOS 26.0, *)
private enum FoundationModelsRuntimeError: LocalizedError {
    case unavailable(reason: String)
    case segmentProcessingTimeout(timeoutMs: Double)
    case suspectedStreamRepetition(sourceWords: Int, outputWords: Int, chunks: Int, mode: String)
    case structuredOutputTargetMismatch(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Foundation Models is unavailable (\(reason)). Enable Apple Intelligence and finish downloading model assets, then retry."
        case .segmentProcessingTimeout(let timeoutMs):
            return "Segment processing timed out after \(String(format: "%.2f", timeoutMs)) ms."
        case .suspectedStreamRepetition(let sourceWords, let outputWords, let chunks, let mode):
            return "Suspected stream repetition (mode=\(mode), chunks=\(chunks), sourceWords=\(sourceWords), outputWords=\(outputWords))."
        case .structuredOutputTargetMismatch(let expected, let actual):
            return "Structured output target mismatch. expected=\(expected), actual=\(actual)"
        }
    }
}
#endif
