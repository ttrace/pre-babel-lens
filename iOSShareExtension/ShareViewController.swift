import UniformTypeIdentifiers
import UIKit
#if canImport(PDFKit)
import PDFKit
#endif

final class ShareViewController: UIViewController {
    private struct PendingImageReservation {
        let data: Data
        let fileExtension: String?
    }

    private let cardView = UIView()
    private let previewTextView = UITextView()
    private let reserveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let buttonStack = UIStackView()
    private let contentStack = UIStackView()
    private var sharedText: String = ""
    private var pendingImageReservation: PendingImageReservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[PBL][SHARE] ShareViewController.viewDidLoad bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
        configureUI()
        Task { @MainActor in
            await loadSharedText()
        }
    }

    private func composeSharedText() async -> String {
        var fragments: [String] = []
        let attachmentText = await collectAttachmentText()
        if !attachmentText.isEmpty {
            fragments.append(attachmentText)
        }

        return fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func collectAttachmentText() async -> String {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            return ""
        }

        var fragments: [String] = []

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if pendingImageReservation == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                   let reservation = await loadImageReservation(
                       provider: provider,
                       typeIdentifier: UTType.image.identifier
                   )
                {
                    pendingImageReservation = reservation
                    continue
                }

                if let text = await loadText(from: provider) {
                    fragments.append(text)
                }
            }
        }

        return fragments
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func loadText(from provider: NSItemProvider) async -> String? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let text = await loadStringValue(provider: provider, typeIdentifier: UTType.fileURL.identifier)
        {
            return text
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let text = await loadStringValue(provider: provider, typeIdentifier: UTType.url.identifier)
        {
            return text
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadStringValue(provider: provider, typeIdentifier: UTType.plainText.identifier)
        {
            return text
        }

        return nil
    }

    private func loadImageReservation(provider: NSItemProvider, typeIdentifier: String) async -> PendingImageReservation? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                guard let reservation = Self.pendingImageReservation(fromSharedItem: item) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: reservation)
            }
        }
    }

    private func loadStringValue(provider: NSItemProvider, typeIdentifier: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
                if let url = item as? URL {
                    if url.isFileURL, let fileText = Self.readTextFile(at: url) {
                        continuation.resume(returning: fileText)
                        return
                    }
                    continuation.resume(returning: url.absoluteString)
                    return
                }
                if let text = item as? String {
                    continuation.resume(returning: text)
                    return
                }
                if let nsURL = item as? NSURL {
                    if let url = nsURL as URL?, url.isFileURL, let fileText = Self.readTextFile(at: url) {
                        continuation.resume(returning: fileText)
                        return
                    }
                    continuation.resume(returning: nsURL.absoluteString)
                    return
                }
                if let attributed = item as? NSAttributedString {
                    continuation.resume(returning: attributed.string)
                    return
                }
                continuation.resume(returning: nil)
            }
        }
    }

    nonisolated private static func readTextFile(at url: URL) -> String? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }

        let lowercasedExtension = url.pathExtension.lowercased()

        if lowercasedExtension == "pdf",
           let extracted = extractTextFromPDF(url),
           !extracted.isEmpty
        {
            return String(extracted.prefix(10_000))
        }

        if ["doc", "docx", "pages"].contains(lowercasedExtension),
           let extracted = extractTextWithAttributedString(from: url),
           !extracted.isEmpty
        {
            return String(extracted.prefix(10_000))
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8), !utf8.isEmpty {
            return String(utf8.prefix(10_000))
        }
        if let utf16 = String(data: data, encoding: .utf16), !utf16.isEmpty {
            return String(utf16.prefix(10_000))
        }
        if let shiftJIS = String(data: data, encoding: .shiftJIS), !shiftJIS.isEmpty {
            return String(shiftJIS.prefix(10_000))
        }
        return nil
    }

    nonisolated private static func extractTextWithAttributedString(from fileURL: URL) -> String? {
        if let attributed = try? NSAttributedString(
            url: fileURL,
            options: [:],
            documentAttributes: nil
        ) {
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    nonisolated private static func pendingImageReservation(fromSharedItem item: NSSecureCoding?) -> PendingImageReservation? {
        if let url = item as? URL {
            return loadImageReservation(at: url)
        }

        if let nsURL = item as? NSURL, let url = nsURL as URL? {
            return loadImageReservation(at: url)
        }

        if let data = item as? Data, !data.isEmpty {
            return PendingImageReservation(data: data, fileExtension: "jpg")
        }

        if let nsData = item as? NSData {
            let data = nsData as Data
            if !data.isEmpty {
                return PendingImageReservation(data: data, fileExtension: "jpg")
            }
        }

        if let image = item as? UIImage {
            if let pngData = image.pngData(), !pngData.isEmpty {
                return PendingImageReservation(data: pngData, fileExtension: "png")
            }
            if let jpegData = image.jpegData(compressionQuality: 0.95), !jpegData.isEmpty {
                return PendingImageReservation(data: jpegData, fileExtension: "jpg")
            }
        }

        return nil
    }

    nonisolated private static func loadImageReservation(at url: URL) -> PendingImageReservation? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return PendingImageReservation(data: data, fileExtension: ext.isEmpty ? nil : ext.lowercased())
    }

    nonisolated private static func extractTextFromPDF(_ fileURL: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: fileURL) else { return nil }

        var pages: [String] = []
        pages.reserveCapacity(document.pageCount)

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                pages.append(normalizePDFSoftLineBreaks(text))
            }
        }

        let combined = pages.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
        #else
        return nil
        #endif
    }

    nonisolated private static func normalizePDFSoftLineBreaks(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard !lines.isEmpty else { return text }

        let headingDataLengthThreshold = shortHeadingDataThreshold(for: lines)
        var resultLines: [String] = []
        resultLines.reserveCapacity(lines.count)
        var previousLineForcesBreak = true
        var verticalWritingMode = false

        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmedLine.isEmpty {
                if !resultLines.isEmpty, resultLines.last != "" {
                    resultLines.append("")
                }
                previousLineForcesBreak = true
                verticalWritingMode = false
                continue
            }

            if !verticalWritingMode {
                let verticalRunCount = consecutiveVerticalCandidateCount(from: lineIndex, in: lines)
                if verticalRunCount >= 3 {
                    verticalWritingMode = true
                }
            }

            let isLineEndMarker = shouldKeepLineBreak(afterRawLine: rawLine)
            let isBulletLine = isBulletLikeLine(trimmedLine)
            let isNumericDataLine = isNumericDataOnlyLine(trimmedLine)
            let isShortHeadingDataLine = isShortHeadingOrDataLine(
                trimmedLine,
                threshold: headingDataLengthThreshold
            )
            let blocksIncomingSoftJoin = isBulletLine || isNumericDataLine
            let blocksOutgoingSoftJoin = isBulletLine || isNumericDataLine || isShortHeadingDataLine

            if verticalWritingMode {
                if
                    var last = resultLines.last,
                    !last.isEmpty
                {
                    last += trimmedLine
                    resultLines[resultLines.count - 1] = last
                } else {
                    resultLines.append(trimmedLine)
                }
            } else if
                !previousLineForcesBreak,
                !blocksIncomingSoftJoin,
                var last = resultLines.last,
                !last.isEmpty
            {
                if shouldJoinWithoutSpace(previousLine: last) {
                    last += trimmedLine
                } else {
                    last += " " + trimmedLine
                }
                resultLines[resultLines.count - 1] = last
            } else {
                resultLines.append(trimmedLine)
            }

            if isLineEndMarker {
                verticalWritingMode = false
            }
            previousLineForcesBreak = isLineEndMarker || blocksOutgoingSoftJoin
        }

        return resultLines.joined(separator: "\n")
    }

    nonisolated private static func shouldKeepLineBreak(afterRawLine rawLine: String) -> Bool {
        guard let trailing = lastNonWhitespaceCharacter(in: rawLine) else { return false }
        return isLineEndMarkerCharacter(trailing)
    }

    nonisolated private static func isLineEndMarkerCharacter(_ character: Character) -> Bool {
        switch character {
        case ".", "。", "!", "?", "！", "？",
             ")", "]", "}", "）", "］", "｝", "〉", "》", "」", "』", "】", "〙", "〗":
            return true
        default:
            return false
        }
    }

    nonisolated private static func isBulletLikeLine(_ trimmedLine: String) -> Bool {
        let leadingTrimmed = trimmedLine.trimmingCharacters(in: .whitespaces)
        guard !leadingTrimmed.isEmpty else { return false }

        if let first = leadingTrimmed.first, ["・", "＊", "ー", "-"].contains(first) {
            return true
        }

        var index = leadingTrimmed.startIndex
        var digitCount = 0
        while index < leadingTrimmed.endIndex, leadingTrimmed[index].isNumber {
            digitCount += 1
            index = leadingTrimmed.index(after: index)
        }

        if digitCount > 0, index < leadingTrimmed.endIndex {
            let delimiter = leadingTrimmed[index]
            if delimiter == "." || delimiter == ":" || delimiter == ";" {
                return true
            }
        }
        return false
    }

    nonisolated private static func isNumericDataOnlyLine(_ trimmedLine: String) -> Bool {
        guard !trimmedLine.isEmpty else { return false }
        return trimmedLine.range(of: #"^[0-9/:\s]+$"#, options: .regularExpression) != nil
    }

    nonisolated private static func shortHeadingDataThreshold(for lines: [String]) -> Int {
        let introMax = lines
            .prefix(30)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).count }
            .max() ?? 0
        return introMax / 2
    }

    nonisolated private static func isShortHeadingOrDataLine(_ trimmedLine: String, threshold: Int) -> Bool {
        guard threshold > 0 else { return false }
        return !trimmedLine.isEmpty && trimmedLine.count <= threshold
    }

    nonisolated private static func consecutiveVerticalCandidateCount(from startIndex: Int, in allLines: [String]) -> Int {
        var index = startIndex
        var count = 0
        while index < allLines.count {
            let trimmed = allLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if isSingleCJKVerticalCandidate(trimmed) {
                count += 1
                index += 1
            } else {
                break
            }
        }
        return count
    }

    nonisolated private static func isSingleCJKVerticalCandidate(_ line: String) -> Bool {
        guard line.count == 1, let first = line.first else { return false }
        return first.unicodeScalars.allSatisfy(isCJKExcludingHangul)
    }

    nonisolated private static func shouldJoinWithoutSpace(previousLine: String) -> Bool {
        guard let trailing = lastNonWhitespaceCharacter(in: previousLine) else { return false }
        return trailing.unicodeScalars.allSatisfy(isCJKExcludingHangul)
    }

    nonisolated private static func lastNonWhitespaceCharacter(in text: String) -> Character? {
        text.last(where: { !$0.isWhitespace })
    }

    nonisolated private static func isCJKExcludingHangul(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value

        switch value {
        case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xD7B0...0xD7FF:
            return false
        default:
            break
        }

        switch value {
        case 0x2E80...0x2EFF,
             0x3000...0x303F,
             0x3040...0x30FF,
             0x31F0...0x31FF,
             0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2A6DF,
             0x2A700...0x2B73F,
             0x2B740...0x2B81F,
             0x2B820...0x2CEAF,
             0x2CEB0...0x2EBEF,
             0x30000...0x3134F:
            return true
        default:
            return false
        }
    }

    @MainActor
    private func openHostApp(withText text: String?) async {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let capped = String(trimmed.prefix(1500))
            if let primaryURL = makeImportURL(text: capped) {
                let openedPrimary = await requestOpen(primaryURL)
                if openedPrimary { return }
            }
        }

        guard let fallbackURL = URL(string: "prebabellens://import-shared") else { return }
        _ = await requestOpen(fallbackURL)
    }

    private func makeImportURL(text: String) -> URL? {
        var components = URLComponents()
        components.scheme = "prebabellens"
        components.host = "import-shared"
        if !text.isEmpty {
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        }
        return components.url
    }

    @MainActor
    private func requestOpen(_ url: URL) async -> Bool {
        guard let context = extensionContext else { return false }
        return await withCheckedContinuation { continuation in
            context.open(url) { opened in
                continuation.resume(returning: opened)
            }
        }
    }

    @MainActor
    private func presentReservationCompletedAlert() {
        let alert = UIAlertController(
            title: nil,
            message: localizedReservationCompletedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: localizedOKLabel, style: .default) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        })
        present(alert, animated: true)
    }

    private var localizedPreserveLabel: String {
        isJapaneseLocale ? "予約" : "Preserve"
    }

    private var localizedReservationCompletedMessage: String {
        isJapaneseLocale ? "予約完了。zenバベルを開いてください" : "Reserved. Please open zen-Babel."
    }

    private var localizedOKLabel: String {
        isJapaneseLocale ? "OK" : "OK"
    }

    private var isJapaneseLocale: Bool {
        Locale.preferredLanguages.first?.hasPrefix("ja") == true
    }

    @MainActor
    private func loadSharedText() async {
        let text = await composeSharedText()
        sharedText = text
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            previewTextView.text = text
        } else if pendingImageReservation != nil {
            previewTextView.text = localizedImageReservedMessage
        } else {
            previewTextView.text = localizedNoTextMessage
        }
        reserveButton.isEnabled = hasText || pendingImageReservation != nil
    }

    @objc
    private func didTapReserve() {
        Task { @MainActor in
            let trimmed = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasText = !trimmed.isEmpty
            let hasImage = pendingImageReservation != nil
            guard hasText || hasImage else { return }
            reserveButton.isEnabled = false

            if hasText {
                SharedImportStore.savePendingText(trimmed)
            } else if let image = pendingImageReservation {
                _ = SharedImportStore.savePendingImageData(
                    image.data,
                    fileExtension: image.fileExtension
                )
            }

            await openHostApp(withText: hasText ? trimmed : nil)
            presentReservationCompletedAlert()
        }
    }

    @objc
    private func didTapCancel() {
        extensionContext?.cancelRequest(withError: NSError(domain: "PreBabelLensShare", code: 0, userInfo: nil))
    }

    private func configureUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.32)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.backgroundColor = .secondarySystemBackground
        cardView.layer.cornerRadius = 18
        cardView.clipsToBounds = true
        view.addSubview(cardView)

        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        buttonStack.axis = .horizontal
        buttonStack.alignment = .fill
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 10

        configureButton(cancelButton, title: localizedCancelLabel, isPrimary: false, action: #selector(didTapCancel))
        configureButton(reserveButton, title: localizedPreserveLabel, isPrimary: true, action: #selector(didTapReserve))
        reserveButton.isEnabled = false

        buttonStack.addArrangedSubview(cancelButton)
        buttonStack.addArrangedSubview(reserveButton)

        previewTextView.translatesAutoresizingMaskIntoConstraints = false
        previewTextView.backgroundColor = .clear
        previewTextView.isEditable = false
        previewTextView.text = localizedLoadingMessage
        previewTextView.font = UIFont.preferredFont(forTextStyle: .body)
        previewTextView.textColor = .label

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.addArrangedSubview(buttonStack)
        contentStack.addArrangedSubview(previewTextView)

        cardView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),

            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -16),

            previewTextView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
        ])
    }

    private func configureButton(_ button: UIButton, title: String, isPrimary: Bool, action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.layer.cornerRadius = 20
        button.heightAnchor.constraint(equalToConstant: 40).isActive = true
        button.addTarget(self, action: action, for: .touchUpInside)

        if isPrimary {
            button.backgroundColor = .systemBlue
            button.setTitleColor(.white, for: .normal)
            button.setTitleColor(.white.withAlphaComponent(0.6), for: .disabled)
        } else {
            button.backgroundColor = .systemGray5
            button.setTitleColor(.label, for: .normal)
        }
    }

    private var localizedLoadingMessage: String {
        isJapaneseLocale ? "読み込み中..." : "Loading..."
    }

    private var localizedNoTextMessage: String {
        isJapaneseLocale ? "共有可能なテキストが見つかりませんでした。" : "No shareable text was found."
    }

    private var localizedImageReservedMessage: String {
        isJapaneseLocale
            ? "画像を予約しました。zenバベル起動時にOCRを実行します。"
            : "Image reserved. OCR will run when zen-Babel launches."
    }

    private var localizedCancelLabel: String {
        isJapaneseLocale ? "キャンセル" : "Cancel"
    }
}
