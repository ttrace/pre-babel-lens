import UniformTypeIdentifiers
import UIKit

final class ShareViewController: UIViewController {
    private let cardView = UIView()
    private let previewTextView = UITextView()
    private let reserveButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let buttonStack = UIStackView()
    private let contentStack = UIStackView()
    private var sharedText: String = ""

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

        guard let data = try? Data(contentsOf: url) else { return nil }
        if let utf8 = String(data: data, encoding: .utf8) {
            return String(utf8.prefix(10_000))
        }
        if let utf16 = String(data: data, encoding: .utf16) {
            return String(utf16.prefix(10_000))
        }
        if let shiftJIS = String(data: data, encoding: .shiftJIS) {
            return String(shiftJIS.prefix(10_000))
        }
        return nil
    }

    @MainActor
    private func openHostApp(with text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let capped = String(trimmed.prefix(1500))
        guard let primaryURL = makeImportURL(text: capped) else { return }

        let openedPrimary = await requestOpen(primaryURL)
        if openedPrimary { return }

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
        isJapaneseLocale ? "予約完了。Pre-Babel Lensを開いてください" : "Reserved. Please open Pre-Babel Lens."
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
        previewTextView.text = text.isEmpty ? localizedNoTextMessage : text
        reserveButton.isEnabled = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @objc
    private func didTapReserve() {
        Task { @MainActor in
            let trimmed = sharedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            reserveButton.isEnabled = false
            SharedImportStore.savePendingText(trimmed)
            await openHostApp(with: trimmed)
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

    private var localizedCancelLabel: String {
        isJapaneseLocale ? "キャンセル" : "Cancel"
    }
}
