import Foundation
import OSLog
import Security

enum WebExtensionSettingType: String, CaseIterable, Sendable {
    case string
    case text
    case secret
    case url
    case boolean
    case number
    case choice
}

enum WebExtensionSettingValue: Equatable, Sendable {
    case string(String)
    case boolean(Bool)
    case number(Double)

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var booleanValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    var scriptValue: Any {
        switch self {
        case .string(let value): value
        case .boolean(let value): value
        case .number(let value): value
        }
    }
}

extension WebExtensionSettingValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            // TOML integers are not implicitly decoded as floating-point values.
            self = .number(Double(try container.decode(Int.self)))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }
}

struct WebExtensionSettingOption: Equatable, Identifiable, Sendable {
    let value: String
    let title: String

    var id: String { value }
}

struct WebExtensionSettingDescriptor: Equatable, Identifiable, Sendable {
    let key: String
    let title: String
    let type: WebExtensionSettingType
    let detail: String?
    let placeholder: String?
    let defaultValue: WebExtensionSettingValue
    let isRequired: Bool
    let grantsNetworkAccess: Bool
    let minimum: Double?
    let maximum: Double?
    let options: [WebExtensionSettingOption]

    var id: String { key }

    /// Coerces a stored or edited value to this setting's type, falling back to the default
    /// when the value has the wrong type or is not one of the declared choices.
    func normalized(_ value: WebExtensionSettingValue?) -> WebExtensionSettingValue {
        switch (type, value) {
        case (.string, .string(let text)?), (.url, .string(let text)?), (.secret, .string(let text)?):
            return .string(text.trimmingCharacters(in: .whitespacesAndNewlines))
        case (.text, .string(let text)?):
            return .string(text)
        case (.boolean, .boolean(let flag)?):
            return .boolean(flag)
        case (.number, .number(let number)?) where number.isFinite:
            return .number(min(max(number, minimum ?? -.infinity), maximum ?? .infinity))
        case (.choice, .string(let choice)?) where options.contains(where: { $0.value == choice }):
            return .string(choice)
        default:
            return defaultValue
        }
    }

    /// Whether `value` can satisfy this setting when the manifest marks it as required.
    func isSatisfied(by value: WebExtensionSettingValue) -> Bool {
        switch type {
        case .string, .text, .secret:
            !(value.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .url:
            networkOrigin(for: value) != nil
        case .boolean, .number, .choice:
            true
        }
    }

    /// The origin of a URL setting's value, or `nil` when the value is not a usable URL.
    func networkOrigin(for value: WebExtensionSettingValue) -> String? {
        guard type == .url,
              let text = value.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: text) else { return nil }
        return WebExtensionNetworkOrigin.origin(of: components)
    }

    /// Restoring defaults resets preferences but keeps what the user had to provide:
    /// secrets and required settings, such as a service's endpoint and model.
    static func restoringDefaults(
        for descriptors: [WebExtensionSettingDescriptor],
        values: [String: WebExtensionSettingValue]
    ) -> [String: WebExtensionSettingValue] {
        var restored = values
        for descriptor in descriptors where descriptor.type != .secret && !descriptor.isRequired {
            restored[descriptor.key] = descriptor.defaultValue
        }
        return restored
    }

    /// Values that differ from their defaults, which is all that is written to `extensions.toml`.
    /// Secrets are never included; they belong to a `WebExtensionSecretStoring`.
    static func storedOverrides(
        for descriptors: [WebExtensionSettingDescriptor],
        values: [String: WebExtensionSettingValue]
    ) -> [String: WebExtensionSettingValue] {
        descriptors.reduce(into: [:]) { overrides, descriptor in
            guard descriptor.type != .secret, let value = values[descriptor.key] else { return }
            let normalized = descriptor.normalized(value)
            if normalized != descriptor.defaultValue {
                overrides[descriptor.key] = normalized
            }
        }
    }
}

/// The settings an extension receives, together with the host permissions they imply.
struct WebExtensionResolvedSettings: Equatable, Sendable {
    let values: [String: WebExtensionSettingValue]
    let networkOrigins: [String]
    let missingRequiredKeys: [String]

    init(
        descriptors: [WebExtensionSettingDescriptor],
        storedValues: [String: WebExtensionSettingValue],
        secrets: [String: String]
    ) {
        var values: [String: WebExtensionSettingValue] = [:]
        var networkOrigins: [String] = []
        var missingRequiredKeys: [String] = []
        for descriptor in descriptors {
            let value = descriptor.type == .secret
                ? descriptor.normalized(.string(secrets[descriptor.key] ?? ""))
                : descriptor.normalized(storedValues[descriptor.key])
            values[descriptor.key] = value
            if descriptor.isRequired, !descriptor.isSatisfied(by: value) {
                missingRequiredKeys.append(descriptor.key)
            }
            if descriptor.grantsNetworkAccess,
               let origin = descriptor.networkOrigin(for: value),
               !networkOrigins.contains(origin) {
                networkOrigins.append(origin)
            }
        }
        self.values = values
        self.networkOrigins = networkOrigins
        self.missingRequiredKeys = missingRequiredKeys
    }

    var scriptValues: [String: Any] {
        values.mapValues(\.scriptValue)
    }
}

enum WebExtensionNetworkOrigin {
    static let schemes: Set<String> = ["https", "http", "wss", "ws"]

    private static let hostCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-[]:"
    )

    /// Returns `scheme://host[:port]`, which is also a valid CSP source expression.
    /// Credentials, paths, queries, and fragments are discarded.
    static func origin(of components: URLComponents) -> String? {
        guard let scheme = components.scheme?.lowercased(),
              schemes.contains(scheme),
              let host = components.percentEncodedHost?.lowercased(),
              !host.isEmpty else { return nil }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.percentEncodedHost = host
        origin.port = components.port
        guard let value = origin.string,
              let hostAndPort = value.components(separatedBy: "://").last,
              !hostAndPort.isEmpty,
              hostAndPort.unicodeScalars.allSatisfy(hostCharacters.contains) else { return nil }
        return value
    }
}

struct WebExtensionSecretKey: Hashable, Sendable {
    let extensionIdentifier: String
    let settingKey: String

    var account: String {
        "\(extensionIdentifier)/\(settingKey)"
    }
}

@MainActor
protocol WebExtensionSecretStoring: AnyObject {
    func secret(for key: WebExtensionSecretKey) -> String?
    /// Stores `value`, or removes the secret when `value` is `nil`.
    func setSecret(_ value: String?, for key: WebExtensionSecretKey, label: String) throws
}

enum WebExtensionSecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "The Keychain could not store the secret: \(SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)")"
        }
    }
}

/// Stores secret extension settings as generic passwords in the user's login Keychain.
@MainActor
final class KeychainWebExtensionSecretStore: WebExtensionSecretStoring {
    private enum Keychain {
        static let service = "app.hovery.Hovery.extension-settings"
    }

    private let logger = Logger(subsystem: "app.hovery.Hovery", category: "ExtensionSecrets")
    private var cachedSecrets: [WebExtensionSecretKey: String] = [:]
    private var knownMissingSecrets = Set<WebExtensionSecretKey>()

    func secret(for key: WebExtensionSecretKey) -> String? {
        if let secret = cachedSecrets[key] { return secret }
        if knownMissingSecrets.contains(key) { return nil }

        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            if status != errSecItemNotFound {
                logger.error("Could not read an extension secret: \(Self.message(for: status), privacy: .public)")
            }
            knownMissingSecrets.insert(key)
            return nil
        }
        cachedSecrets[key] = secret
        return secret
    }

    func setSecret(_ value: String?, for key: WebExtensionSecretKey, label: String) throws {
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw WebExtensionSecretStoreError.keychain(status)
            }
            cachedSecrets.removeValue(forKey: key)
            knownMissingSecrets.insert(key)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrLabel as String: label
        ]
        var status = SecItemUpdate(baseQuery(for: key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(
                baseQuery(for: key).merging(attributes) { _, new in new } as CFDictionary,
                nil
            )
        }
        guard status == errSecSuccess else {
            throw WebExtensionSecretStoreError.keychain(status)
        }
        cachedSecrets[key] = value
        knownMissingSecrets.remove(key)
    }

    private func baseQuery(for key: WebExtensionSecretKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Keychain.service,
            kSecAttrAccount as String: key.account
        ]
    }

    private static func message(for status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
    }
}

@MainActor
final class InMemoryWebExtensionSecretStore: WebExtensionSecretStoring {
    private(set) var secrets: [WebExtensionSecretKey: String]

    init(secrets: [WebExtensionSecretKey: String] = [:]) {
        self.secrets = secrets
    }

    func secret(for key: WebExtensionSecretKey) -> String? {
        secrets[key]
    }

    func setSecret(_ value: String?, for key: WebExtensionSecretKey, label: String) throws {
        if let value, !value.isEmpty {
            secrets[key] = value
        } else {
            secrets.removeValue(forKey: key)
        }
    }
}
