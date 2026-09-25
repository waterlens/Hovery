import Foundation
import Network
import WebKit
import XCTest
@testable import Hovery

final class WebExtensionSettingsTests: XCTestCase {
    private enum TestTiming {
        static let renderTimeout: Duration = .seconds(10)
        static let pollInterval: Duration = .milliseconds(20)
    }

    private enum TestLayout {
        static let resultsFrame = CGRect(x: 0, y: 0, width: 520, height: 400)
    }

    private static let typedSettings = """
    [[settings]]
    key = "endpoint"
    title = "Endpoint"
    type = "url"
    default = "https://api.example.com/v1"
    description = "Service endpoint."
    required = true
    network = true

    [[settings]]
    key = "token"
    type = "secret"

    [[settings]]
    key = "model"
    type = "string"
    placeholder = "model-name"

    [[settings]]
    key = "prompt"
    type = "text"

    [[settings]]
    key = "stream"
    type = "boolean"
    default = true

    [[settings]]
    key = "timeout"
    type = "number"
    default = 30
    minimum = 5
    maximum = 300.5

    [[settings]]
    key = "language"
    type = "choice"
    options = ["English", { value = "zh-Hans", title = "Simplified Chinese" }]
    """

    private static let autoTranslatorPackageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Examples/AutoTranslator/Extension/AutoTranslator.hoveryextension", isDirectory: true)

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoverySettingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testManifestDeclaresTypedSettings() throws {
        let package = try makePackage(in: temporaryDirectory, settings: Self.typedSettings)
        let settings = try WebExtensionCatalog.load(packageURL: package).settings

        XCTAssertEqual(settings.map(\.key), ["endpoint", "token", "model", "prompt", "stream", "timeout", "language"])
        XCTAssertEqual(settings.map(\.type), [.url, .secret, .string, .text, .boolean, .number, .choice])

        let endpoint = settings[0]
        XCTAssertEqual(endpoint.title, "Endpoint")
        XCTAssertEqual(endpoint.detail, "Service endpoint.")
        XCTAssertEqual(endpoint.defaultValue, .string("https://api.example.com/v1"))
        XCTAssertTrue(endpoint.isRequired)
        XCTAssertTrue(endpoint.grantsNetworkAccess)

        XCTAssertEqual(settings[1].title, "token")
        XCTAssertEqual(settings[1].defaultValue, .string(""))
        XCTAssertEqual(settings[2].placeholder, "model-name")
        XCTAssertEqual(settings[4].defaultValue, .boolean(true))
        XCTAssertEqual(settings[5].defaultValue, .number(30))
        XCTAssertEqual(settings[5].minimum, 5)
        XCTAssertEqual(settings[5].maximum, 300.5)
        XCTAssertEqual(settings[6].options, [
            WebExtensionSettingOption(value: "English", title: "English"),
            WebExtensionSettingOption(value: "zh-Hans", title: "Simplified Chinese")
        ])
        XCTAssertEqual(settings[6].defaultValue, .string("English"))
    }

    func testManifestRejectsInvalidSettings() throws {
        let cases: [(settings: String, reason: String)] = [
            ("key = \"1st\"\ntype = \"string\"", "Keys must start with a letter"),
            ("key = \"a\"\ntype = \"string\"\n\n[[settings]]\nkey = \"a\"\ntype = \"text\"", "more than once"),
            ("key = \"a\"\ntype = \"color\"", "Unsupported type"),
            ("key = \"a\"\ntype = \"string\"\nnetwork = true", "Only url settings"),
            ("key = \"a\"\ntype = \"string\"\noptions = [\"x\"]", "Only choice settings"),
            ("key = \"a\"\ntype = \"string\"\nminimum = 1", "Only number settings"),
            ("key = \"a\"\ntype = \"secret\"\ndefault = \"hunter2\"", "Secret settings cannot"),
            ("key = \"a\"\ntype = \"choice\"", "at least one option"),
            ("key = \"a\"\ntype = \"choice\"\noptions = [\"x\", \"x\"]", "must be unique"),
            ("key = \"a\"\ntype = \"choice\"\noptions = [\"x\"]\ndefault = \"y\"", "not one of the options"),
            ("key = \"a\"\ntype = \"number\"\nminimum = 10\ndefault = 5", "outside the allowed range"),
            ("key = \"a\"\ntype = \"number\"\nminimum = 10\nmaximum = 5", "greater than the maximum"),
            ("key = \"a\"\ntype = \"number\"\nminimum = \"low\"", "minimum must be a number"),
            ("key = \"a\"\ntype = \"boolean\"\ndefault = \"yes\"", "does not match"),
            ("key = \"a\"\ntype = \"url\"\ndefault = \"api.example.com\"", "not an http")
        ]

        for (index, testCase) in cases.enumerated() {
            let directory = temporaryDirectory.appendingPathComponent("case-\(index)", isDirectory: true)
            let package = try makePackage(in: directory, settings: "[[settings]]\n\(testCase.settings)")
            XCTAssertThrowsError(try WebExtensionCatalog.load(packageURL: package), testCase.reason) { error in
                guard case WebExtensionManifestError.invalidSetting(_, let reason) = error else {
                    return XCTFail("Unexpected error for \(testCase.reason): \(error)")
                }
                XCTAssertTrue(reason.contains(testCase.reason), "\(reason) does not mention \(testCase.reason)")
            }
        }
    }

    func testResolvedSettingsApplyDefaultsStoredValuesSecretsAndNetworkGrants() throws {
        let package = try makePackage(in: temporaryDirectory, settings: Self.typedSettings)
        let descriptors = try WebExtensionCatalog.load(packageURL: package).settings

        let resolved = WebExtensionResolvedSettings(
            descriptors: descriptors,
            storedValues: [
                "endpoint": .string(" http://localhost:11434/v1 "),
                "stream": .string("yes"),
                "timeout": .number(900),
                "language": .string("fr"),
                "unknown": .string("ignored")
            ],
            secrets: ["token": " secret\n"]
        )
        XCTAssertEqual(resolved.values["endpoint"], .string("http://localhost:11434/v1"))
        XCTAssertEqual(resolved.values["token"], .string("secret"))
        XCTAssertEqual(resolved.values["model"], .string(""))
        XCTAssertEqual(resolved.values["stream"], .boolean(true))
        XCTAssertEqual(resolved.values["timeout"], .number(300.5))
        XCTAssertEqual(resolved.values["language"], .string("English"))
        XCTAssertNil(resolved.values["unknown"])
        XCTAssertEqual(resolved.networkOrigins, ["http://localhost:11434"])
        XCTAssertEqual(resolved.missingRequiredKeys, [])

        let unusable = WebExtensionResolvedSettings(
            descriptors: descriptors,
            storedValues: ["endpoint": .string("not a URL")],
            secrets: [:]
        )
        XCTAssertEqual(unusable.networkOrigins, [])
        XCTAssertEqual(unusable.missingRequiredKeys, ["endpoint"])

        let overrides = WebExtensionSettingDescriptor.storedOverrides(for: descriptors, values: [
            "endpoint": .string("https://api.example.com/v1"),
            "token": .string("secret"),
            "model": .string(" gpt "),
            "prompt": .string("  Keep spacing.  "),
            "stream": .boolean(true),
            "timeout": .number(1)
        ])
        XCTAssertEqual(overrides, [
            "model": .string("gpt"),
            "prompt": .string("  Keep spacing.  "),
            "timeout": .number(5)
        ])
    }

    func testRestoringDefaultsKeepsSecretsAndRequiredSettings() throws {
        let package = try makePackage(in: temporaryDirectory, settings: Self.typedSettings)
        let descriptors = try WebExtensionCatalog.load(packageURL: package).settings
        let restored = WebExtensionSettingDescriptor.restoringDefaults(for: descriptors, values: [
            "endpoint": .string("http://localhost:11434/v1"),
            "token": .string("secret"),
            "model": .string("gpt"),
            "prompt": .string("Be brief."),
            "stream": .boolean(false),
            "timeout": .number(60),
            "language": .string("zh-Hans")
        ])
        XCTAssertEqual(restored, [
            "endpoint": .string("http://localhost:11434/v1"),
            "token": .string("secret"),
            "model": .string(""),
            "prompt": .string(""),
            "stream": .boolean(true),
            "timeout": .number(30),
            "language": .string("English")
        ])

        let translator = try WebExtensionCatalog.load(packageURL: Self.autoTranslatorPackageURL).settings
        let restoredTranslator = WebExtensionSettingDescriptor.restoringDefaults(for: translator, values: [
            "baseURL": .string("https://api.deepseek.com"),
            "apiKey": .string("sk-test"),
            "model": .string("deepseek-chat"),
            "targetLanguage": .string("Japanese"),
            "timeout": .number(90)
        ])
        XCTAssertEqual(restoredTranslator["baseURL"], .string("https://api.deepseek.com"))
        XCTAssertEqual(restoredTranslator["apiKey"], .string("sk-test"))
        XCTAssertEqual(restoredTranslator["model"], .string("deepseek-chat"))
        XCTAssertEqual(restoredTranslator["targetLanguage"], .string("Simplified Chinese"))
        XCTAssertEqual(restoredTranslator["timeout"], .number(30))
    }

    func testNetworkOriginsKeepOnlySchemeHostAndPort() throws {
        func origin(_ value: String) -> String? {
            URLComponents(string: value).flatMap(WebExtensionNetworkOrigin.origin(of:))
        }

        XCTAssertEqual(origin("HTTPS://user:password@API.Example.com:8443/v1?q=1#top"), "https://api.example.com:8443")
        XCTAssertEqual(origin("http://[::1]:11434/v1"), "http://[::1]:11434")
        XCTAssertEqual(origin("wss://example.com/socket"), "wss://example.com")
        XCTAssertNil(origin("ftp://example.com"))
        XCTAssertNil(origin("https://"))
        XCTAssertNil(origin("api.example.com/v1"))
    }

    @MainActor
    func testExtensionSettingsRoundTripThroughTOML() throws {
        let settings = HoverySettings(configurationURL: temporaryDirectory.appendingPathComponent("config.toml"))
        var configuration = WebExtensionConfiguration()
        configuration.settings = [
            "org.example.translator": [
                "baseURL": .string("https://api.example.com/v1"),
                "instructions": .string("Line one\nLine \"two\"\t\\ end ✓\u{1}"),
                "stream": .boolean(false),
                "timeout": .number(42.5)
            ],
            "plain": ["key-with-dash": .string("value")]
        ]
        let text = HoverySettings.serializedExtensions(configuration)
        XCTAssertTrue(text.contains("[settings.\"org.example.translator\"]"))
        XCTAssertTrue(text.contains("[settings.plain]"))
        XCTAssertTrue(text.contains(#"instructions = "Line one\nLine \"two\"\t\\ end ✓\u0001""#))

        try text.write(to: settings.extensionConfigurationURL, atomically: true, encoding: .utf8)
        settings.reload()
        XCTAssertEqual(settings.extensionConfiguration.settings, configuration.settings)

        try """
        directory = "Extensions"

        [settings."org.example.translator"]
        timeout = 30
        unsupported = [1, 2]
        model = "m"
        """.write(to: settings.extensionConfigurationURL, atomically: true, encoding: .utf8)
        settings.reload()
        XCTAssertEqual(
            settings.extensionConfiguration.settings,
            ["org.example.translator": ["timeout": .number(30), "model": .string("m")]]
        )
    }

    @MainActor
    func testCoordinatorSavesSettingsAndKeepsSecretsOutOfTOML() throws {
        let identifier = "org.example.configurable"
        let settings = HoverySettings(configurationURL: temporaryDirectory.appendingPathComponent("config.toml"))
        try makePackage(
            in: settings.extensionsDirectoryURL,
            settings: """
            [[settings]]
            key = "endpoint"
            title = "Endpoint"
            type = "url"
            default = "https://api.example.com/v1"
            required = true
            network = true

            [[settings]]
            key = "token"
            title = "Token"
            type = "secret"

            [[settings]]
            key = "model"
            title = "Model"
            type = "string"
            required = true

            [[settings]]
            key = "timeout"
            type = "number"
            default = 30
            minimum = 5
            maximum = 300
            """
        )
        let secrets = InMemoryWebExtensionSecretStore()
        let manager = WebExtensionCoordinator(settings: settings, secretStore: secrets)

        var status = try XCTUnwrap(manager.extensions.first)
        XCTAssertEqual(status.settings.map(\.key), ["endpoint", "token", "model", "timeout"])
        XCTAssertEqual(status.missingRequiredSettings, ["Model"])
        XCTAssertEqual(manager.settingsForm(for: identifier)?.values["endpoint"], .string("https://api.example.com/v1"))

        var requestedIdentifier: String?
        manager.settingsRequestHandler = { requestedIdentifier = $0 }
        manager.requestSettings(for: identifier)
        XCTAssertEqual(requestedIdentifier, identifier)

        try manager.saveSettings([
            "endpoint": .string("http://127.0.0.1:8080/v1"),
            "token": .string(" sk-test\n"),
            "model": .string("gpt-test"),
            "timeout": .number(500)
        ], for: identifier)

        let secretKey = WebExtensionSecretKey(extensionIdentifier: identifier, settingKey: "token")
        XCTAssertEqual(secrets.secret(for: secretKey), "sk-test")
        XCTAssertEqual(settings.extensionConfiguration.settings[identifier], [
            "endpoint": .string("http://127.0.0.1:8080/v1"),
            "model": .string("gpt-test"),
            "timeout": .number(300)
        ])
        let persisted = try String(contentsOf: settings.extensionConfigurationURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("[settings.\"\(identifier)\"]"))
        XCTAssertTrue(persisted.contains("model = \"gpt-test\""))
        XCTAssertFalse(persisted.contains("sk-test"))
        status = try XCTUnwrap(manager.extensions.first)
        XCTAssertEqual(status.missingRequiredSettings, [])
        XCTAssertEqual(manager.settingsForm(for: identifier)?.values["token"], .string("sk-test"))

        let form = try XCTUnwrap(manager.settingsForm(for: identifier))
        var values = form.values
        values["token"] = .string("")
        try manager.saveSettings(values, for: identifier)
        XCTAssertNil(secrets.secret(for: secretKey))
        XCTAssertEqual(manager.settingsForm(for: identifier)?.values["token"], .string(""))

        values["endpoint"] = .string("https://api.example.com/v1")
        values["model"] = .string("")
        values["timeout"] = .number(30)
        try manager.saveSettings(values, for: identifier)
        XCTAssertNil(settings.extensionConfiguration.settings[identifier])
        XCTAssertEqual(try XCTUnwrap(manager.extensions.first).missingRequiredSettings, ["Model"])

        XCTAssertThrowsError(try manager.saveSettings([:], for: "org.example.missing"))
    }

    @MainActor
    func testWebExtensionReceivesSettingsAndGrantedNetworkOrigins() async throws {
        let package = try makePackage(
            in: temporaryDirectory,
            settings: Self.typedSettings,
            script: """
            let mounted
            export function mount({ settings }) {
              mounted = settings
            }
            export function present({ root, settings }) {
              root.textContent = JSON.stringify({
                settings,
                sameAsMount: settings === mounted,
                frozen: Object.isFrozen(settings),
                policy: document.querySelector('meta[http-equiv="Content-Security-Policy"]').content
              })
            }
            """
        )
        let descriptor = try WebExtensionCatalog.load(packageURL: package)
        let runtime = WebExtensionRuntimeController(
            descriptor: descriptor,
            settings: WebExtensionResolvedSettings(
                descriptors: descriptor.settings,
                storedValues: [
                    "endpoint": .string("http://localhost:11434/v1"),
                    "stream": .boolean(false),
                    "timeout": .number(12.5)
                ],
                secrets: ["token": "secret"]
            )
        )
        runtime.present(request: ["id": UUID().uuidString, "input": ["text": "settings"]])
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        let rendered = try await waitForText(in: webView, containing: "policy")
        runtime.unmount()
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        let values = try XCTUnwrap(payload["settings"] as? [String: Any])
        XCTAssertEqual(values["endpoint"] as? String, "http://localhost:11434/v1")
        XCTAssertEqual(values["token"] as? String, "secret")
        XCTAssertEqual(values["model"] as? String, "")
        XCTAssertEqual(values["stream"] as? Bool, false)
        XCTAssertEqual(values["timeout"] as? Double, 12.5)
        XCTAssertEqual(values["language"] as? String, "English")
        XCTAssertEqual(payload["sameAsMount"] as? Bool, true)
        XCTAssertEqual(payload["frozen"] as? Bool, true)
        let policy = try XCTUnwrap(payload["policy"] as? String)
        XCTAssertTrue(
            policy.contains("connect-src 'self' https://manifest.example.com http://localhost:11434"),
            policy
        )
    }

    @MainActor
    func testAutoTranslatorTranslatesThroughConfiguredService() async throws {
        let server = try MockChatCompletionsServer { request in
            let messages = request.json?["messages"] as? [[String: Any]]
            if messages?.last?["content"] as? String == "Unauthorized text" {
                return .json(status: 401, body: #"{"error":{"message":"Incorrect API key provided."}}"#)
            }
            return .stream(["你好", "，", "世界"])
        }
        let port = try await server.start()
        defer { server.stop() }

        let descriptor = try WebExtensionCatalog.load(packageURL: Self.autoTranslatorPackageURL)
        let settings = WebExtensionResolvedSettings(
            descriptors: descriptor.settings,
            storedValues: [
                "baseURL": .string("http://127.0.0.1:\(port)/v1"),
                "model": .string("test-model")
            ],
            secrets: ["apiKey": "test-key"]
        )
        XCTAssertEqual(settings.networkOrigins, ["http://127.0.0.1:\(port)"])
        XCTAssertEqual(settings.missingRequiredKeys, [])

        let runtime = WebExtensionRuntimeController(descriptor: descriptor, settings: settings)
        defer { runtime.unmount() }
        // innerText omits clipped text, so lay the page out at the results panel's width.
        runtime.view.frame = TestLayout.resultsFrame
        runtime.present(request: translatorRequest(text: "Hello, world"))
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        let translated = try await waitForText(in: webView, containing: "你好，世界")
        XCTAssertTrue(translated.contains("Hello, world"), translated)
        XCTAssertTrue(translated.contains("test-model"), translated)
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.path, "/v1/chat/completions")
        XCTAssertEqual(request.headers["authorization"], "Bearer test-key")
        XCTAssertEqual(request.json?["model"] as? String, "test-model")
        XCTAssertEqual(request.json?["stream"] as? Bool, true)
        let messages = try XCTUnwrap(request.json?["messages"] as? [[String: Any]])
        XCTAssertTrue((messages.first?["content"] as? String)?.contains("Simplified Chinese") == true)
        XCTAssertEqual(messages.last?["content"] as? String, "Hello, world")

        runtime.present(request: translatorRequest(text: "Unauthorized text"))
        let failure = try await waitForText(in: webView, containing: "Incorrect API key provided.")
        XCTAssertTrue(failure.contains("Couldn’t Translate"))
        XCTAssertTrue(failure.contains("Check the API key"))
    }

    @MainActor
    func testAutoTranslatorAsksForSetupWithoutAModel() async throws {
        let descriptor = try WebExtensionCatalog.load(packageURL: Self.autoTranslatorPackageURL)
        let runtime = WebExtensionRuntimeController(descriptor: descriptor)
        defer { runtime.unmount() }
        XCTAssertEqual(runtime.settings.missingRequiredKeys, ["model"])

        runtime.view.frame = TestLayout.resultsFrame
        runtime.present(request: translatorRequest(text: "Hello"))
        let webView = try XCTUnwrap(runtime.view as? WKWebView)
        let rendered = try await waitForText(in: webView, containing: "Click the gear button above")
        XCTAssertTrue(rendered.contains("enter the Model"))
    }

    @discardableResult
    private func makePackage(
        in directory: URL,
        settings: String,
        script: String = "export function present() {}"
    ) throws -> URL {
        let package = directory.appendingPathComponent("Configurable.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.configurable"
        name = "Configurable"

        [view]
        document = "web/index.html"
        module = "web/main.js"

        [permissions]
        network = ["https://manifest.example.com"]

        \(settings)
        """.write(to: package.appendingPathComponent("manifest.toml"), atomically: true, encoding: .utf8)
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try script.write(to: web.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        return package
    }

    private func translatorRequest(text: String) -> [String: Any] {
        let id = UUID().uuidString
        let selection: [String: Any] = ["id": "\(id)-sentence", "level": "sentence", "text": text]
        return ["id": id, "input": selection, "selections": ["sentence": selection]]
    }

    @MainActor
    private func waitForText(in webView: WKWebView, containing expected: String) async throws -> String {
        let deadline = ContinuousClock.now + TestTiming.renderTimeout
        var text = ""
        while ContinuousClock.now < deadline {
            text = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String ?? ""
            if text.contains(expected) { return text }
            try await Task.sleep(for: TestTiming.pollInterval)
        }
        XCTFail("Timed out waiting for “\(expected)”. Rendered: \(text)")
        return text
    }
}

/// A loopback HTTP server that answers CORS preflights and Chat Completions requests.
private final class MockChatCompletionsServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        var json: [String: Any]? {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        }
    }

    enum Reply: Sendable {
        case stream([String])
        case json(status: Int, body: String)
    }

    private static let chunkInterval: DispatchTimeInterval = .milliseconds(15)

    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.hovery.tests.mock-chat-completions")
    private let reply: @Sendable (Request) -> Reply
    private let lock = NSLock()
    private var recordedRequests: [Request] = []
    private var readiness: CheckedContinuation<UInt16, any Error>?

    init(reply: @escaping @Sendable (Request) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.reply = reply
    }

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { readiness = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                self?.listenerStateDidChange(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func listenerStateDidChange(_ state: NWListener.State) {
        let result: Result<UInt16, any Error>
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else { return }
            result = .success(port)
        case .failed(let error):
            result = .failure(error)
        case .cancelled:
            result = .failure(CancellationError())
        default:
            return
        }
        let continuation = lock.withLock {
            let continuation = readiness
            readiness = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffered = buffered
            if let data {
                buffered.append(data)
            }
            if let request = Self.parse(buffered) {
                respond(to: request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                receive(on: connection, buffered: buffered)
            }
        }
    }

    private static func parse(_ data: Data) -> Request? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let body = data[headerEnd.upperBound...]
        guard body.count >= length else { return nil }
        return Request(
            method: String(requestLine[0]),
            path: String(requestLine[1]),
            headers: headers,
            body: Data(body.prefix(length))
        )
    }

    private func respond(to request: Request, on connection: NWConnection) {
        let cors = [
            "Access-Control-Allow-Origin: \(request.headers["origin"] ?? "*")",
            "Access-Control-Allow-Headers: authorization, content-type",
            "Access-Control-Allow-Methods: POST, OPTIONS"
        ]
        guard request.method == "POST" else {
            send([Self.head(status: 204, headers: cors + ["Content-Length: 0"])], on: connection)
            return
        }
        lock.withLock { recordedRequests.append(request) }

        switch reply(request) {
        case .stream(let deltas):
            let events = deltas.map { delta -> Data in
                let event = ["choices": [["delta": ["content": delta]]]]
                let json = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
                return Data("data: ".utf8) + json + Data("\n\n".utf8)
            }
            send(
                [Self.head(status: 200, headers: cors + ["Content-Type: text/event-stream", "Cache-Control: no-cache"])]
                    + events
                    + [Data("data: [DONE]\n\n".utf8)],
                on: connection
            )
        case .json(let status, let body):
            let data = Data(body.utf8)
            send(
                [
                    Self.head(
                        status: status,
                        headers: cors + ["Content-Type: application/json", "Content-Length: \(data.count)"]
                    ),
                    data
                ],
                on: connection
            )
        }
    }

    private static func head(status: Int, headers: [String]) -> Data {
        let lines = ["HTTP/1.1 \(status) Mock", "Connection: close"] + headers + ["", ""]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// Sends each part separately so that streamed responses arrive incrementally.
    private func send(_ parts: [Data], on connection: NWConnection) {
        guard let part = parts.first else {
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in connection.cancel() }
            )
            return
        }
        connection.send(content: part, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            queue.asyncAfter(deadline: .now() + Self.chunkInterval) {
                self.send(Array(parts.dropFirst()), on: connection)
            }
        })
    }
}
