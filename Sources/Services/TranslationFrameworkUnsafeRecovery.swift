import Foundation
#if canImport(Logging)
import Logging
#endif

#if canImport(Translation)
@preconcurrency import Translation

@MainActor
final class TranslationFrameworkUnsafeRecoveryController: ObservableObject, UnsafeSegmentRecoveryEngine, @unchecked Sendable {
    private enum MissingLanguageKind: String {
        case source = "missing_source_language"
        case target = "missing_target_language"
        case sourceAndTarget = "missing_source_and_target_language"
        case unsupportedPair = "unsupported_language_pairing"
    }

    #if canImport(Logging)
    private static let logger = Logger(subsystem: "com.ttrace.prebabellens", category: "translation-framework")
    #endif
    private struct RecoveryChunk {
        enum Kind {
            case text
            case separator
        }

        let kind: Kind
        let value: String
    }

    private enum SourceLanguageResolutionReason: String {
        case requested
        case estimatedFromText = "estimated_from_text"
        case fallbackPreviousSuccess = "fallback_previous_success"
        case undetermined
    }

    private struct PendingRequest {
        let id: UUID
        let sourceText: String
        let sourceLanguage: String
        let resolvedSourceLanguageCode: String?
        let sourceLanguageResolutionReason: SourceLanguageResolutionReason
        let targetLanguage: String
        let onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    }

    private enum RecoveryTimeoutError: Error {
        case timedOut(stage: String)
    }

    @Published private(set) var configuration: TranslationSession.Configuration?
    @Published private(set) var requestGeneration = UUID()

    private var pendingRequest: PendingRequest?
    private var pendingContinuation: CheckedContinuation<String?, Never>?
    private var lastSuccessfulSourceLanguageCode: String?
    private var pendingRequestWatchdogTask: Task<Void, Never>?
    private static let translationCallTimeoutNanoseconds: UInt64 = 25_000_000_000
    private static let pendingRequestWatchdogNanoseconds: UInt64 = 45_000_000_000

    private func log(_ message: String) {
    #if canImport(Logging)
        let context = "request=\(pendingRequest?.id.uuidString ?? "none")"
        TranslationFrameworkUnsafeRecoveryController.logger.debug("\(message, privacy: .public) [\(context)]")
    #else
        print("[TranslationFramework] \(message)")
    #endif
    }

    func recoverUnsafeTranslation(
        sourceText: String,
        sourceLanguage: String,
        targetLanguage: String,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async -> String? {
        if let currentPendingRequest = pendingRequest {
            onDiagnosticEvent?(
                "translation-framework-recovery: skipped-because-request-is-already-active id=\(currentPendingRequest.id.uuidString)"
            )
            log("stale-request-reset-triggered id=\(currentPendingRequest.id.uuidString)")
            finishPendingRequest(with: nil)
        }

        let requestID = UUID()
        let (resolvedSourceLanguageCode, resolutionReason) = resolveSourceLanguageCode(
            requestedSourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        pendingRequest = PendingRequest(
            id: requestID,
            sourceText: sourceText,
            sourceLanguage: sourceLanguage,
            resolvedSourceLanguageCode: resolvedSourceLanguageCode,
            sourceLanguageResolutionReason: resolutionReason,
            targetLanguage: targetLanguage,
            onDiagnosticEvent: onDiagnosticEvent
        )
        var configuration = TranslationSession.Configuration(
            source: localeLanguage(from: resolvedSourceLanguageCode ?? sourceLanguage),
            target: localeLanguage(from: targetLanguage)
        )
        onDiagnosticEvent?(
            "translation-framework-recovery: source-language requested=\(sourceLanguage) resolved=\(resolvedSourceLanguageCode ?? "auto") reason=\(resolutionReason.rawValue)"
        )
        configuration.invalidate()
        requestGeneration = UUID()
        self.configuration = configuration
        pendingRequestWatchdogTask?.cancel()
        pendingRequestWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingRequestWatchdogNanoseconds)
            guard let self else { return }
            guard let pendingRequest, pendingRequest.id == requestID else { return }
            pendingRequest.onDiagnosticEvent?(
                "translation-framework-recovery: watchdog-timeout id=\(requestID.uuidString)"
            )
            self.log("watchdog-timeout id=\(requestID.uuidString)")
            self.finishPendingRequest(with: nil)
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
        }
    }

    func processPendingRequest(using session: TranslationSession) async {
        guard let request = pendingRequest else { return }

        log("request-started")
        do {
            let availability = LanguageAvailability()
            let targetLanguage = localeLanguage(from: request.targetLanguage)
            let status: LanguageAvailability.Status
            do {
                status = try await resolvePairAvailabilityStatus(
                    availability: availability,
                    request: request,
                    targetLanguage: targetLanguage
                )
            } catch {
                if isTranslationServiceConnectionError(error) {
                    request.onDiagnosticEvent?(
                        "translation-framework-recovery: transient-service-connection-error stage=availability retry=1"
                    )
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    status = try await resolvePairAvailabilityStatus(
                        availability: availability,
                        request: request,
                        targetLanguage: targetLanguage
                    )
                } else {
                    throw error
                }
            }
            log("availability=\(describe(status))")

            if status == .unsupported {
                log("unsupported-language-pairing")
                if let missingLanguageKind = await diagnoseMissingLanguageKind(
                    sourceLanguage: request.sourceLanguage,
                    targetLanguage: request.targetLanguage,
                    sourceText: request.sourceText,
                    using: availability
                ) {
                    request.onDiagnosticEvent?(
                        "translation-framework-recovery:failure-kind=\(missingLanguageKind.rawValue)"
                    )
                    log("failure-kind=\(missingLanguageKind.rawValue)")
                }
                finishPendingRequest(with: nil)
                return
            }

            let translated: String
            do {
                if status == .supported {
                    log("preparing-download-or-consent")
                    try await session.prepareTranslation()
                    log("prepare-finished")
                }

                translated = try await performWithTimeout(stage: "translate") {
                    try await self.translatePreservingSeparators(
                        request.sourceText,
                        using: session,
                        onDiagnosticEvent: request.onDiagnosticEvent
                    )
                }
            } catch {
                if isTranslationTimeoutError(error) {
                    let stage = timeoutStage(from: error)
                    request.onDiagnosticEvent?(
                        "translation-framework-recovery: timeout stage=\(stage) retry=1"
                    )
                    log("timeout stage=\(stage)")
                    try? await Task.sleep(nanoseconds: 250_000_000)

                    translated = try await performWithTimeout(stage: "translate(retry)") {
                        try await self.translatePreservingSeparators(
                            request.sourceText,
                            using: session,
                            onDiagnosticEvent: request.onDiagnosticEvent
                        )
                    }
                } else if isTranslationServiceConnectionError(error) {
                    request.onDiagnosticEvent?(
                        "translation-framework-recovery: transient-service-connection-error stage=translate retry=1"
                    )
                    try? await Task.sleep(nanoseconds: 250_000_000)

                    if status == .supported {
                        log("preparing-download-or-consent(retry)")
                        try await session.prepareTranslation()
                        log("prepare-finished(retry)")
                    }

                    translated = try await performWithTimeout(stage: "translate(retry)") {
                        try await self.translatePreservingSeparators(
                            request.sourceText,
                            using: session,
                            onDiagnosticEvent: request.onDiagnosticEvent
                        )
                    }
                } else {
                    throw error
                }
            }
            if let resolved = normalizedLanguageIdentifier(request.resolvedSourceLanguageCode),
               baseLanguageCode(from: resolved) != "und" {
                lastSuccessfulSourceLanguageCode = resolved
            }
            log("request-finished chars=\(translated.count)")
            finishPendingRequest(with: translated.isEmpty ? nil : translated)
        } catch is CancellationError {
            log("cancelled")
            finishPendingRequest(with: nil)
        } catch {
            var failureKind = await classifyFailureKind(
                error: error,
                request: request
            )

            if failureKind == nil {
                let availability = LanguageAvailability()
                failureKind = await diagnoseMissingLanguageKind(
                    sourceLanguage: request.sourceLanguage,
                    targetLanguage: request.targetLanguage,
                    sourceText: request.sourceText,
                    using: availability
                )
            }

            if let failureKind {
                request.onDiagnosticEvent?(
                    "translation-framework-recovery:failure-kind=\(failureKind.rawValue)"
                )
                log("failure-kind=\(failureKind.rawValue)")
            }
            log("failed: \(error.localizedDescription)")
            finishPendingRequest(with: nil)
        }
    }

    func clearPendingRecoveryState() {
        if pendingRequest != nil || configuration != nil {
            log("clear-pending-recovery-state")
        }
        finishPendingRequest(with: nil)
        requestGeneration = UUID()
    }

    private func finishPendingRequest(with translatedText: String?) {
        pendingRequestWatchdogTask?.cancel()
        pendingRequestWatchdogTask = nil
        configuration = nil
        pendingRequest = nil
        pendingContinuation?.resume(returning: translatedText)
        pendingContinuation = nil
    }

    private func translatePreservingSeparators(
        _ text: String,
        using session: TranslationSession,
        onDiagnosticEvent: (@Sendable (_ message: String) -> Void)?
    ) async throws -> String {
        let chunks = splitIntoRecoveryChunks(text)
        let textChunks = chunks.enumerated().compactMap { index, chunk -> TranslationSession.Request? in
            guard chunk.kind == .text else { return nil }
            return TranslationSession.Request(
                sourceText: chunk.value,
                clientIdentifier: String(index)
            )
        }

        guard !textChunks.isEmpty else { return text }
        if Self.verboseLoggingEnabled {
            let sourceForLog = Self.sanitizedForLog(text) ?? "(empty)"
            onDiagnosticEvent?(
                "verbose tf-recovery-input chars=\(text.count) chunks=\(textChunks.count) source=\(sourceForLog)"
            )
        }
        nonisolated(unsafe) let detachedTextChunks = textChunks
        let responses = try await session.translations(from: detachedTextChunks)
        let translatedByIdentifier = Dictionary(
            uniqueKeysWithValues: responses.compactMap { response -> (String, String)? in
                guard let clientIdentifier = response.clientIdentifier else { return nil }
                return (clientIdentifier, response.targetText)
            }
        )

        let reconstructed = chunks.enumerated().map { index, chunk in
            switch chunk.kind {
            case .separator:
                return chunk.value
            case .text:
                return translatedByIdentifier[String(index)] ?? chunk.value
            }
        }
        .joined()

        let missingTextChunkCount = chunks.enumerated().reduce(into: 0) { count, entry in
            let (index, chunk) = entry
            guard chunk.kind == .text else { return }
            if translatedByIdentifier[String(index)] == nil {
                count += 1
            }
        }
        if missingTextChunkCount > 0 {
            onDiagnosticEvent?(
                "translation-framework-recovery:source-fallback-inserted chunks=\(missingTextChunkCount)"
            )
        }

        if Self.verboseLoggingEnabled {
            let outputForLog = Self.sanitizedForLog(reconstructed) ?? "(empty)"
            onDiagnosticEvent?(
                "verbose tf-recovery-output chars=\(reconstructed.count) output=\(outputForLog)"
            )
        }

        return reconstructed
    }

    private func splitIntoRecoveryChunks(_ text: String) -> [RecoveryChunk] {
        guard !text.isEmpty else { return [] }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let regex = try? NSRegularExpression(pattern: #"\n+"#)
        let matches = regex?.matches(in: text, range: nsRange) ?? []
        guard !matches.isEmpty else {
            return [RecoveryChunk(kind: .text, value: text)]
        }

        var chunks: [RecoveryChunk] = []
        var cursor = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                chunks.append(
                    RecoveryChunk(kind: .text, value: String(text[cursor..<range.lowerBound]))
                )
            }
            chunks.append(
                RecoveryChunk(kind: .separator, value: String(text[range]))
            )
            cursor = range.upperBound
        }

        if cursor < text.endIndex {
            chunks.append(
                RecoveryChunk(kind: .text, value: String(text[cursor..<text.endIndex]))
            )
        }

        return chunks
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

    private func localeLanguage(from code: String) -> Locale.Language? {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "und" else { return nil }
        return Locale.Language(identifier: canonicalTranslationFrameworkLanguageIdentifier(from: trimmed))
    }

    private func canonicalTranslationFrameworkLanguageIdentifier(from rawCode: String) -> String {
        let normalized = rawCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        // Translation.framework can treat generic "en" as unavailable even when
        // regional English assets (en-US / en-GB) are present.
        if normalized == "en" {
            return "en-US"
        }
        if normalized == "en-uk" {
            return "en-GB"
        }

        if normalized == "zh" || normalized == "zh-cn" || normalized == "zh-sg" || normalized == "zh-ch" || normalized == "zh-hans" {
            return "zh-CN"
        }

        if normalized == "zh-tw" || normalized == "zh-hk" || normalized == "zh-mo" || normalized == "zh-hant" {
            return "zh-TW"
        }

        return rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func describe(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed:
            return "installed"
        case .supported:
            return "supported"
        case .unsupported:
            return "unsupported"
        @unknown default:
            return "unknown"
        }
    }

    private func diagnoseMissingLanguageKind(
        sourceLanguage: String,
        targetLanguage: String,
        sourceText: String,
        using availability: LanguageAvailability
    ) async -> MissingLanguageKind? {
        let targetStatus: LanguageAvailability.Status? = if let target = localeLanguage(from: targetLanguage) {
            await availability.status(from: target, to: nil)
        } else {
            nil
        }
        let sourceStatus: LanguageAvailability.Status? = if let source = localeLanguage(from: sourceLanguage) {
            await availability.status(from: source, to: nil)
        } else {
            try? await availability.status(
                for: sourceText,
                to: nil
            )
        }

        let sourceMissing = sourceStatus.map { $0 != .installed }
        let targetMissing = targetStatus.map { $0 != .installed } ?? false

        if sourceMissing == true && targetMissing {
            return .sourceAndTarget
        }
        if sourceMissing == true {
            return .source
        }
        if targetMissing {
            return .target
        }
        return .unsupportedPair
    }

    private func classifyFailureKind(
        error: Error,
        request: PendingRequest
    ) async -> MissingLanguageKind? {
        #if canImport(Translation)
        if TranslationError.unsupportedSourceLanguage ~= error {
            return .source
        }
        if TranslationError.unsupportedTargetLanguage ~= error {
            return .target
        }
        if TranslationError.unsupportedLanguagePairing ~= error {
            let availability = LanguageAvailability()
            return await diagnoseMissingLanguageKind(
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                sourceText: request.sourceText,
                using: availability
            )
        }
        if #available(macOS 26.0, iOS 26.0, *), TranslationError.notInstalled ~= error {
            let availability = LanguageAvailability()
            return await diagnoseMissingLanguageKind(
                sourceLanguage: request.sourceLanguage,
                targetLanguage: request.targetLanguage,
                sourceText: request.sourceText,
                using: availability
            )
        }
        #endif

        return nil
    }

    private func isTranslationServiceConnectionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 4097 {
            return true
        }

        let debugDescription = (nsError.userInfo[NSDebugDescriptionErrorKey] as? String) ?? ""
        let message = "\(debugDescription) \(nsError.localizedDescription)".lowercased()
        return message.contains("com.apple.translation.text")
            || message.contains("connection to service")
            || message.contains("translationd")
    }

    private func isTranslationTimeoutError(_ error: Error) -> Bool {
        (error as? RecoveryTimeoutError) != nil
    }

    private func timeoutStage(from error: Error) -> String {
        guard let timeoutError = error as? RecoveryTimeoutError else { return "unknown" }
        switch timeoutError {
        case .timedOut(let stage):
            return stage
        }
    }

    private func performWithTimeout<T: Sendable>(
        stage: String,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let timeoutNanoseconds = Self.translationCallTimeoutNanoseconds
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw RecoveryTimeoutError.timedOut(stage: stage)
            }
            guard let first = try await group.next() else {
                throw RecoveryTimeoutError.timedOut(stage: stage)
            }
            group.cancelAll()
            return first
        }
    }

    private func resolvePairAvailabilityStatus(
        availability: LanguageAvailability,
        request: PendingRequest,
        targetLanguage: Locale.Language?
    ) async throws -> LanguageAvailability.Status {
        let effectiveSourceLanguageCode = request.resolvedSourceLanguageCode ?? request.sourceLanguage
        if let sourceLanguage = localeLanguage(from: effectiveSourceLanguageCode) {
            let status = await availability.status(
                from: sourceLanguage,
                to: targetLanguage
            )
            request.onDiagnosticEvent?(
                "translation-framework-recovery: availability-check=from source=\(effectiveSourceLanguageCode) target=\(request.targetLanguage) status=\(describe(status))"
            )
            return status
        }

        let status = try await availability.status(
            for: request.sourceText,
            to: targetLanguage
        )
        request.onDiagnosticEvent?(
            "translation-framework-recovery: availability-check=from-text source=\(request.sourceLanguage) target=\(request.targetLanguage) status=\(describe(status))"
        )
        return status
    }

    private func resolveSourceLanguageCode(
        requestedSourceLanguage: String,
        targetLanguage: String
    ) -> (String?, SourceLanguageResolutionReason) {
        if let requested = normalizedLanguageIdentifier(requestedSourceLanguage),
           baseLanguageCode(from: requested) != "und" {
            return (alignedGenericSourceLanguageCode(requested, forTargetLanguage: targetLanguage), .requested)
        }

        // Keep explicit auto-source requests as auto when no prior successful language exists.
        // This avoids over-constraining pairs such as zh-Hans <-> zh-Hant where fixed source
        // variants can be rejected but auto source detection may still work.
        if let previous = normalizedLanguageIdentifier(lastSuccessfulSourceLanguageCode),
           baseLanguageCode(from: previous) != "und" {
            return (alignedGenericSourceLanguageCode(previous, forTargetLanguage: targetLanguage), .fallbackPreviousSuccess)
        }

        return (nil, .undetermined)
    }

    private func normalizedLanguageIdentifier(_ code: String?) -> String? {
        guard let code else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed.replacingOccurrences(of: "_", with: "-")
    }

    private func baseLanguageCode(from identifier: String) -> String {
        identifier.split(separator: "-").first.map(String.init) ?? identifier
    }

    private func alignedGenericSourceLanguageCode(_ sourceLanguage: String, forTargetLanguage targetLanguage: String) -> String {
        let source = sourceLanguage.lowercased()
        let target = canonicalTranslationFrameworkLanguageIdentifier(from: targetLanguage).lowercased()

        if source == "en" {
            if target == "en-gb" || target == "en-uk" {
                return "en-US"
            }
            if target == "en-us" {
                return "en-GB"
            }
            return "en-US"
        }

        if baseLanguageCode(from: source) == "zh" {
            if target == "zh-tw" {
                return "zh-CN"
            }
            if target == "zh-cn" || target == "zh-ch" {
                return "zh-TW"
            }
            // Keep explicit Chinese variants when target does not indicate script preference.
            let sourceCanonical = canonicalTranslationFrameworkLanguageIdentifier(from: sourceLanguage)
            if sourceCanonical.lowercased() == "zh-cn" || sourceCanonical.lowercased() == "zh-tw" {
                return sourceCanonical
            }
            return "zh-CN"
        }

        return sourceLanguage
    }
}
#endif
