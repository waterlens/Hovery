import XCTest
@testable import Hovery

final class InterfaceLanguageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        // A separate domain, so tests never change Hovery's own language.
        suiteName = "HoveryTests.InterfaceLanguage.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testStoredLanguagesMatchTheOfferedLanguages() {
        XCTAssertEqual(InterfaceLanguage(storedLanguage: "en"), .english)
        XCTAssertEqual(InterfaceLanguage(storedLanguage: "en-CN"), .english)
        XCTAssertEqual(InterfaceLanguage(storedLanguage: "zh-Hans"), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage(storedLanguage: "zh-Hans-CN"), .simplifiedChinese)
        XCTAssertEqual(InterfaceLanguage(storedLanguage: "zh-CN"), .simplifiedChinese)
        XCTAssertNil(InterfaceLanguage(storedLanguage: "zh-Hant-TW"))
        XCTAssertNil(InterfaceLanguage(storedLanguage: "ja"))
    }

    func testChoosingALanguageWritesTheAppLanguagePreference() {
        let preference = InterfaceLanguagePreference(defaults: defaults, domain: suiteName)
        XCTAssertEqual(preference.language, .system)

        preference.setLanguage(.simplifiedChinese)
        XCTAssertEqual(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"] as? [String], ["zh-Hans"])
        XCTAssertEqual(preference.language, .simplifiedChinese)

        // A stored language can include a region.
        defaults.set(["en-GB"], forKey: "AppleLanguages")
        XCTAssertEqual(preference.language, .english)

        preference.setLanguage(.system)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
        XCTAssertEqual(preference.language, .system)
    }

    func testLocalizationFollowsTheChoiceOrTheSystemLanguages() {
        func localization(_ language: InterfaceLanguage, system: [String]) -> String? {
            InterfaceLanguagePreference.localization(
                for: language,
                systemLanguages: system,
                localizations: ["Base", "en", "zh-Hans"]
            )
        }
        XCTAssertEqual(localization(.system, system: ["en-CN", "zh-Hans-CN"]), "en")
        XCTAssertEqual(localization(.system, system: ["zh-Hans-CN", "en-CN"]), "zh-Hans")
        XCTAssertEqual(localization(.simplifiedChinese, system: ["en-CN"]), "zh-Hans")
        XCTAssertEqual(localization(.english, system: ["zh-Hans-CN"]), "en")
    }
}
