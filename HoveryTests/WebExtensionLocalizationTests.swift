import Foundation
import WebKit
import XCTest
@testable import Hovery

/// Every test chooses its languages explicitly, so none depends on the language of the machine.
final class WebExtensionLocalizationTests: XCTestCase {
    private enum TestTiming {
        static let renderTimeout: Duration = .seconds(10)
        static let pollInterval: Duration = .milliseconds(20)
    }

    private enum TestLayout {
        static let resultsFrame = CGRect(x: 0, y: 0, width: 520, height: 400)
    }

    private static let identifier = "org.example.localized"

    private static let settings = """
    [[settings]]
    key = "model"
    title = "Model"
    type = "string"
    description = "The model to use."
    placeholder = "model-name"

    [[settings]]
    key = "language"
    title = "Language"
    type = "choice"
    options = [{ value = "Simplified Chinese", title = "Simplified Chinese" }, "English"]
    """

    private static let localizations = """
    [en.messages]
    greeting = "Hello, {name}"
    farewell = "Goodbye"

    [zh-Hans]
    name = "本地化示例"

    [zh-Hans.settings.model]
    title = "模型"
    description = "要使用的模型。"
    placeholder = "模型名称"

    [zh-Hans.settings.language]
    title = "语言"
    options = { "Simplified Chinese" = "简体中文", English = "英语" }

    [zh-Hans.messages]
    greeting = "你好，{name}"
    """

    private static let examplesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Examples", isDirectory: true)
    private static let autoTranslatorPackageURL = examplesURL
        .appendingPathComponent("AutoTranslator/Extension/AutoTranslator.hoveryextension", isDirectory: true)
    private static let appleDictionaryPackageURL = examplesURL
        .appendingPathComponent("AppleDictionary/Extension/AppleDictionary.hoveryextension", isDirectory: true)
    private static let streamingEchoPackageURL = examplesURL
        .appendingPathComponent("StreamingEcho/Extension/StreamingEcho.hoveryextension", isDirectory: true)

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryLocalizationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    // MARK: - Parsing and validation

    func testParsesLanguagesSettingsAndMessages() throws {
        let localization = try WebExtensionLocalization(
            source: Self.localizations,
            defaultLanguage: "en",
            settings: settingDescriptors()
        )

        XCTAssertEqual(localization.defaultLanguage, "en")
        XCTAssertEqual(Set(localization.text.keys), ["en", "zh-Hans"])
        XCTAssertEqual(
            localization.text["en"],
            WebExtensionLocalizedText(messages: ["greeting": "Hello, {name}", "farewell": "Goodbye"])
        )
        let chinese = try XCTUnwrap(localization.text["zh-Hans"])
        XCTAssertEqual(chinese.name, "本地化示例")
        XCTAssertEqual(
            chinese.settings["model"],
            .init(title: "模型", detail: "要使用的模型。", placeholder: "模型名称")
        )
        XCTAssertEqual(
            chinese.settings["language"],
            .init(title: "语言", options: ["Simplified Chinese": "简体中文", "English": "英语"])
        )
        XCTAssertEqual(chinese.messages, ["greeting": "你好，{name}"])

        let empty = try WebExtensionLocalization(source: "", defaultLanguage: "en", settings: [])
        XCTAssertEqual(empty.text, [:])
    }

    func testRejectsInvalidLocalizations() throws {
        let cases: [(source: String, error: WebExtensionLocalizationError)] = [
            ("en = \"English\"", .expectedTable("en")),
            ("[[en]]\nname = \"English\"", .expectedTable("en")),
            ("[english]\nname = \"English\"", .invalidLanguage("english")),
            ("[zh_Hans]\nname = \"中文\"", .invalidLanguage("zh_Hans")),
            ("[zh-hans]\nname = \"中文\"", .invalidLanguage("zh-hans")),
            ("[\"zh Hans\"]\nname = \"中文\"", .invalidLanguage("zh Hans")),
            ("[zh-Hans]\ntitle = \"中文\"", .unknownKey("zh-Hans.title")),
            ("[zh-Hans]\nname = 1", .expectedString("zh-Hans.name")),
            ("[zh-Hans]\nsettings = \"模型\"", .expectedTable("zh-Hans.settings")),
            ("[zh-Hans]\nmessages = [\"你好\"]", .expectedTable("zh-Hans.messages")),
            ("[zh-Hans.settings]\nmodel = \"模型\"", .expectedTable("zh-Hans.settings.model")),
            ("[zh-Hans.settings.endpoint]\ntitle = \"地址\"", .undeclaredSetting("zh-Hans.settings.endpoint")),
            ("[zh-Hans.settings.model]\nlabel = \"模型\"", .unknownKey("zh-Hans.settings.model.label")),
            ("[zh-Hans.settings.model]\ntitle = true", .expectedString("zh-Hans.settings.model.title")),
            ("[zh-Hans.settings.model]\ndescription = 2.5", .expectedString("zh-Hans.settings.model.description")),
            ("[zh-Hans.settings.model]\nplaceholder = []", .expectedString("zh-Hans.settings.model.placeholder")),
            (
                "[zh-Hans.settings.model]\noptions = { English = \"英语\" }",
                .optionsRequireChoice("zh-Hans.settings.model.options")
            ),
            (
                "[zh-Hans.settings.language]\noptions = [\"英语\"]",
                .expectedTable("zh-Hans.settings.language.options")
            ),
            (
                "[zh-Hans.settings.language.options]\nKlingon = \"克林贡语\"",
                .undeclaredOption("zh-Hans.settings.language.options.Klingon")
            ),
            (
                "[zh-Hans.settings.language.options]\n\"Simplified Chinese\" = 1",
                .expectedString("zh-Hans.settings.language.options.\"Simplified Chinese\"")
            ),
            ("[en.messages]\ngreeting = 1", .expectedString("en.messages.greeting")),
            ("[en.messages.errors]\ntimeout = \"Timed out\"", .expectedString("en.messages.errors")),
            ("[en.messages]\n\"copy-text\" = \"Copy\"", .invalidMessageKey("en.messages.copy-text")),
            ("[en.messages]\n\"1st\" = \"First\"", .invalidMessageKey("en.messages.1st")),
            (
                "[en.messages]\ngreeting = \"Hello\"\n\n[zh-Hans.messages]\ngreeting = \"你好\"\nfarewel = \"再见\"",
                .undeclaredMessage("zh-Hans.messages.farewel", defaultLanguage: "en")
            )
        ]

        for (index, testCase) in cases.enumerated() {
            let package = try makePackage(
                in: temporaryDirectory.appendingPathComponent("case-\(index)", isDirectory: true),
                settings: Self.settings,
                localizations: testCase.source
            )
            XCTAssertThrowsError(
                try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["en"]),
                testCase.source
            ) { error in
                XCTAssertEqual(error as? WebExtensionLocalizationError, testCase.error, testCase.source)
            }
        }
    }

    func testRejectsMalformedTOMLAndInvalidDefaultLanguages() throws {
        let malformed = try makePackage(
            in: temporaryDirectory.appendingPathComponent("malformed", isDirectory: true),
            localizations: "[en.messages]\ngreeting = \"Hello\nfarewell = \"Goodbye\""
        )
        XCTAssertThrowsError(try WebExtensionCatalog.load(packageURL: malformed, preferredLanguages: ["en"])) { error in
            guard case WebExtensionLocalizationError.invalidTOML(let line, _, let reason)? =
                    error as? WebExtensionLocalizationError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(line, 2)
            XCTAssertFalse(reason.isEmpty)
            XCTAssertTrue(error.localizedDescription.contains(reason), error.localizedDescription)
        }

        for language in ["english", "EN", "zh-hans", "zh_CN", "", "en-"] {
            let package = try makePackage(
                in: temporaryDirectory.appendingPathComponent("default-\(UUID().uuidString)", isDirectory: true),
                defaultLanguage: language
            )
            XCTAssertThrowsError(try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["en"])) { error in
                XCTAssertEqual(error as? WebExtensionLocalizationError, .invalidDefaultLanguage(language))
            }
        }
        for language in ["en", "zh-Hans", "pt-BR", "es-419", "zh-Hant-HK", "de-CH-1901", "sr-Latn"] {
            XCTAssertTrue(WebExtensionLocalization.isLanguageTag(language), language)
        }
    }

    func testCatalogReportsInvalidLocalizationsAsLoadErrors() throws {
        try makePackage(
            in: temporaryDirectory,
            settings: Self.settings,
            localizations: "[zh-Hans.settings.missing]\ntitle = \"缺失\""
        )
        let entry = try XCTUnwrap(
            WebExtensionCatalog.inspect(in: temporaryDirectory, preferredLanguages: ["en"]).first
        )

        XCTAssertNil(entry.descriptor)
        XCTAssertEqual(
            entry.errorDescription,
            WebExtensionLocalizationError.undeclaredSetting("zh-Hans.settings.missing").localizedDescription
        )
    }

    // MARK: - Language resolution

    func testChoosesTheLanguageThatBestMatchesThePreferences() throws {
        let localization = try WebExtensionLocalization(
            source: "[en.messages]\ngreeting = \"Hello\"\n\n[zh-Hans.messages]\ngreeting = \"你好\"",
            defaultLanguage: "en",
            settings: []
        )
        let cases: [(preferences: [String], language: String)] = [
            (["zh-Hans-CN"], "zh-Hans"),
            (["zh-CN"], "zh-Hans"),
            (["en-US"], "en"),
            (["en-CN", "zh-Hans-CN"], "en"),
            (["zh-Hans-CN", "en-CN"], "zh-Hans"),
            (["ja"], "en"),
            (["ja", "zh-Hans-CN"], "zh-Hans"),
            (["zh-Hant-TW"], "en"),
            ([], "en")
        ]
        for testCase in cases {
            let resolved = localization.resolved(for: testCase.preferences)
            XCTAssertEqual(resolved.language, testCase.language, "\(testCase.preferences)")
            XCTAssertEqual(
                resolved.text.messages["greeting"],
                testCase.language == "en" ? "Hello" : "你好",
                "\(testCase.preferences)"
            )
        }
    }

    func testFallsBackToADefaultLanguageOtherThanEnglish() throws {
        let localization = try WebExtensionLocalization(
            source: """
            [zh-Hans.messages]
            greeting = "你好"

            [en.messages]
            greeting = "Hello"

            [ja.messages]
            greeting = "こんにちは"
            """,
            defaultLanguage: "zh-Hans",
            settings: []
        )
        let cases: [(preferences: [String], language: String)] = [
            (["ja-JP"], "ja"),
            (["en-US"], "en"),
            // Bundle chooses English when nothing matches, but these users did not ask for English.
            (["fr-FR"], "zh-Hans"),
            (["de", "ko"], "zh-Hans"),
            ([], "zh-Hans"),
            (["fr", "en-GB"], "en"),
            (["zh-Hans-CN", "en-US"], "zh-Hans")
        ]
        for testCase in cases {
            XCTAssertEqual(
                localization.resolved(for: testCase.preferences).language,
                testCase.language,
                "\(testCase.preferences)"
            )
        }
    }

    func testRegionalLanguagesFallBackToTheirBaseLanguage() throws {
        let localization = try WebExtensionLocalization(
            source: """
            [en.messages]
            color = "Color"
            ok = "OK"
            cancel = "Cancel"

            [pt.messages]
            color = "Cor"
            ok = "OK"

            [pt-BR.messages]
            ok = "Certo"
            """,
            defaultLanguage: "en",
            settings: []
        )

        XCTAssertEqual(localization.languages(for: ["pt-BR"]), ["pt-BR", "pt"])
        let brazilian = localization.resolved(for: ["pt-BR"])
        XCTAssertEqual(brazilian.language, "pt-BR")
        XCTAssertEqual(brazilian.text.messages, ["color": "Cor", "ok": "Certo", "cancel": "Cancel"])

        let portuguese = localization.resolved(for: ["pt-PT"])
        XCTAssertEqual(portuguese.language, "pt")
        XCTAssertEqual(portuguese.text.messages, ["color": "Cor", "ok": "OK", "cancel": "Cancel"])
    }

    // MARK: - Descriptors and messages

    func testLocalizesTheDescriptorWithoutChangingKeysOrValues() throws {
        let package = try makePackage(in: temporaryDirectory, settings: Self.settings, localizations: Self.localizations)
        let chinese = try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["zh-Hans-CN"])
        let english = try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["en-US"])

        XCTAssertEqual(chinese.language, "zh-Hans")
        XCTAssertEqual(chinese.name, "本地化示例")
        XCTAssertEqual(chinese.settings.map(\.title), ["模型", "语言"])
        XCTAssertEqual(chinese.settings[0].detail, "要使用的模型。")
        XCTAssertEqual(chinese.settings[0].placeholder, "模型名称")
        XCTAssertEqual(chinese.settings[1].options, [
            WebExtensionSettingOption(value: "Simplified Chinese", title: "简体中文"),
            WebExtensionSettingOption(value: "English", title: "英语")
        ])

        XCTAssertEqual(english.language, "en")
        XCTAssertEqual(english.name, "Localized")
        XCTAssertEqual(english.settings.map(\.title), ["Model", "Language"])
        XCTAssertEqual(english.settings[0].detail, "The model to use.")
        XCTAssertEqual(english.settings[0].placeholder, "model-name")
        XCTAssertEqual(english.settings[1].options.map(\.title), ["Simplified Chinese", "English"])

        // Only text changes, so values stored in extensions.toml stay valid in every language.
        XCTAssertEqual(chinese.identifier, english.identifier)
        XCTAssertEqual(chinese.settings.map(\.key), english.settings.map(\.key))
        XCTAssertEqual(chinese.settings.map(\.defaultValue), english.settings.map(\.defaultValue))
        XCTAssertEqual(chinese.settings[1].options.map(\.value), english.settings[1].options.map(\.value))
        XCTAssertEqual(
            WebExtensionResolvedSettings(
                descriptors: chinese.settings,
                storedValues: ["language": .string("English")],
                secrets: [:]
            ).values["language"],
            .string("English")
        )
    }

    func testMessagesFallBackToTheDefaultLanguage() throws {
        let package = try makePackage(in: temporaryDirectory, settings: Self.settings, localizations: Self.localizations)

        XCTAssertEqual(
            try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["zh-Hans"]).messages,
            ["greeting": "你好，{name}", "farewell": "Goodbye"]
        )
        XCTAssertEqual(
            try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["ja"]).messages,
            ["greeting": "Hello, {name}", "farewell": "Goodbye"]
        )

        let unlocalized = try WebExtensionCatalog.load(
            packageURL: makePackage(
                in: temporaryDirectory.appendingPathComponent("unlocalized", isDirectory: true),
                settings: Self.settings
            ),
            preferredLanguages: ["zh-Hans"]
        )
        XCTAssertEqual(unlocalized.language, "en")
        XCTAssertEqual(unlocalized.name, "Localized")
        XCTAssertEqual(unlocalized.messages, [:])
    }

    func testManifestCanBeWrittenInAnotherDefaultLanguage() throws {
        let package = try makePackage(
            in: temporaryDirectory,
            name: "本地化示例",
            defaultLanguage: "zh-Hans",
            settings: """
            [[settings]]
            key = "model"
            title = "模型"
            type = "string"
            """,
            localizations: """
            [zh-Hans.messages]
            greeting = "你好"
            farewell = "再见"

            [en]
            name = "Localized"

            [en.settings.model]
            title = "Model"

            [en.messages]
            greeting = "Hello"
            """
        )

        let fallback = try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["ja"])
        XCTAssertEqual(fallback.language, "zh-Hans")
        XCTAssertEqual(fallback.name, "本地化示例")
        XCTAssertEqual(fallback.settings.map(\.title), ["模型"])
        XCTAssertEqual(fallback.messages, ["greeting": "你好", "farewell": "再见"])

        let english = try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["en-GB"])
        XCTAssertEqual(english.language, "en")
        XCTAssertEqual(english.name, "Localized")
        XCTAssertEqual(english.settings.map(\.title), ["Model"])
        XCTAssertEqual(english.messages, ["greeting": "Hello", "farewell": "再见"])
    }

    // MARK: - Pages

    @MainActor
    func testPageReceivesItsLanguageAndMessages() async throws {
        let package = try makePackage(
            in: temporaryDirectory,
            settings: Self.settings,
            localizations: Self.localizations,
            script: """
            let mounted
            export function mount({ extension }) {
              mounted = { extension, documentLanguage: document.documentElement.lang }
            }
            export function present({ root, extension }) {
              root.textContent = JSON.stringify({
                name: extension.name,
                language: extension.language,
                messages: extension.messages,
                documentLanguage: mounted.documentLanguage,
                sameAsMount: extension === mounted.extension,
                frozen: Object.isFrozen(extension) && Object.isFrozen(extension.messages)
              })
            }
            """
        )
        let descriptor = try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["zh-Hans-CN"])
        let runtime = WebExtensionRuntimeController(descriptor: descriptor)
        defer { runtime.unmount() }
        runtime.present(request: ["id": UUID().uuidString, "input": ["text": "language"]])
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        let rendered = try await waitForText(in: webView, containing: "documentLanguage")
        let payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(rendered.utf8)) as? [String: Any]
        )
        XCTAssertEqual(payload["name"] as? String, "本地化示例")
        XCTAssertEqual(payload["language"] as? String, "zh-Hans")
        XCTAssertEqual(payload["messages"] as? [String: String], ["greeting": "你好，{name}", "farewell": "Goodbye"])
        XCTAssertEqual(payload["documentLanguage"] as? String, "zh-Hans")
        XCTAssertEqual(payload["sameAsMount"] as? Bool, true)
        XCTAssertEqual(payload["frozen"] as? Bool, true)
    }

    @MainActor
    func testAutoTranslatorShowsChineseText() async throws {
        let server = try MockChatCompletionsServer { request in
            let messages = request.json?["messages"] as? [[String: Any]]
            if messages?.last?["content"] as? String == "Unauthorized text" {
                return .json(status: 401, body: #"{"error":{"message":"Incorrect API key provided."}}"#)
            }
            return .stream(["你好", "，", "世界"])
        }
        let port = try await server.start()
        defer { server.stop() }

        let descriptor = try WebExtensionCatalog.load(
            packageURL: Self.autoTranslatorPackageURL,
            preferredLanguages: ["zh-Hans-CN"]
        )
        XCTAssertEqual(descriptor.name, "自动翻译")
        let runtime = WebExtensionRuntimeController(
            descriptor: descriptor,
            settings: WebExtensionResolvedSettings(
                descriptors: descriptor.settings,
                storedValues: [
                    "baseURL": .string("http://127.0.0.1:\(port)/v1"),
                    "model": .string("test-model")
                ],
                secrets: ["apiKey": "test-key"]
            )
        )
        defer { runtime.unmount() }
        runtime.view.frame = TestLayout.resultsFrame
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        runtime.present(request: translatorRequest(text: "Hello, world"))
        _ = try await waitForText(in: webView, containing: "你好，世界")
        let titles = try await buttonTitles(in: webView)
        let documentLanguage = try await webView.evaluateJavaScript("document.documentElement.lang") as? String
        XCTAssertEqual(titles, ["拷贝原文", "拷贝译文"])
        XCTAssertEqual(documentLanguage, "zh-Hans")

        runtime.present(request: translatorRequest(text: "Unauthorized text"))
        let failure = try await waitForText(in: webView, containing: "无法翻译")
        XCTAssertTrue(failure.contains("Incorrect API key provided."), failure)
        XCTAssertTrue(failure.contains("请在“自动翻译”设置中检查 API 密钥。"), failure)
        // The prompt stays English for the model; only the text shown to the user is localized.
        let prompt = try XCTUnwrap(server.requests.first?.json?["messages"] as? [[String: Any]])
        XCTAssertTrue((prompt.first?["content"] as? String)?.contains("Translate the user's message") == true)
    }

    @MainActor
    func testAutoTranslatorAsksForSetupInTheChosenLanguage() async throws {
        let cases: [(preferences: [String], setup: String, name: String, button: String)] = [
            (["zh-Hans"], "点按上方的齿轮按钮，然后输入“模型”以开始翻译。", "自动翻译", "拷贝原文"),
            (["en"], "Click the gear button above and enter the Model to start translating.", "Auto Translator", "Copy Original")
        ]
        for testCase in cases {
            let descriptor = try WebExtensionCatalog.load(
                packageURL: Self.autoTranslatorPackageURL,
                preferredLanguages: testCase.preferences
            )
            let runtime = WebExtensionRuntimeController(descriptor: descriptor)
            defer { runtime.unmount() }
            runtime.view.frame = TestLayout.resultsFrame
            runtime.present(request: translatorRequest(text: "Hello"))
            let webView = try XCTUnwrap(runtime.view as? WKWebView)

            let rendered = try await waitForText(in: webView, containing: testCase.setup)
            let titles = try await buttonTitles(in: webView)
            let documentLanguage = try await webView.evaluateJavaScript("document.documentElement.lang") as? String
            XCTAssertTrue(rendered.contains(testCase.name), rendered)
            XCTAssertEqual(titles, [testCase.button])
            XCTAssertEqual(documentLanguage, testCase.preferences[0])
        }
    }

    @MainActor
    func testAppleDictionaryDescribesAMissInChinese() async throws {
        // The helper may not be built; the page only needs the executable to exist.
        let package = temporaryDirectory.appendingPathComponent("AppleDictionary.hoveryextension", isDirectory: true)
        try FileManager.default.copyItem(at: Self.appleDictionaryPackageURL, to: package)
        let helper = package.appendingPathComponent("native/AppleDictionaryHelper")
        if !FileManager.default.fileExists(atPath: helper.path) {
            try FileManager.default.createDirectory(
                at: helper.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data().write(to: helper)
        }
        let descriptor = try WebExtensionCatalog.load(packageURL: package, preferredLanguages: ["zh-Hans-CN"])
        XCTAssertEqual(descriptor.name, "Apple 词典")

        let dictionary = GatedDictionaryMiss()
        defer { dictionary.release() }
        let runtime = WebExtensionRuntimeController(descriptor: descriptor, nativeInvoker: dictionary)
        defer { runtime.unmount() }
        runtime.view.frame = TestLayout.resultsFrame
        let word: [String: Any] = ["id": "word", "level": "word", "text": "qxzv"]
        runtime.present(request: ["id": UUID().uuidString, "input": word, "selections": ["word": word]])
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        _ = try await waitForText(in: webView, containing: "正在查询“qxzv”…")
        dictionary.release()
        let miss = try await waitForText(in: webView, containing: "未找到释义。")
        XCTAssertTrue(miss.contains("qxzv"), miss)
    }

    @MainActor
    func testStreamingEchoLabelsFollowTheLanguage() async throws {
        let cases: [(preferences: [String], labels: [String])] = [
            (["zh-Hans"], ["段落", "句子", "单词", "不可用"]),
            (["en"], ["Paragraph", "Sentence", "Word", "Not available"])
        ]
        for testCase in cases {
            let descriptor = try WebExtensionCatalog.load(
                packageURL: Self.streamingEchoPackageURL,
                preferredLanguages: testCase.preferences
            )
            let runtime = WebExtensionRuntimeController(descriptor: descriptor)
            defer { runtime.unmount() }
            runtime.view.frame = TestLayout.resultsFrame
            let word: [String: Any] = ["id": "word", "level": "word", "text": "echo"]
            let sentence: [String: Any] = ["id": "sentence", "level": "sentence", "text": "An echo."]
            runtime.present(request: [
                "id": UUID().uuidString,
                "input": word,
                "selections": ["word": word, "sentence": sentence]
            ])
            let webView = try XCTUnwrap(runtime.view as? WKWebView)

            let rendered = try await waitForText(in: webView, containing: "An echo.")
            for label in testCase.labels {
                // The headings are uppercased by the page's style.
                XCTAssertTrue(rendered.localizedCaseInsensitiveContains(label), "\(label) is missing from \(rendered)")
            }
        }
    }

    // MARK: - Coordinator

    @MainActor
    func testExtensionsWindowShowsLocalizedTextAndStoresOptionValues() throws {
        let settings = HoverySettings(configurationURL: temporaryDirectory.appendingPathComponent("config.toml"))
        let identifier = "org.hovery.example.auto-translator"
        try FileManager.default.createDirectory(at: settings.extensionsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.autoTranslatorPackageURL,
            to: settings.extensionsDirectoryURL.appendingPathComponent("AutoTranslator.hoveryextension")
        )

        let chinese = WebExtensionCoordinator(
            settings: settings,
            secretStore: InMemoryWebExtensionSecretStore(),
            preferredLanguages: ["zh-Hans-CN"]
        )
        let status = try XCTUnwrap(chinese.extensions.first)
        XCTAssertEqual(status.name, "自动翻译")
        XCTAssertEqual(status.missingRequiredSettings, ["模型"])
        let form = try XCTUnwrap(chinese.settingsForm(for: identifier))
        XCTAssertEqual(form.name, "自动翻译")
        let targetLanguage = try XCTUnwrap(form.descriptors.first { $0.key == "targetLanguage" })
        XCTAssertEqual(targetLanguage.title, "目标语言")
        XCTAssertEqual(targetLanguage.options.first { $0.value == "Japanese" }?.title, "日语")

        var values = form.values
        values["targetLanguage"] = .string("Japanese")
        try chinese.saveSettings(values, for: identifier)
        XCTAssertEqual(settings.extensionConfiguration.settings[identifier]?["targetLanguage"], .string("Japanese"))
        let persisted = try String(contentsOf: settings.extensionConfigurationURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("targetLanguage = \"Japanese\""), persisted)

        let english = WebExtensionCoordinator(
            settings: settings,
            secretStore: InMemoryWebExtensionSecretStore(),
            preferredLanguages: ["en-US"]
        )
        let englishForm = try XCTUnwrap(english.settingsForm(for: identifier))
        XCTAssertEqual(english.extensions.first?.name, "Auto Translator")
        XCTAssertEqual(englishForm.values["targetLanguage"], .string("Japanese"))
        XCTAssertEqual(englishForm.descriptors.first { $0.key == "targetLanguage" }?.title, "Translate Into")
    }

    @MainActor
    func testExtensionsWindowShowsLocalizationErrors() throws {
        let settings = HoverySettings(configurationURL: temporaryDirectory.appendingPathComponent("config.toml"))
        try makePackage(
            in: settings.extensionsDirectoryURL,
            settings: Self.settings,
            localizations: "[zh-Hans.settings.language.options]\nKlingon = \"克林贡语\""
        )

        let manager = WebExtensionCoordinator(
            settings: settings,
            secretStore: InMemoryWebExtensionSecretStore(),
            preferredLanguages: ["en"]
        )
        let status = try XCTUnwrap(manager.extensions.first)
        XCTAssertNil(status.identifier)
        XCTAssertFalse(manager.hasExtensions)
        XCTAssertEqual(
            status.errorDescription,
            WebExtensionLocalizationError.undeclaredOption("zh-Hans.settings.language.options.Klingon")
                .localizedDescription
        )
    }

    // MARK: - Examples

    func testExamplesAreCompletelyLocalizedIntoSimplifiedChinese() throws {
        let autoTranslatorSettings = try WebExtensionCatalog.load(
            packageURL: Self.autoTranslatorPackageURL,
            preferredLanguages: ["en"]
        ).settings
        let examples: [(package: URL, settings: [WebExtensionSettingDescriptor])] = [
            (Self.autoTranslatorPackageURL, autoTranslatorSettings),
            (Self.appleDictionaryPackageURL, []),
            (Self.streamingEchoPackageURL, [])
        ]
        for example in examples {
            let name = example.package.lastPathComponent
            // The Apple Dictionary helper may not be built, so its package is not loaded as a whole.
            let localization = try WebExtensionLocalization.load(
                packageURL: example.package,
                defaultLanguage: "en",
                settings: example.settings
            )
            let english = try XCTUnwrap(localization.text["en"], name)
            let chinese = try XCTUnwrap(localization.text["zh-Hans"], name)
            XCTAssertFalse(english.messages.isEmpty, name)
            XCTAssertEqual(Set(chinese.messages.keys), Set(english.messages.keys), name)
            XCTAssertNotNil(chinese.name, name)

            for setting in example.settings {
                let text = chinese.settings[setting.key]
                XCTAssertNotNil(text?.title, "\(name) \(setting.key)")
                if setting.detail != nil {
                    XCTAssertNotNil(text?.detail, "\(name) \(setting.key)")
                }
                for option in setting.options {
                    XCTAssertNotNil(text?.options[option.value], "\(name) \(setting.key) \(option.value)")
                }
            }
        }
        XCTAssertEqual(
            try WebExtensionLocalization.load(
                packageURL: Self.appleDictionaryPackageURL,
                defaultLanguage: "en",
                settings: []
            ).text["zh-Hans"]?.name,
            "Apple 词典"
        )
    }

    // MARK: - Helpers

    private func settingDescriptors() throws -> [WebExtensionSettingDescriptor] {
        try WebExtensionCatalog.load(
            packageURL: makePackage(
                in: temporaryDirectory.appendingPathComponent("descriptors", isDirectory: true),
                settings: Self.settings
            ),
            preferredLanguages: ["en"]
        ).settings
    }

    @discardableResult
    private func makePackage(
        in directory: URL,
        name: String = "Localized",
        defaultLanguage: String? = nil,
        settings: String = "",
        localizations: String? = nil,
        script: String = "export function present() {}"
    ) throws -> URL {
        let package = directory.appendingPathComponent("Localized.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "\(Self.identifier)"
        name = "\(name)"
        \(defaultLanguage.map { "defaultLanguage = \"\($0)\"" } ?? "")

        [view]
        document = "web/index.html"
        module = "web/main.js"

        \(settings)
        """.write(to: package.appendingPathComponent("manifest.toml"), atomically: true, encoding: .utf8)
        if let localizations {
            try localizations.write(
                to: package.appendingPathComponent(WebExtensionLocalization.filename),
                atomically: true,
                encoding: .utf8
            )
        }
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
    private func buttonTitles(in webView: WKWebView) async throws -> [String] {
        let script = """
        Array.from(document.querySelectorAll("button"), button => {
          return button.title === button.getAttribute("aria-label") ? button.title : "mismatched label"
        })
        """
        return try await webView.evaluateJavaScript(script) as? [String] ?? []
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

/// Answers every dictionary lookup with a miss once the test releases it.
@MainActor
private final class GatedDictionaryMiss: WebExtensionNativeInvoking {
    private var isReleased = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func invoke(capability: String, method: String, arguments: [String: Any]) async throws -> Any {
        guard capability == "org.hovery.capability.system-dictionary",
              method == "lookup",
              let text = arguments["text"] as? String else {
            throw WebExtensionCapabilityError.invalidMessage
        }
        if !isReleased {
            await withCheckedContinuation { waiting.append($0) }
        }
        return ["found": false, "term": text]
    }

    func release() {
        isReleased = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
