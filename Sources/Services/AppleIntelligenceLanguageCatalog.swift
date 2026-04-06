import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct TargetLanguageOption: Hashable, Identifiable {
    enum LabelStyle {
        case ai
        case machine
    }

    let code: String
    let displayName: String
    let nativeDisplayName: String

    var id: String { code }

    func menuLabel(showCode: Bool, style: LabelStyle) -> String {
        let label: String
        switch code.lowercased() {
        case "en", "en-us":
            label = style == .ai ? "English" : "English (US)"
        case "en-gb":
            label = "English (UK)"
        case "zh", "zh-hans":
            label = style == .ai ? "中文" : "中文 (简体)"
        case "zh-hant":
            label = "中文 (繁体)"
        default:
            label = nativeDisplayName
        }
        return showCode ? "\(code) - \(label)" : label
    }
}

enum AppleIntelligenceLanguageCatalog {
    private static let fallbackLanguageCodes: [String] = [
        "da", "de", "en", "es", "fr", "it", "ja", "ko",
        "nb", "nl", "pt", "sv", "tr", "vi", "zh"
    ]
    private static let translationFrameworkFallbackLanguageCodes: [String] = [
        "ar", "cs", "da", "de", "el", "en", "en-GB", "es", "fi", "fr", "he", "hi",
        "hu", "id", "it", "ja", "ko", "ms", "nl", "no", "pl", "pt", "ro",
        "ru", "sk", "sv", "th", "tr", "uk", "vi", "zh", "zh-Hant"
    ]

    static func supportedLanguageOptions(locale: Locale = .current) -> [TargetLanguageOption] {
        let codes = foundationModelsSupportedLanguageCodes()
        return codes.map { code in
            let localized = localizedLanguageName(for: code, locale: locale)
            let native = nativeLanguageName(for: code)
            return TargetLanguageOption(
                code: code,
                displayName: localized,
                nativeDisplayName: native
            )
        }
    }

    static func translationFrameworkLanguageOptions(locale: Locale = .current) -> [TargetLanguageOption] {
        let codes = translationFrameworkFallbackLanguageCodes
        return codes.map { code in
            let localized = localizedLanguageName(for: code, locale: locale)
            let native = nativeLanguageName(for: code)
            return TargetLanguageOption(
                code: code,
                displayName: localized,
                nativeDisplayName: native
            )
        }
    }

    private static func localizedLanguageName(for code: String, locale: Locale) -> String {
        if let name = locale.localizedString(forLanguageCode: code) {
            return name
        }
        let baseCode = code.split(separator: "-").first.map(String.init) ?? code
        return locale.localizedString(forLanguageCode: baseCode) ?? code
    }

    private static func nativeLanguageName(for code: String) -> String {
        let nativeLocale = Locale(identifier: code)
        if let name = nativeLocale.localizedString(forLanguageCode: code) {
            return name
        }
        let baseCode = code.split(separator: "-").first.map(String.init) ?? code
        return nativeLocale.localizedString(forLanguageCode: baseCode) ?? code
    }

    private static func foundationModelsSupportedLanguageCodes() -> [String] {
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
