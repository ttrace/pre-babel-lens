import Combine
import UIKit
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(Translation)
import Translation
#endif

@MainActor
final class TranslationViewController: UIViewController {
    @IBOutlet private weak var targetLanguageButton: UIButton!
    @IBOutlet private weak var sourceTextView: UITextView!
    @IBOutlet private weak var outputTextView: UITextView!
    @IBOutlet private weak var statusLabel: UILabel!
    @IBOutlet private weak var translateButton: UIButton!

    private let viewModel: TranslationViewModel
#if canImport(Translation) && canImport(SwiftUI)
    private let unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController
    private var unsafeRecoveryHostingController: UIHostingController<TranslationFrameworkRecoveryBridgeView>?
#endif

    private var cancellables: Set<AnyCancellable> = []

    required init?(coder: NSCoder) {
        let preprocess = DeterministicPreprocessEngine()
#if canImport(Translation) && canImport(SwiftUI)
        let unsafeRecoveryController = TranslationFrameworkUnsafeRecoveryController()
        let translationEngine = FoundationModelsTranslationEngine(
            unsafeSegmentRecoveryEngine: unsafeRecoveryController
        )
        self.unsafeRecoveryController = unsafeRecoveryController
#else
        let translationEngine = FoundationModelsTranslationEngine()
#endif
        let policy = FixedTranslationEnginePolicy(engine: translationEngine)
        self.viewModel = TranslationViewModel(
            orchestrator: TranslationOrchestrator(
                preprocessEngine: preprocess,
                enginePolicy: policy
            )
        )
        super.init(coder: coder)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        print("[PBL][APP-UIKIT] TranslationViewController.viewDidLoad bundle=\(Bundle.main.bundleIdentifier ?? "unknown")")
#if canImport(Translation) && canImport(SwiftUI)
        embedTranslationFrameworkRecoveryBridge()
#endif
        configureUI()
        bindViewModel()
        refreshLanguageMenu()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        importSharedTextIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        importSharedTextIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @IBAction private func tapTranslate(_ sender: UIButton) {
        if viewModel.isTranslating {
            viewModel.stopTranslation()
            return
        }

        viewModel.inputText = sourceTextView.text ?? ""
        Task { await viewModel.translate() }
    }

    @IBAction private func tapClear(_ sender: UIButton) {
        sourceTextView.text = ""
        outputTextView.text = ""
        viewModel.inputText = ""
        viewModel.translatedText = ""
        viewModel.errorMessage = nil
    }

    @IBAction private func tapPaste(_ sender: UIButton) {
        sourceTextView.text = UIPasteboard.general.string ?? ""
    }

    @IBAction private func tapCopy(_ sender: UIButton) {
        let text = outputTextView.text ?? ""
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    @objc private func handleDidBecomeActive() {
        importSharedTextIfNeeded()
    }

    func applyImportedInput(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        sourceTextView.text = normalized
        viewModel.inputText = normalized
        sourceTextView.becomeFirstResponder()
        sourceTextView.selectedRange = NSRange(location: normalized.count, length: 0)
    }

    private func importSharedTextIfNeeded() {
        guard let shared = SharedImportStore.consumePendingText() else { return }
        applyImportedInput(shared)
    }

    private func configureUI() {
        title = "Pre-Babel Lens"
        view.backgroundColor = .systemBackground

        sourceTextView.font = .preferredFont(forTextStyle: .body)
        sourceTextView.layer.cornerRadius = 12
        sourceTextView.layer.borderWidth = 1
        sourceTextView.layer.borderColor = UIColor.separator.cgColor

        outputTextView.font = .preferredFont(forTextStyle: .body)
        outputTextView.layer.cornerRadius = 12
        outputTextView.layer.borderWidth = 1
        outputTextView.layer.borderColor = UIColor.separator.cgColor
        outputTextView.isEditable = false

        statusLabel.text = viewModel.statusText
        statusLabel.textColor = .secondaryLabel

        targetLanguageButton.showsMenuAsPrimaryAction = true
        targetLanguageButton.changesSelectionAsPrimaryAction = false
    }

    private func bindViewModel() {
        viewModel.$translatedText
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.outputTextView.text = text
            }
            .store(in: &cancellables)

        viewModel.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusLabel.text = self.viewModel.statusText
                self.translateButton.setTitle(self.viewModel.isTranslating ? "Stop" : "Translate", for: .normal)
            }
            .store(in: &cancellables)

        viewModel.$isTranslating
            .receive(on: RunLoop.main)
            .sink { [weak self] isTranslating in
                self?.translateButton.setTitle(isTranslating ? "Stop" : "Translate", for: .normal)
            }
            .store(in: &cancellables)

        viewModel.$errorMessage
            .receive(on: RunLoop.main)
            .sink { [weak self] message in
                guard let self else { return }
                if let message, !message.isEmpty {
                    self.statusLabel.text = message
                    self.statusLabel.textColor = .systemRed
                } else {
                    self.statusLabel.text = self.viewModel.statusText
                    self.statusLabel.textColor = .secondaryLabel
                }
            }
            .store(in: &cancellables)

        viewModel.$targetLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshLanguageMenu()
            }
            .store(in: &cancellables)
    }

#if canImport(Translation) && canImport(SwiftUI)
    private func embedTranslationFrameworkRecoveryBridge() {
        let host = UIHostingController(
            rootView: TranslationFrameworkRecoveryBridgeView(
                unsafeRecoveryController: unsafeRecoveryController
            )
        )
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.isHidden = true
        host.view.isUserInteractionEnabled = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.widthAnchor.constraint(equalToConstant: 0),
            host.view.heightAnchor.constraint(equalToConstant: 0),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
        ])
        host.didMove(toParent: self)
        unsafeRecoveryHostingController = host
    }
#endif

    private func refreshLanguageMenu() {
        let options = viewModel.targetLanguageOptions
        guard !options.isEmpty else {
            targetLanguageButton.isEnabled = false
            targetLanguageButton.setTitle("No target languages", for: .normal)
            targetLanguageButton.menu = nil
            return
        }

        let actions = options.map { option in
            UIAction(
                title: option.menuLabel(showCode: false),
                state: option.code == viewModel.targetLanguage ? .on : .off
            ) { [weak self] _ in
                guard let self else { return }
                self.viewModel.targetLanguage = option.code
                self.refreshLanguageMenu()
            }
        }

        targetLanguageButton.isEnabled = true
        targetLanguageButton.menu = UIMenu(title: "Target", children: actions)

        if let selected = options.first(where: { $0.code == viewModel.targetLanguage }) {
            targetLanguageButton.setTitle(selected.menuLabel(showCode: false), for: .normal)
        } else {
            targetLanguageButton.setTitle(options[0].menuLabel(showCode: false), for: .normal)
            viewModel.targetLanguage = options[0].code
        }
    }
}

#if canImport(Translation) && canImport(SwiftUI)
private struct TranslationFrameworkRecoveryBridgeView: View {
    @ObservedObject var unsafeRecoveryController: TranslationFrameworkUnsafeRecoveryController

    var body: some View {
        Group {
            if let configuration = unsafeRecoveryController.configuration {
                Color.clear
                    .frame(width: 0, height: 0)
                    .id(unsafeRecoveryController.requestGeneration)
                    .translationTask(configuration) { session in
                        await unsafeRecoveryController.processPendingRequest(using: session)
                    }
            } else {
                Color.clear
                    .frame(width: 0, height: 0)
            }
        }
    }
}
#endif
