import Foundation
import TOMLKit

/// The text that an extension's `i18n.toml` provides for one language.
struct WebExtensionLocalizedText: Equatable, Sendable {
    struct Setting: Equatable, Sendable {
        var title: String?
        var detail: String?
        var placeholder: String?
        /// Titles of choice options, keyed by option value.
        var options: [String: String] = [:]
    }

    var name: String?
    /// Keyed by setting key.
    var settings: [String: Setting] = [:]
    var messages: [String: String] = [:]

    /// This text, replaced by `other`'s text wherever `other` provides some.
    func overlaid(by other: WebExtensionLocalizedText) -> WebExtensionLocalizedText {
        var result = self
        result.name = other.name ?? name
        result.settings.merge(other.settings) { base, override in
            Setting(
                title: override.title ?? base.title,
                detail: override.detail ?? base.detail,
                placeholder: override.placeholder ?? base.placeholder,
                options: base.options.merging(override.options) { _, override in override }
            )
        }
        result.messages.merge(other.messages) { _, override in override }
        return result
    }

    /// `settings` with the titles, descriptions, placeholders, and option titles that this text provides.
    /// Setting keys and option values never change, so stored values remain valid in every language.
    func localizing(_ settings: [WebExtensionSettingDescriptor]) -> [WebExtensionSettingDescriptor] {
        settings.map { setting in
            guard let text = self.settings[setting.key] else { return setting }
            var localized = setting
            localized.title = text.title ?? setting.title
            localized.detail = text.detail ?? setting.detail
            localized.placeholder = text.placeholder ?? setting.placeholder
            localized.options = setting.options.map { option in
                WebExtensionSettingOption(value: option.value, title: text.options[option.value] ?? option.title)
            }
            return localized
        }
    }
}

enum WebExtensionLocalizationError: LocalizedError, Equatable {
    case invalidDefaultLanguage(String)
    case invalidTOML(line: Int, column: Int, reason: String)
    case invalidLanguage(String)
    case expectedTable(String)
    case expectedString(String)
    case unknownKey(String)
    case undeclaredSetting(String)
    case undeclaredOption(String)
    case optionsRequireChoice(String)
    case invalidMessageKey(String)
    case undeclaredMessage(String, defaultLanguage: String)

    var errorDescription: String? {
        switch self {
        case .invalidDefaultLanguage(let language):
            String(localized: "manifest.toml: The defaultLanguage “\(language)” is not a valid language tag. Use a tag such as en, zh-Hans, or pt-BR.")
        case .invalidTOML(let line, let column, let reason):
            String(localized: "i18n.toml is not valid TOML at line \(line), column \(column): \(reason)")
        case .invalidLanguage(let language):
            String(localized: "i18n.toml: “\(language)” is not a valid language tag. Use a tag such as en, zh-Hans, or pt-BR.")
        case .expectedTable(let path):
            String(localized: "i18n.toml: \(path) must be a table.")
        case .expectedString(let path):
            String(localized: "i18n.toml: \(path) must be a string.")
        case .unknownKey(let path):
            String(localized: "i18n.toml: \(path) is not a supported key.")
        case .undeclaredSetting(let path):
            String(localized: "i18n.toml: \(path) is not a setting declared in manifest.toml.")
        case .undeclaredOption(let path):
            String(localized: "i18n.toml: \(path) is not an option of the setting.")
        case .optionsRequireChoice(let path):
            String(localized: "i18n.toml: \(path) is only supported for choice settings.")
        case .invalidMessageKey(let path):
            String(localized: "i18n.toml: \(path) is not a valid message key. Keys start with a letter and contain only letters, digits, and underscores.")
        case .undeclaredMessage(let path, let language):
            String(localized: "i18n.toml: \(path) has no message in the default language, \(language).")
        }
    }
}

/// An extension's localizations: the language its manifest is written in, and the text that
/// `i18n.toml` provides for each language.
struct WebExtensionLocalization: Equatable, Sendable {
    static let filename = "i18n.toml"
    /// The language of the manifest's text when the manifest does not declare `defaultLanguage`.
    static let defaultManifestLanguage = "en"

    /// The language that the manifest's text is written in. Every other language falls back on it.
    let defaultLanguage: String
    /// The text that `i18n.toml` provides, keyed by language tag.
    let text: [String: WebExtensionLocalizedText]

    /// Reads and validates the package's `i18n.toml`. A package without one has only its default language.
    static func load(
        packageURL: URL,
        defaultLanguage: String,
        settings: [WebExtensionSettingDescriptor],
        fileManager: FileManager = .default
    ) throws -> WebExtensionLocalization {
        let fileURL = packageURL.appendingPathComponent(filename, isDirectory: false)
        let source = fileManager.fileExists(atPath: fileURL.path)
            ? try String(contentsOf: fileURL, encoding: .utf8)
            : ""
        return try WebExtensionLocalization(source: source, defaultLanguage: defaultLanguage, settings: settings)
    }

    /// Parses the contents of an `i18n.toml` file. Everything it localizes must be declared by the
    /// manifest's `settings`; every message must also exist in the default language.
    init(source: String, defaultLanguage: String, settings: [WebExtensionSettingDescriptor]) throws {
        guard Self.isLanguageTag(defaultLanguage) else {
            throw WebExtensionLocalizationError.invalidDefaultLanguage(defaultLanguage)
        }
        let table: TOMLTable
        do {
            table = try TOMLTable(string: source)
        } catch let error as TOMLParseError {
            throw WebExtensionLocalizationError.invalidTOML(
                line: error.source.begin.line,
                column: error.source.begin.column,
                reason: error.description
            )
        }

        let settingsByKey = Dictionary(settings.map { ($0.key, $0) }) { first, _ in first }
        var text: [String: WebExtensionLocalizedText] = [:]
        for language in table.keys.sorted() {
            guard Self.isLanguageTag(language) else {
                throw WebExtensionLocalizationError.invalidLanguage(language)
            }
            text[language] = try Self.text(
                in: Self.table(table[language], at: [language]),
                at: [language],
                settings: settingsByKey
            )
        }

        let declaredMessages = text[defaultLanguage]?.messages ?? [:]
        for language in text.keys.sorted() where language != defaultLanguage {
            let messages = text[language]?.messages ?? [:]
            if let key = messages.keys.sorted().first(where: { declaredMessages[$0] == nil }) {
                throw WebExtensionLocalizationError.undeclaredMessage(
                    Self.path([language, "messages", key]),
                    defaultLanguage: defaultLanguage
                )
            }
        }

        self.defaultLanguage = defaultLanguage
        self.text = text
    }

    /// The languages whose text applies for `preferredLanguages`, best first: the chosen language,
    /// then more general languages that it falls back on, such as `pt` for `pt-BR`.
    func languages(for preferredLanguages: [String]) -> [String] {
        let available = [defaultLanguage] + text.keys.filter { $0 != defaultLanguage }.sorted()
        let matches = Bundle.preferredLocalizations(from: available, forPreferences: preferredLanguages)
        // When no preference matches, Bundle chooses English if it is available and otherwise the
        // first language, which is the default language. Only a user who reads English gets English.
        guard let language = matches.first,
              language == defaultLanguage
                || !Self.isEnglish(language)
                || preferredLanguages.contains(where: Self.isEnglish) else {
            return [defaultLanguage]
        }
        return matches
    }

    /// The language to use for `preferredLanguages` and the text to show in it. Text that the language
    /// omits comes from the languages it falls back on, and finally from the default language.
    func resolved(for preferredLanguages: [String]) -> (language: String, text: WebExtensionLocalizedText) {
        let chain = languages(for: preferredLanguages)
        let resolvedText = ([defaultLanguage] + chain.reversed())
            .compactMap { text[$0] }
            .reduce(WebExtensionLocalizedText()) { $0.overlaid(by: $1) }
        return (chain.first ?? defaultLanguage, resolvedText)
    }

    /// Whether `tag` is a BCP 47 language tag in canonical case: a language, optionally followed by a
    /// script, a region, and variants, such as `en`, `zh-Hans`, `pt-BR`, or `es-419`.
    static func isLanguageTag(_ tag: String) -> Bool {
        tag.wholeMatch(
            of: #/[a-z]{2,3}(?:-[A-Z][a-z]{3})?(?:-(?:[A-Z]{2}|[0-9]{3}))?(?:-(?:[a-z0-9]{5,8}|[0-9][a-z0-9]{3}))*/#
        ) != nil
    }

    private static func isEnglish(_ language: String) -> Bool {
        Locale.Language(identifier: language).languageCode == .english
    }

    /// Message keys follow the rules for setting keys, so pages can use them as property names.
    private static func isMessageKey(_ key: String) -> Bool {
        key.wholeMatch(of: #/[A-Za-z][A-Za-z0-9_]*/#) != nil
    }

    private static func text(
        in table: TOMLTable,
        at path: [String],
        settings: [String: WebExtensionSettingDescriptor]
    ) throws -> WebExtensionLocalizedText {
        var text = WebExtensionLocalizedText()
        for key in table.keys.sorted() {
            let keyPath = path + [key]
            switch key {
            case "name":
                text.name = try string(table[key], at: keyPath)
            case "settings":
                let settingsTable = try self.table(table[key], at: keyPath)
                for settingKey in settingsTable.keys.sorted() {
                    let settingPath = keyPath + [settingKey]
                    guard let setting = settings[settingKey] else {
                        throw WebExtensionLocalizationError.undeclaredSetting(Self.path(settingPath))
                    }
                    text.settings[settingKey] = try settingText(
                        in: self.table(settingsTable[settingKey], at: settingPath),
                        at: settingPath,
                        setting: setting
                    )
                }
            case "messages":
                let messages = try self.table(table[key], at: keyPath)
                for messageKey in messages.keys.sorted() {
                    let messagePath = keyPath + [messageKey]
                    guard isMessageKey(messageKey) else {
                        throw WebExtensionLocalizationError.invalidMessageKey(Self.path(messagePath))
                    }
                    text.messages[messageKey] = try string(messages[messageKey], at: messagePath)
                }
            default:
                throw WebExtensionLocalizationError.unknownKey(Self.path(keyPath))
            }
        }
        return text
    }

    private static func settingText(
        in table: TOMLTable,
        at path: [String],
        setting: WebExtensionSettingDescriptor
    ) throws -> WebExtensionLocalizedText.Setting {
        var text = WebExtensionLocalizedText.Setting()
        for key in table.keys.sorted() {
            let keyPath = path + [key]
            switch key {
            case "title":
                text.title = try string(table[key], at: keyPath)
            case "description":
                text.detail = try string(table[key], at: keyPath)
            case "placeholder":
                text.placeholder = try string(table[key], at: keyPath)
            case "options":
                guard setting.type == .choice else {
                    throw WebExtensionLocalizationError.optionsRequireChoice(Self.path(keyPath))
                }
                let options = try self.table(table[key], at: keyPath)
                for value in options.keys.sorted() {
                    let optionPath = keyPath + [value]
                    guard setting.options.contains(where: { $0.value == value }) else {
                        throw WebExtensionLocalizationError.undeclaredOption(Self.path(optionPath))
                    }
                    text.options[value] = try string(options[value], at: optionPath)
                }
            default:
                throw WebExtensionLocalizationError.unknownKey(Self.path(keyPath))
            }
        }
        return text
    }

    private static func table(_ value: (any TOMLValueConvertible)?, at path: [String]) throws -> TOMLTable {
        guard let table = value?.table else {
            throw WebExtensionLocalizationError.expectedTable(Self.path(path))
        }
        return table
    }

    private static func string(_ value: (any TOMLValueConvertible)?, at path: [String]) throws -> String {
        guard let string = value?.string else {
            throw WebExtensionLocalizationError.expectedString(Self.path(path))
        }
        return string
    }

    /// A dotted key path as it could appear in the file, such as `zh-Hans.settings.language.options."Simplified Chinese"`.
    private static func path(_ keys: [String]) -> String {
        let bareKeyCharacters = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        return keys.map { key in
            guard key.isEmpty || !key.unicodeScalars.allSatisfy(bareKeyCharacters.contains) else { return key }
            let escaped = key
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }.joined(separator: ".")
    }
}
