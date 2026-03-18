import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

struct TargetLanguageOption: Hashable, Identifiable {
    let code: String
    let displayName: String
    let nativeDisplayName: String

    var id: String { code }

    func menuLabel(showCode: Bool) -> String {
        showCode ? "\(code) - \(nativeDisplayName)" : nativeDisplayName
    }
}

enum AppleIntelligenceLanguageCatalog {
    private static let fallbackLanguageCodes: [String] = [
        "da", "de", "en", "es", "fr", "it", "ja", "ko",
        "nb", "nl", "pt", "sv", "tr", "vi", "zh"
    ]

    static func supportedLanguageOptions(locale: Locale = .current) -> [TargetLanguageOption] {
        let codes = supportedLanguageCodes()
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
