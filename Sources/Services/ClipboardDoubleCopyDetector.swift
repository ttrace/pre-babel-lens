#if os(macOS)
import AppKit
import Foundation

@MainActor
final class ClipboardDoubleCopyDetector {
    private let pollInterval: TimeInterval = 0.2
    private let doubleCopyThreshold: TimeInterval = 1.0
    private let onDoubleCopy: (String) -> Void

    private var timer: Timer?
    private var lastChangeCount: Int
    private var lastCopiedText: String?
    private var lastCopiedAt: Date?

    init(onDoubleCopy: @escaping (String) -> Void) {
        self.onDoubleCopy = onDoubleCopy
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClipboard()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount

        guard
            let copied = pasteboard.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !copied.isEmpty
        else {
            return
        }

        let now = Date()
        if lastCopiedText == copied,
           let previous = lastCopiedAt,
           now.timeIntervalSince(previous) <= doubleCopyThreshold
        {
            onDoubleCopy(copied)
            // Prevent immediate re-trigger loops from the same clipboard state.
            lastCopiedAt = nil
            return
        }

        lastCopiedText = copied
        lastCopiedAt = now
    }
}
#endif
