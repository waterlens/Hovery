import Foundation

/// The language of Hovery's interface. Extensions follow it too.
enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// The option for a stored language tag such as `zh-Hans-CN`, or `nil` for a language Hovery
    /// doesn't offer.
    init?(storedLanguage tag: String) {
        let language = Locale.Language(identifier: Locale.Language(identifier: tag).maximalIdentifier)
        switch (language.languageCode, language.script) {
        case (.english?, _):
            self = .english
        case (.chinese?, .hanSimplified?):
            self = .simplifiedChinese
        default:
            return nil
        }
    }
}

/// Hovery's `AppleLanguages` preference, which System Settings → General → Language & Region →
/// Applications changes as well. macOS reads it when Hovery launches.
struct InterfaceLanguagePreference {
    private static let key = "AppleLanguages"

    private let defaults: UserDefaults
    private let domain: String

    /// `domain` is the defaults domain that `defaults` writes to: the bundle identifier for
    /// `UserDefaults.standard`, or the suite name.
    init(defaults: UserDefaults = .standard, domain: String = Bundle.main.bundleIdentifier ?? "app.hovery.Hovery") {
        self.defaults = defaults
        self.domain = domain
    }

    /// The chosen language. Only Hovery's own preference counts; the system's languages
    /// are what `.system` follows.
    var language: InterfaceLanguage {
        guard let tag = (defaults.persistentDomain(forName: domain)?[Self.key] as? [String])?.first else {
            return .system
        }
        return InterfaceLanguage(storedLanguage: tag) ?? .system
    }

    func setLanguage(_ language: InterfaceLanguage) {
        if language == .system {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set([language.rawValue], forKey: Self.key)
        }
    }

    /// The localization that Hovery uses when it launches with `language`.
    static func localization(
        for language: InterfaceLanguage,
        systemLanguages: [String] = InterfaceLanguagePreference.systemLanguages,
        localizations: [String] = Bundle.main.localizations
    ) -> String? {
        let preferences = language == .system ? systemLanguages : [language.rawValue]
        return Bundle.preferredLocalizations(
            from: localizations.filter { $0 != "Base" },
            forPreferences: preferences
        ).first
    }

    /// The user's languages for all apps, in order of preference.
    static var systemLanguages: [String] {
        UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?[key] as? [String] ?? []
    }
}
