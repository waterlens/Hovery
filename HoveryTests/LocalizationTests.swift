import Foundation
import XCTest
@testable import Hovery

final class LocalizationTests: XCTestCase {
    /// The Hovery scheme runs tests in English, so assertions on English text hold whatever the Mac's language is.
    func testTestsRunInEnglish() {
        XCTAssertEqual(Bundle.main.preferredLocalizations.first, "en")
        XCTAssertEqual(
            WebExtensionNativeHostError.timedOut.localizedDescription,
            "The native extension request timed out."
        )
        XCTAssertEqual(String(localized: "Showing \(1) semantic levels", bundle: .main), "Showing 1 semantic level")
        XCTAssertEqual(String(localized: "Showing \(2) semantic levels", bundle: .main), "Showing 2 semantic levels")
    }

    func testAppIncludesSimplifiedChinese() throws {
        let path = try XCTUnwrap(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let bundle = try XCTUnwrap(Bundle(path: path))
        XCTAssertEqual(bundle.localizedString(forKey: "Quit Hovery", value: nil, table: nil), "退出 Hovery")

        let format = bundle.localizedString(forKey: "Showing %lld semantic levels", value: nil, table: nil)
        XCTAssertEqual(String.localizedStringWithFormat(format, 3), "正在显示 3 个语义层级")
    }
}
