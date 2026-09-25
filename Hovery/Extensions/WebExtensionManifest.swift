import Foundation
import TOMLKit

enum WebExtensionInputLevel: String, Codable, CaseIterable, Sendable {
    case word
    case sentence
    case paragraph
    case block

    var semanticLevel: SemanticLevel {
        switch self {
        case .word: .word
        case .sentence: .sentence
        case .paragraph: .paragraph
        case .block: .block
        }
    }
}

struct WebExtensionDescriptor: Equatable, Sendable {
    let identifier: String
    let name: String
    let preferredInput: WebExtensionInputLevel
    let order: Int
    let packageURL: URL
    let documentPath: String
    let modulePath: String
    let allowedNetworkOrigins: [String]
    let allowedCapabilities: [String]
    let allowsSelectionOverlay: Bool
    let nativeHost: WebExtensionNativeDescriptor?
    let settings: [WebExtensionSettingDescriptor]
}

struct WebExtensionNativeDescriptor: Equatable, Sendable {
    static let supportedProtocol = "json-lines-v1"

    let executablePath: String
    let communicationProtocol: String
}

struct WebExtensionCatalogEntry: Sendable {
    let packageURL: URL
    let descriptor: WebExtensionDescriptor?
    let errorDescription: String?
}

enum WebExtensionManifestError: LocalizedError {
    case missingManifest(URL)
    case invalidIdentifier(String)
    case unsafeResourcePath(String)
    case missingResource(String)
    case invalidNetworkOrigin(String)
    case unsupportedNativeProtocol(String)
    case invalidSetting(key: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .missingManifest(let url):
            "Missing extension manifest at \(url.path)"
        case .invalidIdentifier(let identifier):
            "Invalid extension identifier: \(identifier)"
        case .unsafeResourcePath(let path):
            "Extension resource must stay inside its package: \(path)"
        case .missingResource(let path):
            "Extension resource does not exist: \(path)"
        case .invalidNetworkOrigin(let origin):
            "Invalid extension network origin: \(origin)"
        case .unsupportedNativeProtocol(let value):
            "Unsupported native extension protocol: \(value)"
        case .invalidSetting(let key, let reason):
            "Invalid extension setting \(key): \(reason)"
        }
    }
}

struct WebExtensionCatalog {
    private struct Manifest: Decodable {
        struct Metadata: Decodable {
            let id: String
            let name: String
            let input: WebExtensionInputLevel
            let order: Int

            private enum CodingKeys: String, CodingKey {
                case id
                case name
                case input
                case order
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                name = try container.decode(String.self, forKey: .name)
                input = try container.decodeIfPresent(WebExtensionInputLevel.self, forKey: .input) ?? .word
                order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
            }
        }

        struct View: Decodable {
            let document: String
            let module: String
        }

        struct Permissions: Decodable {
            let network: [String]
            let capabilities: [String]
            let selectionOverlay: Bool

            private enum CodingKeys: String, CodingKey {
                case network
                case capabilities
                case selectionOverlay
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                network = try container.decodeIfPresent([String].self, forKey: .network) ?? []
                capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
                selectionOverlay = try container.decodeIfPresent(Bool.self, forKey: .selectionOverlay) ?? false
            }

            init(network: [String], capabilities: [String], selectionOverlay: Bool = false) {
                self.network = network
                self.capabilities = capabilities
                self.selectionOverlay = selectionOverlay
            }
        }

        struct Native: Decodable {
            let executable: String
            let communicationProtocol: String

            private enum CodingKeys: String, CodingKey {
                case executable
                case communicationProtocol = "protocol"
            }
        }

        struct Setting: Decodable {
            struct Option: Decodable {
                let value: String
                let title: String

                private enum CodingKeys: String, CodingKey {
                    case value
                    case title
                }

                init(from decoder: Decoder) throws {
                    if let value = try? decoder.singleValueContainer().decode(String.self) {
                        self.value = value
                        title = value
                        return
                    }
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    value = try container.decode(String.self, forKey: .value)
                    title = try container.decodeIfPresent(String.self, forKey: .title) ?? value
                }
            }

            let key: String
            let title: String?
            let type: String
            let detail: String?
            let placeholder: String?
            let defaultValue: WebExtensionSettingValue?
            let required: Bool
            let network: Bool
            let minimum: WebExtensionSettingValue?
            let maximum: WebExtensionSettingValue?
            let options: [Option]

            private enum CodingKeys: String, CodingKey {
                case key
                case title
                case type
                case detail = "description"
                case placeholder
                case defaultValue = "default"
                case required
                case network
                case minimum
                case maximum
                case options
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                key = try container.decode(String.self, forKey: .key)
                title = try container.decodeIfPresent(String.self, forKey: .title)
                type = try container.decode(String.self, forKey: .type)
                detail = try container.decodeIfPresent(String.self, forKey: .detail)
                placeholder = try container.decodeIfPresent(String.self, forKey: .placeholder)
                defaultValue = try container.decodeIfPresent(
                    WebExtensionSettingValue.self,
                    forKey: .defaultValue
                )
                required = try container.decodeIfPresent(Bool.self, forKey: .required) ?? false
                network = try container.decodeIfPresent(Bool.self, forKey: .network) ?? false
                minimum = try container.decodeIfPresent(WebExtensionSettingValue.self, forKey: .minimum)
                maximum = try container.decodeIfPresent(WebExtensionSettingValue.self, forKey: .maximum)
                options = try container.decodeIfPresent([Option].self, forKey: .options) ?? []
            }
        }

        let metadata: Metadata
        let view: View
        let permissions: Permissions
        let native: Native?
        let settings: [Setting]

        private enum CodingKeys: String, CodingKey {
            case metadata = "extension"
            case view
            case permissions
            case native
            case settings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            metadata = try container.decode(Metadata.self, forKey: .metadata)
            view = try container.decode(View.self, forKey: .view)
            permissions = try container.decodeIfPresent(Permissions.self, forKey: .permissions)
                ?? Permissions(network: [], capabilities: [], selectionOverlay: false)
            native = try container.decodeIfPresent(Native.self, forKey: .native)
            settings = try container.decodeIfPresent([Setting].self, forKey: .settings) ?? []
        }
    }

    static let packageExtension = "hoveryextension"
    static let manifestFilename = "manifest.toml"

    static func discover(
        in directoryURL: URL,
        fileManager: FileManager = .default,
        onFailure: ((URL, any Error) -> Void)? = nil
    ) throws -> [WebExtensionDescriptor] {
        try inspect(in: directoryURL, fileManager: fileManager).compactMap { entry in
            if let errorDescription = entry.errorDescription {
                onFailure?(
                    entry.packageURL,
                    NSError(
                        domain: "WebExtensionCatalog",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: errorDescription]
                    )
                )
            }
            return entry.descriptor
        }.sorted {
            if $0.order != $1.order { return $0.order > $1.order }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func inspect(
        in directoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> [WebExtensionCatalogEntry] {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let packageURLs = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var entries: [WebExtensionCatalogEntry] = []
        for packageURL in packageURLs where packageURL.pathExtension == packageExtension {
            do {
                let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey])
                guard values.isDirectory == true else { continue }
                entries.append(WebExtensionCatalogEntry(
                    packageURL: packageURL,
                    descriptor: try load(packageURL: packageURL, fileManager: fileManager),
                    errorDescription: nil
                ))
            } catch {
                entries.append(WebExtensionCatalogEntry(
                    packageURL: packageURL,
                    descriptor: nil,
                    errorDescription: error.localizedDescription
                ))
            }
        }
        return entries.sorted {
            let left = $0.descriptor?.name ?? $0.packageURL.deletingPathExtension().lastPathComponent
            let right = $1.descriptor?.name ?? $1.packageURL.deletingPathExtension().lastPathComponent
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    static func load(
        packageURL: URL,
        fileManager: FileManager = .default
    ) throws -> WebExtensionDescriptor {
        let manifestURL = packageURL.appendingPathComponent(manifestFilename, isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw WebExtensionManifestError.missingManifest(manifestURL)
        }

        let source = try String(contentsOf: manifestURL, encoding: .utf8)
        let table = try TOMLTable(string: source)
        let manifest = try TOMLDecoder().decode(Manifest.self, from: table)

        guard isValidIdentifier(manifest.metadata.id) else {
            throw WebExtensionManifestError.invalidIdentifier(manifest.metadata.id)
        }

        try validateResource(
            manifest.view.document,
            packageURL: packageURL,
            fileManager: fileManager
        )
        try validateResource(
            manifest.view.module,
            packageURL: packageURL,
            fileManager: fileManager
        )
        if let native = manifest.native {
            try validateResource(
                native.executable,
                packageURL: packageURL,
                fileManager: fileManager
            )
            guard native.communicationProtocol == WebExtensionNativeDescriptor.supportedProtocol else {
                throw WebExtensionManifestError.unsupportedNativeProtocol(native.communicationProtocol)
            }
        }

        let origins = try manifest.permissions.network.map(validateNetworkOrigin)
        let settings = try settingDescriptors(from: manifest.settings)
        return WebExtensionDescriptor(
            identifier: manifest.metadata.id,
            name: manifest.metadata.name,
            preferredInput: manifest.metadata.input,
            order: manifest.metadata.order,
            packageURL: packageURL.resolvingSymlinksInPath(),
            documentPath: manifest.view.document,
            modulePath: manifest.view.module,
            allowedNetworkOrigins: origins,
            allowedCapabilities: Array(Set(manifest.permissions.capabilities)).sorted(),
            allowsSelectionOverlay: manifest.permissions.selectionOverlay,
            nativeHost: manifest.native.map {
                WebExtensionNativeDescriptor(
                    executablePath: $0.executable,
                    communicationProtocol: $0.communicationProtocol
                )
            },
            settings: settings
        )
    }

    private static func isValidIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty, identifier == identifier.lowercased() else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        return identifier.unicodeScalars.allSatisfy(allowed.contains)
            && !identifier.hasPrefix(".")
            && !identifier.hasSuffix(".")
            && !identifier.contains("..")
    }

    private static func validateResource(
        _ path: String,
        packageURL: URL,
        fileManager: FileManager
    ) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw WebExtensionManifestError.unsafeResourcePath(path)
        }
        let packageRoot = packageURL.resolvingSymlinksInPath().standardizedFileURL
        let resourceURL = packageRoot
            .appendingPathComponent(path, isDirectory: false)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootPrefix = packageRoot.path.hasSuffix("/") ? packageRoot.path : packageRoot.path + "/"
        guard resourceURL.path.hasPrefix(rootPrefix) else {
            throw WebExtensionManifestError.unsafeResourcePath(path)
        }
        guard fileManager.fileExists(atPath: resourceURL.path) else {
            throw WebExtensionManifestError.missingResource(path)
        }
    }

    private static func validateNetworkOrigin(_ origin: String) throws -> String {
        guard let components = URLComponents(string: origin),
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil,
              let value = WebExtensionNetworkOrigin.origin(of: components) else {
            throw WebExtensionManifestError.invalidNetworkOrigin(origin)
        }
        return value
    }

    private static func settingDescriptors(
        from settings: [Manifest.Setting]
    ) throws -> [WebExtensionSettingDescriptor] {
        var keys = Set<String>()
        return try settings.map { setting in
            let key = setting.key
            func invalid(_ reason: String) -> WebExtensionManifestError {
                .invalidSetting(key: key, reason: reason)
            }

            guard isValidSettingKey(key) else {
                throw invalid("Keys must start with a letter and contain only letters, digits, and underscores.")
            }
            guard keys.insert(key).inserted else {
                throw invalid("The key is declared more than once.")
            }
            guard let type = WebExtensionSettingType(rawValue: setting.type) else {
                throw invalid("Unsupported type \"\(setting.type)\".")
            }
            guard !setting.network || type == .url else {
                throw invalid("Only url settings can grant network access.")
            }
            guard setting.options.isEmpty || type == .choice else {
                throw invalid("Only choice settings can declare options.")
            }
            guard (setting.minimum == nil && setting.maximum == nil) || type == .number else {
                throw invalid("Only number settings can declare a minimum or maximum.")
            }
            let minimum = try setting.minimum.map { value in
                guard let number = value.numberValue, number.isFinite else {
                    throw invalid("The minimum must be a number.")
                }
                return number
            }
            let maximum = try setting.maximum.map { value in
                guard let number = value.numberValue, number.isFinite else {
                    throw invalid("The maximum must be a number.")
                }
                return number
            }
            if let minimum, let maximum, minimum > maximum {
                throw invalid("The minimum is greater than the maximum.")
            }
            let options = setting.options.map {
                WebExtensionSettingOption(value: $0.value, title: $0.title)
            }
            if type == .choice {
                guard !options.isEmpty else {
                    throw invalid("A choice needs at least one option.")
                }
                guard Set(options.map(\.value)).count == options.count else {
                    throw invalid("Choice option values must be unique.")
                }
            }

            let defaultValue: WebExtensionSettingValue
            switch (type, setting.defaultValue) {
            case (.secret, nil):
                defaultValue = .string("")
            case (.secret, _?):
                throw invalid("Secret settings cannot declare a default value.")
            case (.string, nil), (.text, nil), (.url, nil):
                defaultValue = .string("")
            case (.string, .string(let text)?), (.text, .string(let text)?):
                defaultValue = .string(text)
            case (.url, .string(let text)?):
                guard text.isEmpty
                    || URLComponents(string: text).flatMap(WebExtensionNetworkOrigin.origin(of:)) != nil else {
                    throw invalid("The default value is not an http, https, ws, or wss URL.")
                }
                defaultValue = .string(text)
            case (.boolean, nil):
                defaultValue = .boolean(false)
            case (.boolean, .boolean(let flag)?):
                defaultValue = .boolean(flag)
            case (.number, nil):
                defaultValue = .number(min(max(0, minimum ?? -.infinity), maximum ?? .infinity))
            case (.number, .number(let number)?):
                guard number.isFinite,
                      number >= minimum ?? -.infinity,
                      number <= maximum ?? .infinity else {
                    throw invalid("The default value is outside the allowed range.")
                }
                defaultValue = .number(number)
            case (.choice, nil):
                defaultValue = .string(options[0].value)
            case (.choice, .string(let choice)?):
                guard options.contains(where: { $0.value == choice }) else {
                    throw invalid("The default value is not one of the options.")
                }
                defaultValue = .string(choice)
            default:
                throw invalid("The default value does not match the \(type.rawValue) type.")
            }

            return WebExtensionSettingDescriptor(
                key: key,
                title: setting.title ?? key,
                type: type,
                detail: setting.detail,
                placeholder: setting.placeholder,
                defaultValue: defaultValue,
                isRequired: setting.required,
                grantsNetworkAccess: setting.network,
                minimum: minimum,
                maximum: maximum,
                options: options
            )
        }
    }

    private static func isValidSettingKey(_ key: String) -> Bool {
        let letters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let allowed = letters.union(CharacterSet(charactersIn: "0123456789_"))
        guard let first = key.unicodeScalars.first, letters.contains(first) else { return false }
        return key.unicodeScalars.allSatisfy(allowed.contains)
    }
}
