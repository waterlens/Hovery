import AppKit
import Carbon.HIToolbox
import WebKit
import XCTest
@testable import Hovery

final class ResultsTabTests: XCTestCase {
    private enum TestTiming {
        static let timeout: Duration = .seconds(10)
        static let pollInterval: Duration = .milliseconds(20)
        /// How long an extension that must stay idle is watched.
        static let idleObservation: Duration = .milliseconds(300)
    }

    private enum Extension {
        static let first = "org.example.first"
        static let second = "org.example.second"
    }

    /// Records every hover it receives. Text starting with “finished” is done at once; other text
    /// keeps the request running until it is aborted.
    private static let recordingScript = """
    let current
    export async function present({ input, root, signal }) {
      const request = {}
      current = request
      globalThis.presented = [...(globalThis.presented ?? []), input.text]
      if (input.text.startsWith("finished")) {
        root.textContent = `done:${input.text}`
        return
      }
      root.textContent = `working:${input.text}`
      await new Promise(resolve => signal.addEventListener("abort", resolve, { once: true }))
      if (current === request) root.textContent = `aborted:${input.text}`
    }
    """

    private let pointer = CGPoint(x: 230, y: 210)
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryResultsTabTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testShortcutUsesNumberKeysWithExactlyTheRecognitionModifiers() {
        XCTAssertEqual(ResultsTabShortcut.tabIndex(forKeyCode: Int64(kVK_ANSI_1)), 0)
        XCTAssertEqual(ResultsTabShortcut.tabIndex(forKeyCode: Int64(kVK_ANSI_9)), 8)
        XCTAssertEqual(ResultsTabShortcut.tabIndex(forKeyCode: Int64(kVK_ANSI_Keypad3)), 2)
        XCTAssertNil(ResultsTabShortcut.tabIndex(forKeyCode: Int64(kVK_ANSI_0)))
        XCTAssertNil(ResultsTabShortcut.tabIndex(forKeyCode: Int64(kVK_ANSI_A)))

        let command: [RecognitionModifier] = [.command]
        XCTAssertTrue(ResultsTabShortcut.matches(CGEventFlags.maskCommand, modifiers: command))
        XCTAssertTrue(ResultsTabShortcut.matches(
            [CGEventFlags.maskCommand, .maskNumericPad, .maskAlphaShift],
            modifiers: command
        ))
        XCTAssertFalse(ResultsTabShortcut.matches([CGEventFlags.maskCommand, .maskShift], modifiers: command))
        XCTAssertFalse(ResultsTabShortcut.matches(CGEventFlags.maskAlternate, modifiers: command))
        XCTAssertFalse(ResultsTabShortcut.matches(CGEventFlags(), modifiers: []))
        XCTAssertTrue(ResultsTabShortcut.matches(
            [CGEventFlags.maskCommand, .maskAlternate],
            modifiers: [.option, .command]
        ))
        XCTAssertTrue(ResultsTabShortcut.matches(NSEvent.ModifierFlags([.command, .numericPad]), modifiers: command))
        XCTAssertFalse(ResultsTabShortcut.matches(NSEvent.ModifierFlags([.command, .control]), modifiers: command))
    }

    @MainActor
    func testOnlyTheSelectedExtensionReceivesTheHover() async throws {
        let manager = WebExtensionCoordinator(settings: try makeSettings())
        defer { manager.hide() }
        let first = try webView(of: Extension.first, in: manager)
        let second = try webView(of: Extension.second, in: manager)
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.first)

        manager.present(hierarchy: hierarchy(text: "alpha"), pointer: pointer)
        try await waitForText("working:alpha", in: first)
        try await Task.sleep(for: TestTiming.idleObservation)
        let hiddenRequests = try await presentedTexts(in: second)
        XCTAssertEqual(hiddenRequests, [])

        // Selecting a tab sends it the current hover and stops the tab the user left.
        manager.selectTabForTesting(at: 1)
        try await waitForText("working:alpha", in: second)
        try await waitForText("aborted:alpha", in: first)

        manager.selectTabForTesting(at: 0)
        try await waitForText("working:alpha", in: first)
        try await waitForText("aborted:alpha", in: second)
        let repeatedRequests = try await presentedTexts(in: first)
        XCTAssertEqual(repeatedRequests, ["alpha", "alpha"])

        manager.present(hierarchy: hierarchy(text: "beta"), pointer: pointer)
        try await waitForText("working:beta", in: first)
        try await Task.sleep(for: TestTiming.idleObservation)
        let laterRequests = try await presentedTexts(in: second)
        XCTAssertEqual(laterRequests, ["alpha"])
    }

    @MainActor
    func testFinishedResultsStayWhenSwitchingTabs() async throws {
        let manager = WebExtensionCoordinator(settings: try makeSettings())
        defer { manager.hide() }
        let first = try webView(of: Extension.first, in: manager)
        let second = try webView(of: Extension.second, in: manager)

        manager.present(hierarchy: hierarchy(text: "finished"), pointer: pointer)
        try await waitForText("done:finished", in: first)
        // Hovery learns that present() finished shortly after the page renders.
        try await Task.sleep(for: TestTiming.idleObservation)
        manager.selectTabForTesting(at: 1)
        try await waitForText("done:finished", in: second)
        try await Task.sleep(for: TestTiming.idleObservation)

        manager.selectTabForTesting(at: 0)
        try await Task.sleep(for: TestTiming.idleObservation)
        let firstRequests = try await presentedTexts(in: first)
        XCTAssertEqual(firstRequests, ["finished"])
        try await waitForText("done:finished", in: first)
    }

    @MainActor
    func testSelectedTabSurvivesReloading() throws {
        let settings = try makeSettings()
        let manager = WebExtensionCoordinator(settings: settings)

        manager.selectTabForTesting(at: 1)
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.second)
        manager.reloadExtensions()
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.second)

        manager.setEnabled(false, identifier: Extension.second)
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.first)
    }

    @MainActor
    func testRecognitionModifiersAndNumberKeysSelectTabsWhileResultsAreVisible() throws {
        let manager = WebExtensionCoordinator(settings: try makeSettings())
        defer { manager.hide() }
        let secondKey = Int64(kVK_ANSI_2)
        XCTAssertFalse(manager.handleTabShortcutForTesting(keyCode: secondKey, flags: .maskCommand))

        manager.present(hierarchy: hierarchy(text: "alpha"), pointer: pointer)
        XCTAssertFalse(manager.isTabShortcut(keyCode: Int64(kVK_ANSI_3), flags: .maskCommand))
        XCTAssertFalse(manager.handleTabShortcutForTesting(keyCode: secondKey, flags: [.maskCommand, .maskShift]))
        XCTAssertFalse(manager.handleTabShortcutForTesting(keyCode: secondKey, flags: []))
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.first)

        XCTAssertTrue(manager.isTabShortcut(keyCode: secondKey, flags: .maskCommand))
        XCTAssertTrue(manager.handleTabShortcutForTesting(keyCode: secondKey, flags: .maskCommand))
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.second)
        XCTAssertTrue(manager.handleTabShortcutForTesting(
            keyCode: Int64(kVK_ANSI_Keypad1),
            flags: [.maskCommand, .maskNumericPad]
        ))
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.first)

        manager.hide()
        XCTAssertFalse(manager.isTabShortcut(keyCode: secondKey, flags: .maskCommand))
    }

    @MainActor
    func testNumberKeysSelectTabsInTheKeyResultsPanel() throws {
        let manager = WebExtensionCoordinator(settings: try makeSettings())
        defer { manager.hide() }
        manager.present(hierarchy: hierarchy(text: "alpha"), pointer: pointer)
        let window = try XCTUnwrap(manager.resultsWindowForTesting)
        // Keys the focused page doesn't use travel up the responder chain to the panel.
        XCTAssertTrue(window.makeFirstResponder(nil))

        window.sendEvent(try keyDown(kVK_ANSI_2, characters: "2", in: window))
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.second)
        window.sendEvent(try keyDown(kVK_ANSI_1, characters: "1", modifierFlags: .command, in: window))
        XCTAssertEqual(manager.selectedExtensionIdentifierForTesting, Extension.first)
    }

    @MainActor
    private func makeSettings() throws -> HoverySettings {
        let settings = HoverySettings(configurationURL: temporaryDirectory.appendingPathComponent("config.toml"))
        for (identifier, name, order) in [(Extension.first, "First", 2), (Extension.second, "Second", 1)] {
            let package = settings.extensionsDirectoryURL
                .appendingPathComponent("\(name).hoveryextension", isDirectory: true)
            let web = package.appendingPathComponent("web", isDirectory: true)
            try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
            try """
            [extension]
            id = "\(identifier)"
            name = "\(name)"
            order = \(order)

            [view]
            document = "web/index.html"
            module = "web/main.js"
            """.write(to: package.appendingPathComponent("manifest.toml"), atomically: true, encoding: .utf8)
            try "<main id=\"hovery-root\"></main>".write(
                to: web.appendingPathComponent("index.html"),
                atomically: true,
                encoding: .utf8
            )
            try Self.recordingScript.write(
                to: web.appendingPathComponent("main.js"),
                atomically: true,
                encoding: .utf8
            )
        }
        return settings
    }

    private func hierarchy(text: String) -> HoverHierarchy {
        HoverHierarchy(
            displayID: CGMainDisplayID(),
            selections: [.word: SemanticSelection(
                level: .word,
                text: text,
                regions: [.rectangle(CGRect(x: 200, y: 200, width: 90, height: 24))],
                confidence: 1
            )]
        )
    }

    @MainActor
    private func webView(of identifier: String, in manager: WebExtensionCoordinator) throws -> WKWebView {
        try XCTUnwrap(manager.webViewForTesting(identifier: identifier) as? WKWebView)
    }

    @MainActor
    private func keyDown(
        _ keyCode: Int,
        characters: String,
        modifierFlags: NSEvent.ModifierFlags = [],
        in window: NSWindow
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: UInt16(keyCode)
        ))
    }

    @MainActor
    private func presentedTexts(in webView: WKWebView) async throws -> [String] {
        let json = try await webView.evaluateJavaScript("JSON.stringify(globalThis.presented ?? [])") as? String
        return try JSONDecoder().decode([String].self, from: Data((json ?? "[]").utf8))
    }

    @MainActor
    private func waitForText(_ expected: String, in webView: WKWebView) async throws {
        let deadline = ContinuousClock.now + TestTiming.timeout
        var text = ""
        while ContinuousClock.now < deadline {
            text = (try? await webView.evaluateJavaScript(
                "document.getElementById('hovery-root')?.textContent ?? ''"
            )) as? String ?? ""
            if text == expected { return }
            try await Task.sleep(for: TestTiming.pollInterval)
        }
        XCTFail("Timed out waiting for “\(expected)”. Rendered: \(text)")
    }
}
