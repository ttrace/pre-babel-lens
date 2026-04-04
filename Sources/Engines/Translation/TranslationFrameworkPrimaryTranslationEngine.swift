import Foundation

struct TranslationFrameworkPrimaryTranslationEngine: DiagnosticCapableTranslationEngine {
    fileprivate enum RecoveryFailureKind: String {
        case missingSourceLanguage = "missing_source_language"
        case missingTargetLanguage = "missing_target_language"
        case missingSourceAndTargetLanguage = "missing_source_and_target_language"
        case unsupportedLanguagePairing = "unsupported_language_pairing"
    }

    private final class RecoveryDiagnosticState: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var failureKind: RecoveryFailureKind?
        private(set) var insertedSourceFallback: Bool = false

        func capture(message: String) {
            lock.lock()
            if let parsed = TranslationFrameworkPrimaryTranslationEngine.parseRecoveryFailureKind(from: message) {
                failureKind = parsed
            }
            if message.contains("translation-framework-recovery:source-fallback-inserted") {
                insertedSourceFallback = true
            }
            lock.unlock()
        }

        func snapshot() -> (failureKind: RecoveryFailureKind?, insertedSourceFallback: Bool) {
            lock.lock()
            let snapshot = (
                failureKind: failureKind,
                insertedSourceFallback: insertedSourceFallback
            )
            lock.unlock()
            return snapshot
        }
    }

    private let recoveryEngine: UnsafeSegmentRecoveryEngine

    init(recoveryEngine: UnsafeSegmentRecoveryEngine) {
        self.recoveryEngine = recoveryEngine
    }

    var name: String { "translation-framework-primary" }

    func translate(_ input: TranslationInput) async throws -> [SegmentOutput] {
        try await translate(input, onPartialResult: nil, onDiagnosticEvent: nil)
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?
    ) async throws -> [SegmentOutput] {
        try await translate(input, onPartialResult: onPartialResult, onDiagnosticEvent: nil)
    }

    func translate(
        _ input: TranslationInput,
        onPartialResult: (@Sendable (_ segmentIndex: Int, _ partialTranslation: String) -> Void)?,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> [SegmentOutput] {
        let segments = input.segments.isEmpty
            ? [TextSegment(index: 0, text: input.originalText, role: .leading)]
            : input.segments

        onDiagnosticEvent?("engine=tf-primary-start segments=\(segments.count) source=\(input.sourceLanguage) target=\(input.targetLanguage)")

        var outputs: [SegmentOutput] = []
        outputs.reserveCapacity(segments.count)

        for segment in segments {
            try Task.checkCancellation()
            if Self.verboseLoggingEnabled {
                let sourceForLog = Self.sanitizedForLog(segment.text) ?? "(empty)"
                onDiagnosticEvent?(
                    "verbose tf-input segment=\(segment.index) chars=\(segment.text.count) source=\(sourceForLog)"
                )
            }

            let recoveryDiagnosticState = RecoveryDiagnosticState()
            let translated = await recoveryEngine.recoverUnsafeTranslation(
                sourceText: segment.text,
                sourceLanguage: input.sourceLanguage,
                targetLanguage: input.targetLanguage,
                onDiagnosticEvent: { message in
                    recoveryDiagnosticState.capture(message: message)
                    onDiagnosticEvent?(message)
                }
            )
            let recoveryDiagnosticSnapshot = recoveryDiagnosticState.snapshot()
            let recoveryFailureKind = recoveryDiagnosticSnapshot.failureKind

            let translatedText = translated ?? ""
            if translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               recoveryFailureKind == .unsupportedLanguagePairing {
                onDiagnosticEvent?(
                    "segment=\(segment.index): tf-primary-retry-with-auto-source-after-unsupported-pairing"
                )

                let retryDiagnosticState = RecoveryDiagnosticState()
                let retried = await recoveryEngine.recoverUnsafeTranslation(
                    sourceText: segment.text,
                    sourceLanguage: "und",
                    targetLanguage: input.targetLanguage,
                    onDiagnosticEvent: { message in
                        retryDiagnosticState.capture(message: message)
                        onDiagnosticEvent?(message)
                    }
                )
                let retrySnapshot = retryDiagnosticState.snapshot()
                let retriedText = retried ?? ""
                if !retriedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if Self.verboseLoggingEnabled {
                        let outputForLog = Self.sanitizedForLog(retriedText) ?? "(empty)"
                        onDiagnosticEvent?(
                            "verbose tf-output segment=\(segment.index) chars=\(retriedText.count) output=\(outputForLog)"
                        )
                    }

                    onPartialResult?(segment.index, retriedText)
                    outputs.append(
                        SegmentOutput(
                            segmentIndex: segment.index,
                            sourceText: segment.text,
                            translatedText: retriedText,
                            isUnsafeFallback: retrySnapshot.insertedSourceFallback,
                            isUnsafeRecoveredByTranslationFramework: false
                        )
                    )
                    continue
                }
            }

            guard !translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                let reason = recoveryFailureKind?.rawValue ?? "unknown"
                onDiagnosticEvent?(
                    "segment=\(segment.index): tf-primary-empty-result-fallback-to-source reason=\(reason)"
                )
                onPartialResult?(segment.index, segment.text)
                outputs.append(
                    SegmentOutput(
                        segmentIndex: segment.index,
                        sourceText: segment.text,
                        translatedText: segment.text,
                        isUnsafeFallback: true,
                        isUnsafeRecoveredByTranslationFramework: false
                    )
                )
                continue
            }

            if Self.verboseLoggingEnabled {
                let outputForLog = Self.sanitizedForLog(translatedText) ?? "(empty)"
                onDiagnosticEvent?(
                    "verbose tf-output segment=\(segment.index) chars=\(translatedText.count) output=\(outputForLog)"
                )
            }

            onPartialResult?(segment.index, translatedText)
            outputs.append(
                SegmentOutput(
                    segmentIndex: segment.index,
                    sourceText: segment.text,
                    translatedText: translatedText,
                    isUnsafeFallback: recoveryDiagnosticSnapshot.insertedSourceFallback,
                    isUnsafeRecoveredByTranslationFramework: false
                )
            )
        }

        onDiagnosticEvent?("engine=tf-primary-finished segments=\(outputs.count)")
        return outputs
    }

    private static func parseRecoveryFailureKind(from message: String) -> RecoveryFailureKind? {
        let marker = "translation-framework-recovery:failure-kind="
        guard let range = message.range(of: marker) else { return nil }
        let raw = String(message[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return RecoveryFailureKind(rawValue: raw)
    }

    private static func sanitizedForLog(_ text: String?) -> String? {
        guard let text else { return nil }
        let compact = text.replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
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

private enum TranslationFrameworkPrimaryEngineError: LocalizedError {
    case recoveryFailed(
        segmentIndex: Int,
        sourceLanguage: String,
        targetLanguage: String,
        failureKind: TranslationFrameworkPrimaryTranslationEngine.RecoveryFailureKind?
    )

    var errorDescription: String? {
        switch self {
        case .recoveryFailed(let segmentIndex, let sourceLanguage, let targetLanguage, let failureKind):
            let reasonSuffix: String
            if let failureKind {
                reasonSuffix = " reason=\(failureKind.rawValue)."
            } else {
                reasonSuffix = "."
            }
            return "Translation Framework could not complete translation for segment=\(segmentIndex) (\(sourceLanguage)->\(targetLanguage))\(reasonSuffix) Please confirm language-pack download and retry."
        }
    }
}
