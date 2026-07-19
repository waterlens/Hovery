import CoreGraphics
import CoreText
import AppKit
import ApplicationServices
import ScreenCaptureKit
import WebKit
import XCTest
@testable import Hovery

final class SemanticSelectionTests: XCTestCase {
    func testDefaultInteractionRequiresCommandWithShortDelayAndNoDebugOverlay() {
        let configuration = HoveryConfiguration.standard

        XCTAssertEqual(configuration.interaction.requiredModifiers, [.command])
        XCTAssertEqual(configuration.interaction.scanDelay, 0.05, accuracy: 0.000_001)
        XCTAssertFalse(configuration.overlay.debugEnabled)
    }

    func testScreenCapturePermissionDenialIsRecognized() {
        let denial = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )

        XCTAssertTrue(CaptureError.isPermissionDenied(denial))
        XCTAssertFalse(CaptureError.isPermissionDenied(CaptureError.noDisplay))
    }

    func testHierarchyFallsBackToNearestAvailableLevel() {
        let sentence = SemanticSelection(
            level: .sentence,
            text: "A sentence.",
            regions: [.rectangle(CGRect(x: 10, y: 10, width: 100, height: 20))],
            confidence: 0.9
        )
        let hierarchy = HoverHierarchy(displayID: 1, selections: [.sentence: sentence])

        XCTAssertEqual(hierarchy.selection(for: .word)?.level, .sentence)
        XCTAssertEqual(hierarchy.selection(for: .paragraph)?.level, .sentence)
        XCTAssertEqual(hierarchy.selection(for: .block)?.level, .sentence)
    }

    func testModifierRequirementNeedsEveryConfiguredKey() {
        let commandAndShift: CGEventFlags = [.maskCommand, .maskShift]

        XCTAssertTrue(HoverEngine.modifiersSatisfied([], flags: CGEventFlags()))
        XCTAssertTrue(HoverEngine.modifiersSatisfied([.command], flags: commandAndShift))
        XCTAssertTrue(HoverEngine.modifiersSatisfied([.command, .shift], flags: commandAndShift))
        XCTAssertFalse(HoverEngine.modifiersSatisfied([.command, .option], flags: commandAndShift))

        let appKitFlags: NSEvent.ModifierFlags = [.command, .shift]
        XCTAssertTrue(HoverEngine.modifiersSatisfied([.command, .shift], flags: appKitFlags))
        XCTAssertFalse(HoverEngine.modifiersSatisfied([.command, .option], flags: appKitFlags))
    }

    func testResultsInteractionCorridorDoesNotCoverTheWholeSentence() {
        let panel = CGRect(x: 100, y: 340, width: 500, height: 220)
        let anchor = CGRect(x: 300, y: 260, width: 50, height: 20)

        XCTAssertTrue(ResultsInteractionRegion.contains(
            CGPoint(x: 320, y: 310),
            panelFrame: panel,
            anchorRect: anchor,
            padding: 10
        ))
        XCTAssertTrue(ResultsInteractionRegion.contains(
            CGPoint(x: 400, y: 400),
            panelFrame: panel,
            anchorRect: anchor,
            padding: 10
        ))
        XCTAssertFalse(ResultsInteractionRegion.contains(
            CGPoint(x: 400, y: 270),
            panelFrame: panel,
            anchorRect: anchor,
            padding: 10
        ))
        XCTAssertTrue(ResultsInteractionRegion.isMovingTowardPanel(
            from: CGPoint(x: 320, y: 270),
            to: CGPoint(x: 320, y: 310),
            panelFrame: panel,
            anchorRect: anchor,
            padding: 10
        ))
        XCTAssertFalse(ResultsInteractionRegion.isMovingTowardPanel(
            from: CGPoint(x: 320, y: 270),
            to: CGPoint(x: 355, y: 270),
            panelFrame: panel,
            anchorRect: anchor,
            padding: 10
        ))
    }

    func testResultsPanelUsesTheSideThatCanShowTheWholeWindow() {
        let layout = ResultsPanelLayout.resolve(
            availableFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            horizontalAnchor: CGRect(x: 450, y: 500, width: 40, height: 20),
            avoidanceRect: CGRect(x: 200, y: 300, width: 600, height: 220),
            desiredSize: CGSize(width: 500, height: 280),
            gap: 10
        )

        XCTAssertEqual(layout.placement, .below)
        XCTAssertEqual(layout.frame.height, 280)
        XCTAssertLessThanOrEqual(layout.frame.maxY, 290)
    }

    func testResultsPanelUsesScrollingInsteadOfOverlappingAvoidanceRect() {
        let avoidance = CGRect(x: 200, y: 350, width: 600, height: 100)
        let layout = ResultsPanelLayout.resolve(
            availableFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            horizontalAnchor: CGRect(x: 450, y: 380, width: 40, height: 20),
            avoidanceRect: avoidance,
            desiredSize: CGSize(width: 500, height: 700),
            gap: 10
        )

        XCTAssertEqual(layout.placement, .above)
        XCTAssertEqual(layout.frame.height, 340)
        XCTAssertGreaterThanOrEqual(layout.frame.minY, avoidance.maxY + 10)
        XCTAssertFalse(layout.frame.intersects(avoidance))
    }

    func testResultsPanelKeepsItsPlacementWhileContentStreams() {
        let available = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let avoidance = CGRect(x: 300, y: 300, width: 400, height: 100)
        let first = ResultsPanelLayout.resolve(
            availableFrame: available,
            horizontalAnchor: avoidance,
            avoidanceRect: avoidance,
            desiredSize: CGSize(width: 500, height: 200),
            gap: 10
        )
        let expanded = ResultsPanelLayout.resolve(
            availableFrame: available,
            horizontalAnchor: avoidance,
            avoidanceRect: avoidance,
            desiredSize: CGSize(width: 500, height: 700),
            gap: 10,
            lockedPlacement: first.placement
        )

        XCTAssertEqual(expanded.placement, first.placement)
        XCTAssertFalse(expanded.frame.intersects(avoidance))
    }

    func testCaptureRegionPrefersElementThenWindowThenFixedFallback() {
        let display = CGRect(x: 100, y: 50, width: 1000, height: 800)
        let pointer = CGPoint(x: 500, y: 400)
        let window = CGRect(x: 200, y: 100, width: 700, height: 600)
        let element = CGRect(x: 300, y: 250, width: 400, height: 220)

        let elementRegion = ScreenCaptureService.resolveCaptureRegion(
            around: pointer,
            displayBounds: display,
            elementRect: element,
            windowRect: window,
            fallbackSize: CGSize(width: 320, height: 240)
        )
        XCTAssertEqual(elementRegion.source, .accessibilityElement)
        XCTAssertEqual(elementRegion.rect, element)

        let windowRegion = ScreenCaptureService.resolveCaptureRegion(
            around: pointer,
            displayBounds: display,
            elementRect: nil,
            windowRect: window,
            fallbackSize: CGSize(width: 320, height: 240)
        )
        XCTAssertEqual(windowRegion.source, .window)
        XCTAssertEqual(windowRegion.rect, window)

        let fallbackRegion = ScreenCaptureService.resolveCaptureRegion(
            around: CGPoint(x: 105, y: 55),
            displayBounds: display,
            elementRect: nil,
            windowRect: nil,
            fallbackSize: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(fallbackRegion.source, .fixedFallback)
        XCTAssertEqual(fallbackRegion.rect, CGRect(x: 100, y: 50, width: 400, height: 300))
    }

    func testAccessibilityRegionChoosesNearestSufficientAncestor() {
        var configuration = HoveryConfiguration.Capture()
        configuration.accessibilityMinimumWidth = 200
        configuration.accessibilityMinimumHeight = 100
        configuration.accessibilityPadding = 10
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        let candidates = [
            AccessibilityRegionCandidate(
                frame: CGRect(x: 300, y: 300, width: 80, height: 20),
                role: kAXStaticTextRole as String,
                depth: 0,
                elementIdentifier: 10
            ),
            AccessibilityRegionCandidate(
                frame: CGRect(x: 260, y: 250, width: 300, height: 180),
                role: kAXGroupRole as String,
                depth: 1,
                elementIdentifier: 20
            ),
            AccessibilityRegionCandidate(
                frame: window,
                role: kAXWindowRole as String,
                depth: 2
            )
        ]

        let region = AccessibilityRegionResolver.chooseRegion(
            from: candidates,
            at: CGPoint(x: 320, y: 310),
            within: window,
            configuration: configuration
        )

        XCTAssertEqual(region, CGRect(x: 250, y: 240, width: 320, height: 200))
        XCTAssertEqual(
            AccessibilityRegionResolver.chooseRegionResolution(
                from: candidates,
                at: CGPoint(x: 320, y: 310),
                within: window,
                configuration: configuration
            )?.elementIdentifier,
            20
        )
    }

    func testRegionHitSlopAndBlockGroupingUseConfiguration() {
        var regionConfiguration = HoveryConfiguration.RegionSelection()
        regionConfiguration.magneticHorizontalScale = 0.5
        regionConfiguration.magneticVerticalScale = 0.25
        regionConfiguration.minimumMagneticPadding = 0
        regionConfiguration.maximumHorizontalPadding = 100
        regionConfiguration.maximumVerticalPadding = 100
        regionConfiguration.blockMaximumVerticalGap = 1

        var heuristics = RegionSelectionHeuristics(configuration: regionConfiguration)
        let rect = CGRect(x: 100, y: 100, width: 80, height: 20)
        XCTAssertEqual(heuristics.magneticRect(rect), CGRect(x: 90, y: 95, width: 100, height: 30))

        let nextParagraph = CGRect(x: 100, y: 135, width: 80, height: 20)
        XCTAssertFalse(heuristics.belongsToSameBlock(rect, nextParagraph, lineHeight: 10))

        regionConfiguration.blockMaximumVerticalGap = 2
        heuristics = RegionSelectionHeuristics(configuration: regionConfiguration)
        XCTAssertTrue(heuristics.belongsToSameBlock(rect, nextParagraph, lineHeight: 10))
    }

    @MainActor
    func testConfigurationFileCanReloadAndRecoverFromInvalidTOML() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryTests-\(UUID().uuidString)", isDirectory: true)
        let configurationURL = directory.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = HoverySettings(configurationURL: configurationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configurationURL.path))

        var configured = HoveryConfiguration.standard
        configured.capture.width = 1_280
        configured.capture.accessibilityMinimumWidth = 320
        configured.overlay.debugEnabled = true
        configured.overlay.labelFontSize = 13
        configured.extensionOverlay.fillOpacity = 0.2
        configured.interaction.requiredModifiers = [.command, .shift]
        configured.webExtensions.disabled = ["org.example.disabled"]
        let text = try HoverySettings.serialized(configured)
        XCTAssertTrue(text.contains("accessibilityMinimumWidth = 320.0"))
        XCTAssertTrue(text.contains("[overlay]"))
        XCTAssertTrue(text.contains("debugEnabled = true"))
        XCTAssertTrue(text.contains("labelFontSize = 13.0"))
        XCTAssertTrue(text.contains("[extensionOverlay]"))
        XCTAssertTrue(text.contains("fillOpacity = 0.2"))
        XCTAssertTrue(text.contains("materialOpacity = 0.18"))
        XCTAssertTrue(text.contains("requiredModifiers = [\"command\", \"shift\"]"))
        XCTAssertTrue(text.contains("[webExtensions]"))
        XCTAssertTrue(text.contains("directory = \"Extensions\""))
        XCTAssertTrue(text.contains("disabled = [\"org.example.disabled\"]"))
        XCTAssertTrue(text.contains("[resultsPresentation]"))
        XCTAssertTrue(text.contains("tabBarHorizontalInset = 8.0"))
        XCTAssertTrue(text.contains("tabBarVerticalInset = 5.0"))
        XCTAssertTrue(text.contains("tabItemHorizontalPadding = 14.0"))
        XCTAssertTrue(text.contains("tabItemSpacing = 4.0"))
        XCTAssertTrue(text.contains("tabIndicatorHeight = 2.0"))
        XCTAssertTrue(text.contains("tabCornerRadius = 8.0"))
        XCTAssertFalse(text.contains("sentenceExpansionDelay"))
        try text.write(to: configurationURL, atomically: true, encoding: .utf8)
        settings.reload()

        XCTAssertNil(settings.loadError)
        XCTAssertEqual(settings.configuration.capture.width, 1_280)
        XCTAssertEqual(settings.configuration.capture.accessibilityMinimumWidth, 320)
        XCTAssertTrue(settings.configuration.overlay.debugEnabled)
        XCTAssertEqual(settings.configuration.overlay.labelFontSize, 13)
        XCTAssertEqual(settings.configuration.extensionOverlay.fillOpacity, 0.2)
        XCTAssertEqual(settings.configuration.interaction.requiredModifiers, [.command, .shift])
        XCTAssertEqual(settings.configuration.webExtensions.disabled, ["org.example.disabled"])

        let configurationWithoutNewTabInsets = text
            .components(separatedBy: .newlines)
            .filter {
                !$0.hasPrefix("tabBarHorizontalInset =")
                    && !$0.hasPrefix("tabBarVerticalInset =")
                    && !$0.hasPrefix("tabItemHorizontalPadding =")
                    && !$0.hasPrefix("tabItemSpacing =")
                    && !$0.hasPrefix("tabIndicatorHeight =")
                    && !$0.hasPrefix("tabCornerRadius =")
            }
            .joined(separator: "\n")
        try configurationWithoutNewTabInsets.write(
            to: configurationURL,
            atomically: true,
            encoding: .utf8
        )
        settings.reload()
        XCTAssertNil(settings.loadError)
        XCTAssertEqual(settings.configuration.resultsPresentation.tabBarHorizontalInset, 8)
        XCTAssertEqual(settings.configuration.resultsPresentation.tabBarVerticalInset, 5)
        XCTAssertEqual(settings.configuration.resultsPresentation.tabItemHorizontalPadding, 14)
        XCTAssertEqual(settings.configuration.resultsPresentation.tabItemSpacing, 4)
        XCTAssertEqual(settings.configuration.resultsPresentation.tabIndicatorHeight, 2)
        XCTAssertEqual(settings.configuration.resultsPresentation.tabCornerRadius, 8)

        let configurationWithoutOverlay = try XCTUnwrap(text.components(separatedBy: "\n[overlay]\n").first)
        try configurationWithoutOverlay.write(to: configurationURL, atomically: true, encoding: .utf8)
        settings.reload()

        XCTAssertNil(settings.loadError)
        XCTAssertFalse(settings.configuration.overlay.debugEnabled)
        XCTAssertEqual(settings.configuration.overlay, HoveryConfiguration.Overlay())

        try "not = [valid TOML".write(to: configurationURL, atomically: true, encoding: .utf8)
        settings.reload()

        XCTAssertNotNil(settings.loadError)
        XCTAssertEqual(settings.configuration.capture.width, 1_280)
    }

    func testWebExtensionManifestLoadsESMEntryAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryExtensionTests-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Example.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.lookup"
        name = "Lookup"
        input = "paragraph"
        order = 12

        [view]
        document = "web/index.html"
        module = "web/main.js"

        [permissions]
        network = ["https://api.example.com"]
        capabilities = ["org.example.lookup"]
        selectionOverlay = true
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export function present() {}".write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let descriptor = try WebExtensionCatalog.load(packageURL: package)

        XCTAssertEqual(descriptor.identifier, "org.example.lookup")
        XCTAssertEqual(descriptor.name, "Lookup")
        XCTAssertEqual(descriptor.preferredInput, .paragraph)
        XCTAssertEqual(descriptor.order, 12)
        XCTAssertEqual(descriptor.documentPath, "web/index.html")
        XCTAssertEqual(descriptor.modulePath, "web/main.js")
        XCTAssertEqual(descriptor.allowedNetworkOrigins, ["https://api.example.com"])
        XCTAssertEqual(descriptor.allowedCapabilities, ["org.example.lookup"])
        XCTAssertTrue(descriptor.allowsSelectionOverlay)
    }

    func testWebExtensionSelectionOverlayPermissionDefaultsToDisabled() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryOverlayManifestTests-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Example.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.no-overlay"
        name = "No Overlay"

        [view]
        document = "web/index.html"
        module = "web/main.js"
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export function present() {}".write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertFalse(try WebExtensionCatalog.load(packageURL: package).allowsSelectionOverlay)
    }

    func testWebExtensionManifestRejectsResourcesOutsidePackage() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryExtensionTests-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Unsafe.hoveryextension", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try "<main></main>".write(
            to: directory.appendingPathComponent("outside.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export function present() {}".write(
            to: directory.appendingPathComponent("outside.js"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [extension]
        id = "org.example.unsafe"
        name = "Unsafe"

        [view]
        document = "../outside.html"
        module = "../outside.js"
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try WebExtensionCatalog.load(packageURL: package)) { error in
            guard case WebExtensionManifestError.unsafeResourcePath = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    @MainActor
    func testExtensionManagerPersistsEnabledState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryManagerTests-\(UUID().uuidString)", isDirectory: true)
        let configurationURL = directory.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = HoverySettings(configurationURL: configurationURL)
        let package = settings.extensionsDirectoryURL
            .appendingPathComponent("Managed.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.managed"
        name = "Managed"

        [view]
        document = "web/index.html"
        module = "web/main.js"
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export function present() {}".write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WebExtensionCoordinator(settings: settings)
        XCTAssertEqual(manager.extensions.count, 1)
        XCTAssertTrue(try XCTUnwrap(manager.extensions.first).isEnabled)

        manager.setEnabled(false, identifier: "org.example.managed")

        XCTAssertEqual(settings.configuration.webExtensions.disabled, ["org.example.managed"])
        XCTAssertFalse(try XCTUnwrap(manager.extensions.first).isEnabled)
        let persisted = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("disabled = [\"org.example.managed\"]"))
    }

    @MainActor
    func testSuspendingSourceOverlayKeepsResultsPanelVisible() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryPersistentResultsTests-\(UUID().uuidString)", isDirectory: true)
        let configurationURL = directory.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = HoverySettings(configurationURL: configurationURL)
        let package = settings.extensionsDirectoryURL
            .appendingPathComponent("Persistent.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.persistent"
        name = "Persistent"

        [view]
        document = "web/index.html"
        module = "web/main.js"
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export function present() {}".write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WebExtensionCoordinator(settings: settings)
        let selection = SemanticSelection(
            level: .word,
            text: "persistent",
            regions: [.rectangle(CGRect(x: 200, y: 200, width: 90, height: 24))],
            confidence: 1
        )
        manager.present(
            hierarchy: HoverHierarchy(
                displayID: CGMainDisplayID(),
                selections: [.word: selection]
            ),
            pointer: CGPoint(x: 230, y: 210)
        )
        XCTAssertTrue(manager.resultsAreVisibleForTesting)

        manager.suspendSourceOverlay()
        XCTAssertTrue(manager.resultsAreVisibleForTesting)

        manager.hide()
        XCTAssertFalse(manager.resultsAreVisibleForTesting)
    }

    @MainActor
    func testNativeExtensionRequiresExplicitTrustBeforeEnabling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryNativeTrustTests-\(UUID().uuidString)", isDirectory: true)
        let configurationURL = directory.appendingPathComponent("config.toml")
        defer { try? FileManager.default.removeItem(at: directory) }

        let settings = HoverySettings(configurationURL: configurationURL)
        let package = settings.extensionsDirectoryURL
            .appendingPathComponent("Native.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        let native = package.appendingPathComponent("native", isDirectory: true)
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: native, withIntermediateDirectories: true)
        try "".write(
            to: native.appendingPathComponent("helper"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [extension]
        id = "org.example.native"
        name = "Native"

        [view]
        document = "web/index.html"
        module = "web/main.js"

        [permissions]
        capabilities = ["org.example.native"]

        [native]
        executable = "native/helper"
        protocol = "json-lines-v1"
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try "export function present() {}".write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let manager = WebExtensionCoordinator(settings: settings)
        var status = try XCTUnwrap(manager.extensions.first)
        XCTAssertTrue(status.hasNativeCode)
        XCTAssertFalse(status.isNativeCodeTrusted)
        XCTAssertFalse(status.isEnabled)

        manager.setEnabled(true, identifier: "org.example.native")
        XCTAssertFalse(try XCTUnwrap(manager.extensions.first).isEnabled)
        XCTAssertTrue(settings.configuration.webExtensions.trustedNative.isEmpty)

        manager.trustAndEnableNativeExtension(identifier: "org.example.native")
        status = try XCTUnwrap(manager.extensions.first)
        XCTAssertTrue(status.isNativeCodeTrusted)
        XCTAssertTrue(status.isEnabled)
        XCTAssertEqual(settings.configuration.webExtensions.trustedNative, ["org.example.native"])
        let persisted = try String(contentsOf: configurationURL, encoding: .utf8)
        XCTAssertTrue(persisted.contains("trustedNative = [\"org.example.native\"]"))
    }

    @MainActor
    func testWebExtensionLoadsESMAndInvokesPresentExport() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryWebRuntimeTests-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Runtime.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.runtime"
        name = "Runtime"

        [view]
        document = "web/index.html"
        module = "web/main.js"
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        export async function present({ input, root, signal }) {
          root.textContent = `started:${input.text}`
          await new Promise(resolve => setTimeout(resolve, input.delay ?? 0))
          signal.throwIfAborted()
          root.textContent = input.text
        }
        """.write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let descriptor = try WebExtensionCatalog.load(packageURL: package)
        let runtime = WebExtensionRuntimeController(descriptor: descriptor)
        runtime.present(request: [
            "id": UUID().uuidString,
            "input": ["text": "ESM present export", "delay": 0]
        ])
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        var renderedText = ""
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            renderedText = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
            if renderedText.contains("ESM present export") { break }
        }

        XCTAssertTrue(renderedText.contains("ESM present export"))

        runtime.present(request: [
            "id": UUID().uuidString,
            "input": ["text": "stale result", "delay": 160]
        ])
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(10))
            renderedText = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
            if renderedText.contains("started:stale result") { break }
        }
        XCTAssertTrue(renderedText.contains("started:stale result"))

        runtime.present(request: [
            "id": UUID().uuidString,
            "input": ["text": "current result", "delay": 0]
        ])
        try await Task.sleep(for: .milliseconds(220))
        renderedText = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""

        runtime.unmount()
        XCTAssertEqual(renderedText.trimmingCharacters(in: .whitespacesAndNewlines), "current result")
    }

    @MainActor
    func testWebExtensionCanShowItsRequestInputInSelectionOverlay() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryWebOverlayTests-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Overlay.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.overlay"
        name = "Overlay"

        [view]
        document = "web/index.html"
        module = "web/main.js"

        [permissions]
        selectionOverlay = true
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        export function present({ overlay }) {
          overlay.showInput({
            fill: "#0066ff80",
            stroke: "rebeccapurple",
            lineWidth: 1.5,
            lineDash: [6, 3],
            lineCap: "round",
            material: "hudWindow",
            materialOpacity: 0.2,
            shadow: { color: "rgb(0 0 0 / 25%)", radius: 4, x: 1, y: -1 }
          })
        }
        """.write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let descriptor = try WebExtensionCatalog.load(packageURL: package)
        let runtime = WebExtensionRuntimeController(descriptor: descriptor)
        let received = expectation(description: "Selection overlay request")
        runtime.selectionOverlayDidChange = { requestID, items in
            XCTAssertEqual(requestID, "request-1")
            let item = items?.first
            XCTAssertEqual(items?.count, 1)
            XCTAssertEqual(item?.selectionID, "selection-1")
            XCTAssertEqual(item?.style.fillColor?.red ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(item?.style.fillColor?.green ?? -1, 0.4, accuracy: 0.001)
            XCTAssertEqual(item?.style.fillColor?.blue ?? -1, 1, accuracy: 0.001)
            XCTAssertEqual(item?.style.lineWidth, 1.5)
            XCTAssertEqual(item?.style.lineDash, [6, 3])
            XCTAssertEqual(item?.style.lineCap, "round")
            XCTAssertEqual(item?.style.material, "hudWindow")
            XCTAssertEqual(item?.style.materialOpacity, 0.2)
            XCTAssertEqual(item?.style.shadowRadius, 4)
            XCTAssertEqual(item?.style.shadowOffsetX, 1)
            XCTAssertEqual(item?.style.shadowOffsetY, -1)
            received.fulfill()
        }
        runtime.present(request: [
            "id": "request-1",
            "input": ["id": "selection-1", "text": "hello"]
        ])

        await fulfillment(of: [received], timeout: 2)
        runtime.unmount()
    }

    @MainActor
    func testWebExtensionInvokesDeclaredCapabilityAsPromise() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryCapabilityTests-\(UUID().uuidString)", isDirectory: true)
        let package = directory.appendingPathComponent("Capability.hoveryextension", isDirectory: true)
        let web = package.appendingPathComponent("web", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        try """
        [extension]
        id = "org.example.capability"
        name = "Capability"

        [view]
        document = "web/index.html"
        module = "web/main.js"

        [permissions]
        capabilities = ["org.example.echo"]
        """.write(
            to: package.appendingPathComponent("manifest.toml"),
            atomically: true,
            encoding: .utf8
        )
        try "<main id=\"hovery-root\"></main>".write(
            to: web.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8
        )
        try """
        export async function present({ input, root, capabilities }) {
          const result = await capabilities.invoke("org.example.echo", "transform", {
            text: input.text
          })
          root.textContent = result.value
        }
        """.write(
            to: web.appendingPathComponent("main.js"),
            atomically: true,
            encoding: .utf8
        )

        let descriptor = try WebExtensionCatalog.load(packageURL: package)
        let runtime = WebExtensionRuntimeController(
            descriptor: descriptor,
            nativeInvoker: TestNativeInvoker()
        )
        runtime.present(request: ["input": ["text": "hello"]])
        let webView = try XCTUnwrap(runtime.view as? WKWebView)

        var renderedText = ""
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(20))
            renderedText = try await webView.evaluateJavaScript("document.body.innerText") as? String ?? ""
            if renderedText.contains("HELLO") { break }
        }

        runtime.unmount()
        XCTAssertEqual(renderedText.trimmingCharacters(in: .whitespacesAndNewlines), "HELLO")
    }

    func testVisionDocumentOCRBuildsCompleteHoverHierarchy() async throws {
        let canvasSize = CGSize(width: 1200, height: 600)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: canvasSize))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateWithName("Helvetica" as CFString, 42, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        let text = NSAttributedString(
            string: "Hovering reveals words. Sentences expand automatically.",
            attributes: attributes
        )
        let line = CTLineCreateWithAttributedString(text)
        context.textPosition = CGPoint(x: 100, y: 400)
        CTLineDraw(line, context)

        let image = try XCTUnwrap(context.makeImage())
        let frame = CapturedFrame(
            image: image,
            globalRect: CGRect(origin: .zero, size: canvasSize),
            displayID: 1,
            regionSource: .window
        )
        let pointer = CGPoint(x: 160, y: 180)

        let service = DocumentOCRService()
        let recognition = try await service.recognize(frame: frame, pointer: pointer)
        let hierarchy = recognition.hierarchy

        XCTAssertNotNil(hierarchy?.selections[.word])
        XCTAssertNotNil(hierarchy?.selections[.sentence])
        XCTAssertNotNil(hierarchy?.selections[.paragraph])
        XCTAssertNotNil(hierarchy?.selections[.block])
        XCTAssertTrue(hierarchy?.selections[.paragraph]?.text.contains("Hovering") == true)

        let recognitionIdentifier = try XCTUnwrap(recognition.identifier)
        let sameLineLookup = await service.hierarchy(
            from: recognitionIdentifier,
            at: CGPoint(x: 430, y: pointer.y)
        )
        guard case let .hit(sameLineHierarchy) = sameLineLookup else {
            return XCTFail("Expected the cached document to hit text on the same line")
        }
        XCTAssertNotNil(sameLineHierarchy.selections[.word])
        XCTAssertNotEqual(
            sameLineHierarchy.selections[.word]?.text,
            hierarchy?.selections[.word]?.text
        )
        XCTAssertEqual(
            sameLineHierarchy.selections[.paragraph]?.text,
            hierarchy?.selections[.paragraph]?.text
        )
        let blankLookup = await service.hierarchy(
            from: recognitionIdentifier,
            at: CGPoint(x: 20, y: 20)
        )
        let outsideLookup = await service.hierarchy(
            from: recognitionIdentifier,
            at: CGPoint(x: -1, y: -1)
        )
        XCTAssertEqual(blankLookup, .noHit)
        XCTAssertEqual(outsideLookup, .unavailable)
    }

    @MainActor
    func testOverlayRendersTranslucentHighlight() throws {
        let view = HighlightOverlayView(frame: CGRect(x: 0, y: 0, width: 320, height: 220))
        view.initialRegion = CGRect(x: 20, y: 20, width: 280, height: 180)
        view.initialRegionSource = .window
        view.selections = [
            SemanticSelection(
                level: .paragraph,
                text: "Visible paragraph",
                regions: [.rectangle(CGRect(x: 50, y: 60, width: 200, height: 70))],
                confidence: 0.91
            ),
            SemanticSelection(
                level: .sentence,
                text: "Visible sentence",
                regions: [.rectangle(CGRect(x: 60, y: 70, width: 180, height: 42))],
                confidence: 0.95
            )
        ]

        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)

        let scaleX = CGFloat(bitmap.pixelsWide) / view.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        let interior = try XCTUnwrap(bitmap.colorAt(
            x: Int(120 * scaleX),
            y: Int((view.bounds.height - 90) * scaleY)
        ))
        XCTAssertGreaterThan(interior.alphaComponent, 0.1)

        let paragraphOnly = try XCTUnwrap(bitmap.colorAt(
            x: Int(55 * scaleX),
            y: Int((view.bounds.height - 65) * scaleY)
        ))
        XCTAssertGreaterThan(paragraphOnly.alphaComponent, 0.1)

        let initialBorder = try XCTUnwrap(bitmap.colorAt(
            x: Int(20 * scaleX),
            y: Int((view.bounds.height - 100) * scaleY)
        ))
        XCTAssertGreaterThan(initialBorder.alphaComponent, 0.1)
        XCTAssertGreaterThan(initialBorder.redComponent, initialBorder.blueComponent)
    }

    @MainActor
    func testOverlayLabelAnchorsToRegionNearestPointer() throws {
        let view = HighlightOverlayView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let distantRegion = CGRect(x: 30, y: 80, width: 120, height: 24)
        let pointerRegion = CGRect(x: 260, y: 90, width: 180, height: 28)
        view.pointerLocation = CGPoint(x: 300, y: 100)
        view.selections = [
            SemanticSelection(
                level: .sentence,
                text: "A sentence spanning multiple regions",
                regions: [.rectangle(distantRegion), .rectangle(pointerRegion)],
                confidence: 0.95
            )
        ]

        let labelRect = try XCTUnwrap(view.labelRectsForTesting()[.sentence])

        XCTAssertEqual(labelRect.minX, pointerRegion.minX, accuracy: 0.001)
        XCTAssertEqual(
            labelRect.minY,
            pointerRegion.maxY + CGFloat(view.configuration.labelGap),
            accuracy: 0.001
        )
    }

    @MainActor
    func testOverlayLabelsAvoidCollisionsAndRemainVisible() {
        let view = HighlightOverlayView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let sharedRegion = CGRect(x: 180, y: 170, width: 220, height: 32)
        view.pointerLocation = CGPoint(x: sharedRegion.midX, y: sharedRegion.midY)
        view.selections = SemanticLevel.allCases.map { level in
            SemanticSelection(
                level: level,
                text: level.displayName,
                regions: [.rectangle(sharedRegion)],
                confidence: 0.9
            )
        }

        let labelRects = view.labelRectsForTesting()
        XCTAssertEqual(labelRects.count, SemanticLevel.allCases.count)

        let visibleBounds = view.bounds.insetBy(
            dx: CGFloat(view.configuration.labelEdgeInset),
            dy: CGFloat(view.configuration.labelEdgeInset)
        )
        for rect in labelRects.values {
            XCTAssertTrue(visibleBounds.contains(rect))
            XCTAssertFalse(rect.intersects(sharedRegion))
        }

        let rects = Array(labelRects.values)
        for firstIndex in rects.indices {
            for secondIndex in rects.indices where secondIndex > firstIndex {
                XCTAssertFalse(rects[firstIndex].intersects(rects[secondIndex]))
            }
        }
    }

    @MainActor
    func testOverlayPanelDoesNotApplySecondaryScreenOriginTwice() throws {
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin != .zero }),
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw XCTSkip("A secondary display with a non-zero origin is required.")
        }

        let displayID = displayNumber.uint32Value
        let displayBounds = CGDisplayBounds(displayID)
        let controller = HighlightOverlayController()
        let selection = SemanticSelection(
            level: .word,
            text: "Secondary display",
            regions: [.rectangle(CGRect(
                x: displayBounds.minX + 40,
                y: displayBounds.minY + 40,
                width: 120,
                height: 30
            ))],
            confidence: 1
        )

        controller.show(
            [selection],
            pointer: CGPoint(x: displayBounds.minX + 60, y: displayBounds.minY + 60),
            on: displayID
        )
        defer { controller.hide() }

        XCTAssertEqual(controller.panelFrameForTesting, screen.frame)
        XCTAssertEqual(controller.panelLevelForTesting, .screenSaver)
    }
}

@MainActor
private final class TestNativeInvoker: WebExtensionNativeInvoking {
    func invoke(capability: String, method: String, arguments: [String: Any]) async throws -> Any {
        guard capability == "org.example.echo",
              method == "transform",
              let text = arguments["text"] as? String else {
            throw WebExtensionCapabilityError.invalidMessage
        }
        return ["value": text.uppercased()]
    }
}
