import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct TargetLanguageOption: Hashable, Identifiable {
    let code: String
    let displayName: String

    var id: String { code }
    var displayLabel: String { "\(code) - \(displayName)" }
}

enum AppleIntelligenceLanguageCatalog {
    private static let fallbackLanguageCodes: [String] = [
        "da", "de", "en", "es", "fr", "it", "ja", "ko",
        "nb", "nl", "pt", "sv", "tr", "vi", "zh"
    ]

    static func supportedLanguageOptions(locale: Locale = .current) -> [TargetLanguageOption] {
        let codes = supportedLanguageCodes()
        return codes.map { code in
            let localized = locale.localizedString(forLanguageCode: code) ?? code
            return TargetLanguageOption(code: code, displayName: localized)
        }
    }

    private static func supportedLanguageCodes() -> [String] {
#if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, *) {
            let dynamicCodes = Array(
                Set(
                    SystemLanguageModel.default.supportedLanguages.compactMap {
                        $0.languageCode?.identifier.lowercased()
                    }
                )
            ).sorted()
            if !dynamicCodes.isEmpty {
                return dynamicCodes
            }
        }
#endif
        return fallbackLanguageCodes
    }
}
