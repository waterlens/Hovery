import AppKit
import Combine
import CoreGraphics
import OSLog
import SwiftUI

@MainActor
final class WebExtensionCoordinator: ObservableObject {
    struct ExtensionStatus: Identifiable, Equatable {
        let id: String
        let identifier: String?
        let name: String
        let input: WebExtensionInputLevel?
        let packageURL: URL
        let isEnabled: Bool
        let hasNativeCode: Bool
        let isNativeCodeTrusted: Bool
        var settings: [WebExtensionSettingDescriptor] = []
        /// Titles of required settings that do not have a usable value yet.
        var missingRequiredSettings: [String] = []
        let errorDescription: String?
    }

    struct SettingsForm: Identifiable, Equatable {
        let identifier: String
        let name: String
        let descriptors: [WebExtensionSettingDescriptor]
        let values: [String: WebExtensionSettingValue]

        var id: String { identifier }
    }

    enum SettingsError: LocalizedError {
        case unknownExtension(String)

        var errorDescription: String? {
            switch self {
            case .unknownExtension(let identifier):
                String(localized: "The extension \(identifier) is no longer installed.")
            }
        }
    }

    /// The hover shown in the results panel, kept so that an extension whose tab is selected
    /// later can still receive it.
    private struct HoverRequest {
        let id: String
        let hierarchy: HoverHierarchy
        let selectionIDsByLevel: [SemanticLevel: String]
        let pointer: CGPoint
        let application: NSRunningApplication?
    }

    @Published private(set) var extensions: [ExtensionStatus] = []
    /// Called when the user asks to edit an extension's settings from outside the Extensions window.
    var settingsRequestHandler: ((String) -> Void)?

    private let settings: HoverySettings
    private let secretStore: any WebExtensionSecretStoring
    /// Chooses the language of extensions' text; `nil` follows the user's language preferences.
    private let preferredLanguages: [String]?
    private let panelController = WebExtensionResultsPanelController()
    private let selectionOverlay = HighlightOverlayController()
    private let logger = Logger(subsystem: "app.hovery.Hovery", category: "WebExtensions")
    private var descriptorsByIdentifier: [String: WebExtensionDescriptor] = [:]
    private var runtimes: [WebExtensionRuntimeController] = []
    private var configurationCancellable: AnyCancellable?
    private var currentRequestKey: String?
    private var currentRequest: HoverRequest?
    /// Extensions that received `currentRequest`. Only the selected tab's extension receives a
    /// request, so hidden extensions don't call services for results nobody sees.
    private var presentedExtensionIdentifiers = Set<String>()
    private var currentSelectionsByID: [String: SemanticSelection] = [:]
    private var currentDisplayID: CGDirectDisplayID?
    private var overlayItemsByExtension: [String: [WebExtensionOverlayItem]] = [:]
    private var defaultAvoidanceRect: CGRect?
    private var sourceOverlaySuspended = false

    init(
        settings: HoverySettings,
        secretStore: (any WebExtensionSecretStoring)? = nil,
        preferredLanguages: [String]? = nil
    ) {
        self.settings = settings
        self.secretStore = secretStore ?? Self.defaultSecretStore()
        self.preferredLanguages = preferredLanguages
        panelController.selectionDidChange = { [weak self] _ in
            self?.selectedExtensionDidChange()
        }
        panelController.pinStateDidChange = { [weak self] isPinned in
            if isPinned {
                self?.clearPinnedSelectionOverlay()
            }
        }
        panelController.settingsRequested = { [weak self] identifier in
            self?.requestSettings(for: identifier)
        }
        configurationCancellable = Publishers.CombineLatest(
            settings.$extensionConfiguration,
            settings.$configuration.map(\.resultsPresentation).removeDuplicates()
        )
            .sink { [weak self] webExtensions, presentation in
                self?.reload(
                    webExtensions: webExtensions,
                    presentation: presentation
                )
            }
    }

    var hasExtensions: Bool {
        !runtimes.isEmpty
    }

    var resultsAreVisibleForTesting: Bool {
        panelController.isVisible
    }

    var selectedExtensionIdentifierForTesting: String? {
        panelController.selectedIdentifier
    }

    var resultsWindowForTesting: NSWindow? {
        panelController.window
    }

    func selectTabForTesting(at index: Int) {
        panelController.selectTab(at: index)
    }

    func webViewForTesting(identifier: String) -> NSView? {
        runtimes.first { $0.descriptor.identifier == identifier }?.view
    }

    /// Whether a key press is a tab shortcut, which the results panel takes instead of the app
    /// under the pointer.
    func isTabShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        panelController.isTabShortcut(keyCode: keyCode, flags: flags)
    }

    /// Handles a key press as the event tap does while the results panel is visible.
    func handleTabShortcutForTesting(keyCode: Int64, flags: CGEventFlags) -> Bool {
        panelController.handleTabShortcut(keyCode: keyCode, flags: flags)
    }

    func reloadExtensions() {
        reload(
            webExtensions: settings.extensionConfiguration,
            presentation: settings.configuration.resultsPresentation
        )
    }

    func setEnabled(_ enabled: Bool, identifier: String) {
        if enabled,
           let status = extensions.first(where: { $0.identifier == identifier }),
           status.hasNativeCode,
           !status.isNativeCodeTrusted {
            return
        }
        settings.updateExtensions { configuration in
            configuration.disabled.removeAll { $0 == identifier }
            if !enabled {
                configuration.disabled.append(identifier)
            }
        }
    }

    func trustAndEnableNativeExtension(identifier: String) {
        settings.updateExtensions { configuration in
            if !configuration.trustedNative.contains(identifier) {
                configuration.trustedNative.append(identifier)
            }
            configuration.disabled.removeAll { $0 == identifier }
        }
    }

    func openExtensionsDirectory() {
        let url = extensionDirectoryURL()
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.open(url)
        } catch {
            logger.error("Could not open extensions directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    func requestSettings(for identifier: String) {
        settingsRequestHandler?(identifier)
    }

    /// The current values of an installed extension's settings, including secrets.
    func settingsForm(for identifier: String) -> SettingsForm? {
        guard let descriptor = descriptorsByIdentifier[identifier], !descriptor.settings.isEmpty else {
            return nil
        }
        return SettingsForm(
            identifier: identifier,
            name: descriptor.name,
            descriptors: descriptor.settings,
            values: resolvedSettings(for: descriptor, configuration: settings.extensionConfiguration).values
        )
    }

    /// Stores secrets in the secret store and all other values that differ from their defaults in
    /// `extensions.toml`, then reloads the extensions so the new settings and permissions apply.
    func saveSettings(_ values: [String: WebExtensionSettingValue], for identifier: String) throws {
        guard let descriptor = descriptorsByIdentifier[identifier] else {
            throw SettingsError.unknownExtension(identifier)
        }
        for setting in descriptor.settings where setting.type == .secret {
            let key = WebExtensionSecretKey(extensionIdentifier: identifier, settingKey: setting.key)
            let secret = setting.normalized(values[setting.key]).stringValue ?? ""
            guard secret != secretStore.secret(for: key) ?? "" else { continue }
            try secretStore.setSecret(
                secret.isEmpty ? nil : secret,
                for: key,
                label: "Hovery – \(descriptor.name): \(setting.title)"
            )
        }

        let overrides = WebExtensionSettingDescriptor.storedOverrides(
            for: descriptor.settings,
            values: values
        )
        if overrides == settings.extensionConfiguration.settings[identifier] ?? [:] {
            // Only secrets changed, so the configuration file does not trigger a reload.
            reloadExtensions()
        } else {
            settings.updateExtensions { configuration in
                configuration.settings[identifier] = overrides.isEmpty ? nil : overrides
            }
        }
    }

    func present(hierarchy: HoverHierarchy, pointer: CGPoint) {
        let presentation = settings.configuration.resultsPresentation
        guard !panelController.isPinned else { return }
        guard presentation.enabled, !runtimes.isEmpty else {
            hide()
            return
        }

        let anchorSelection = hierarchy.selection(for: .word)
            ?? SemanticLevel.allCases.compactMap { hierarchy.selections[$0] }.first
        guard let anchorSelection else {
            hide()
            return
        }

        let requestKey = Self.requestKey(for: hierarchy)
        if requestKey == currentRequestKey {
            sourceOverlaySuspended = false
            refreshSelectionOverlay()
            return
        }
        currentRequestKey = requestKey
        sourceOverlaySuspended = false

        let selectionIDsByLevel = Dictionary(uniqueKeysWithValues: hierarchy.selections.keys.map {
            ($0, UUID().uuidString)
        })
        currentRequest = HoverRequest(
            id: UUID().uuidString,
            hierarchy: hierarchy,
            selectionIDsByLevel: selectionIDsByLevel,
            pointer: pointer,
            application: NSWorkspace.shared.frontmostApplication
        )
        presentedExtensionIdentifiers = []
        currentSelectionsByID = Dictionary(uniqueKeysWithValues: hierarchy.selections.compactMap { level, selection in
            selectionIDsByLevel[level].map { ($0, selection) }
        })
        currentDisplayID = hierarchy.displayID
        overlayItemsByExtension = [:]
        selectionOverlay.hide()

        let debugAvoidanceRect = Self.boundingRect(
            of: SemanticLevel.allCases.compactMap { hierarchy.selections[$0] }
        )
        defaultAvoidanceRect = settings.configuration.overlay.debugEnabled
            ? debugAvoidanceRect
            : anchorSelection.boundingRect

        panelController.shortcutModifiers = settings.configuration.interaction.requiredModifiers
        panelController.beginRequest(
            anchorRect: anchorSelection.boundingRect,
            avoidanceRect: defaultAvoidanceRect ?? anchorSelection.boundingRect,
            displayID: hierarchy.displayID,
            configuration: presentation
        )
        presentCurrentRequestToSelectedExtension()
    }

    func hide() {
        guard !panelController.isPinned else { return }
        currentRequestKey = nil
        currentRequest = nil
        presentedExtensionIdentifiers = []
        currentSelectionsByID = [:]
        currentDisplayID = nil
        overlayItemsByExtension = [:]
        defaultAvoidanceRect = nil
        sourceOverlaySuspended = false
        runtimes.forEach { $0.cancel() }
        panelController.hide()
        selectionOverlay.hide()
    }

    private func clearPinnedSelectionOverlay() {
        suspendSourceOverlay()
    }

    func suspendSourceOverlay() {
        sourceOverlaySuspended = true
        selectionOverlay.hide()
    }

    func shouldKeepVisible(at point: CGPoint) -> Bool {
        panelController.containsPanelPoint(point)
    }

    func dismissUnpinnedResultsIfNeeded() {
        guard panelController.shouldDismissForCurrentPointer else { return }
        hide()
    }

    func isPointerMovingTowardResults(from origin: CGPoint, to point: CGPoint) -> Bool {
        panelController.isMovingTowardPanel(from: origin, to: point)
    }

    private func reload(
        webExtensions: WebExtensionConfiguration,
        presentation: HoveryConfiguration.ResultsPresentation
    ) {
        runtimes.forEach { $0.unmount() }
        runtimes = []
        currentRequestKey = nil
        currentRequest = nil
        presentedExtensionIdentifiers = []
        currentSelectionsByID = [:]
        currentDisplayID = nil
        overlayItemsByExtension = [:]
        defaultAvoidanceRect = nil
        sourceOverlaySuspended = false
        panelController.hide()
        selectionOverlay.hide()

        let directoryURL = extensionDirectoryURL()
        descriptorsByIdentifier = [:]
        do {
            let entries = try WebExtensionCatalog.inspect(
                in: directoryURL,
                preferredLanguages: preferredLanguages ?? Locale.preferredLanguages
            )
            let disabled = Set(webExtensions.disabled)
            let trustedNative = Set(webExtensions.trustedNative)
            var identifiers = Set<String>()
            var statuses: [ExtensionStatus] = []
            var resolvedSettingsByIdentifier: [String: WebExtensionResolvedSettings] = [:]
            let descriptors = entries.compactMap { entry -> WebExtensionDescriptor? in
                guard let descriptor = entry.descriptor else {
                    statuses.append(ExtensionStatus(
                        id: entry.packageURL.path,
                        identifier: nil,
                        name: entry.packageURL.deletingPathExtension().lastPathComponent,
                        input: nil,
                        packageURL: entry.packageURL,
                        isEnabled: false,
                        hasNativeCode: false,
                        isNativeCodeTrusted: false,
                        errorDescription: entry.errorDescription
                    ))
                    return nil
                }
                guard identifiers.insert(descriptor.identifier).inserted else {
                    logger.error("Ignoring duplicate extension identifier: \(descriptor.identifier, privacy: .public)")
                    statuses.append(ExtensionStatus(
                        id: entry.packageURL.path,
                        identifier: nil,
                        name: descriptor.name,
                        input: descriptor.preferredInput,
                        packageURL: entry.packageURL,
                        isEnabled: false,
                        hasNativeCode: descriptor.nativeHost != nil,
                        isNativeCodeTrusted: false,
                        errorDescription: String(localized: "Another extension uses \(descriptor.identifier).")
                    ))
                    return nil
                }
                let hasNativeCode = descriptor.nativeHost != nil
                let isNativeCodeTrusted = !hasNativeCode || trustedNative.contains(descriptor.identifier)
                let extensionSettings = resolvedSettings(for: descriptor, configuration: webExtensions)
                resolvedSettingsByIdentifier[descriptor.identifier] = extensionSettings
                descriptorsByIdentifier[descriptor.identifier] = descriptor
                statuses.append(ExtensionStatus(
                    id: entry.packageURL.path,
                    identifier: descriptor.identifier,
                    name: descriptor.name,
                    input: descriptor.preferredInput,
                    packageURL: entry.packageURL,
                    isEnabled: !disabled.contains(descriptor.identifier) && isNativeCodeTrusted,
                    hasNativeCode: hasNativeCode,
                    isNativeCodeTrusted: isNativeCodeTrusted,
                    settings: descriptor.settings,
                    missingRequiredSettings: extensionSettings.missingRequiredKeys.compactMap { key in
                        descriptor.settings.first { $0.key == key }?.title
                    },
                    errorDescription: nil
                ))
                return descriptor
            }.sorted {
                if $0.order != $1.order { return $0.order > $1.order }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            extensions = statuses.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            runtimes = descriptors.compactMap { descriptor in
                guard !disabled.contains(descriptor.identifier) else { return nil }
                guard descriptor.nativeHost == nil || trustedNative.contains(descriptor.identifier) else {
                    return nil
                }
                let runtime = WebExtensionRuntimeController(
                    descriptor: descriptor,
                    settings: resolvedSettingsByIdentifier[descriptor.identifier],
                    nativeConfiguration: webExtensions
                )
                runtime.contentHeightDidChange = { [weak self] requestID, height in
                    guard let self, requestID == currentRequestID else { return }
                    panelController.updateContentHeight(height, for: descriptor.identifier)
                }
                runtime.failureDidOccur = { [weak self] message in
                    self?.logger.error(
                        "Extension \(descriptor.identifier, privacy: .public) failed: \(message, privacy: .public)"
                    )
                }
                runtime.selectionOverlayDidChange = { [weak self] requestID, items in
                    self?.handleSelectionOverlayChange(
                        extensionIdentifier: descriptor.identifier,
                        requestID: requestID,
                        items: items
                    )
                }
                if webExtensions.preload {
                    runtime.ensureLoaded()
                }
                return runtime
            }
            panelController.configure(runtimes: runtimes, configuration: presentation)
            logger.notice("Loaded \(self.runtimes.count, privacy: .public) Web extensions from \(directoryURL.path, privacy: .public)")
        } catch {
            extensions = []
            panelController.configure(runtimes: [], configuration: presentation)
            logger.error("Could not load Web extensions: \(error.localizedDescription, privacy: .public)")
        }
    }

    private var currentRequestID: String? {
        currentRequest?.id
    }

    /// Sends the current hover to the extension whose tab is visible, unless it already has it.
    private func presentCurrentRequestToSelectedExtension() {
        guard let request = currentRequest,
              let identifier = panelController.selectedIdentifier,
              !presentedExtensionIdentifiers.contains(identifier),
              let runtime = runtimes.first(where: { $0.descriptor.identifier == identifier }) else { return }
        presentedExtensionIdentifiers.insert(identifier)
        guard let input = request.hierarchy.selection(for: runtime.descriptor.preferredInput.semanticLevel) else {
            runtime.cancel()
            return
        }
        runtime.present(request: Self.requestPayload(
            id: request.id,
            input: input,
            hierarchy: request.hierarchy,
            selectionIDsByLevel: request.selectionIDsByLevel,
            pointer: request.pointer,
            application: request.application
        ))
    }

    /// Sends the hover to the newly visible extension. Work that hidden extensions haven't
    /// finished stops and starts over when their tab is selected again; finished results stay.
    private func selectedExtensionDidChange() {
        let selectedIdentifier = panelController.selectedIdentifier
        for runtime in runtimes where runtime.descriptor.identifier != selectedIdentifier {
            let identifier = runtime.descriptor.identifier
            guard presentedExtensionIdentifiers.contains(identifier),
                  runtime.completedRequestID != currentRequestID else { continue }
            presentedExtensionIdentifiers.remove(identifier)
            runtime.cancel()
        }
        presentCurrentRequestToSelectedExtension()
        refreshSelectionOverlay()
    }

    private func extensionDirectoryURL() -> URL {
        settings.extensionsDirectoryURL
    }

    private func resolvedSettings(
        for descriptor: WebExtensionDescriptor,
        configuration: WebExtensionConfiguration
    ) -> WebExtensionResolvedSettings {
        let secrets = descriptor.settings.reduce(into: [String: String]()) { secrets, setting in
            guard setting.type == .secret else { return }
            secrets[setting.key] = secretStore.secret(for: WebExtensionSecretKey(
                extensionIdentifier: descriptor.identifier,
                settingKey: setting.key
            ))
        }
        return WebExtensionResolvedSettings(
            descriptors: descriptor.settings,
            storedValues: configuration.settings[descriptor.identifier] ?? [:],
            secrets: secrets
        )
    }

    private static func defaultSecretStore() -> any WebExtensionSecretStoring {
        // The test host loads the user's real configuration; tests must never read their Keychain.
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil
            ? KeychainWebExtensionSecretStore()
            : InMemoryWebExtensionSecretStore()
    }

    private static func requestPayload(
        id: String,
        input: SemanticSelection,
        hierarchy: HoverHierarchy,
        selectionIDsByLevel: [SemanticLevel: String],
        pointer: CGPoint,
        application: NSRunningApplication?
    ) -> [String: Any] {
        var selections: [String: Any] = [:]
        for level in SemanticLevel.allCases {
            if let selection = hierarchy.selections[level] {
                selections[level.extensionName] = selectionPayload(
                    selection,
                    id: selectionIDsByLevel[level] ?? ""
                )
            }
        }

        return [
            "id": id,
            "input": selectionPayload(
                input,
                id: selectionIDsByLevel[input.level] ?? ""
            ),
            "selections": selections,
            "pointer": pointPayload(pointer),
            "application": [
                "name": application?.localizedName ?? "",
                "bundleIdentifier": application?.bundleIdentifier ?? ""
            ]
        ]
    }

    private static func requestKey(for hierarchy: HoverHierarchy) -> String {
        let text = SemanticLevel.allCases.map { level in
            guard let selection = hierarchy.selections[level] else {
                return "\(level.extensionName):"
            }
            let geometry = selection.regions.map { region in
                let bounds = region.boundingRect
                return "\(bounds.minX),\(bounds.minY),\(bounds.width),\(bounds.height)"
            }.joined(separator: ",")
            return "\(level.extensionName):\(selection.text):\(geometry)"
        }.joined(separator: "\u{1F}")
        return "\(hierarchy.displayID)\u{1E}\(text)"
    }

    private static func selectionPayload(_ selection: SemanticSelection, id: String) -> [String: Any] {
        [
            "id": id,
            "level": selection.level.extensionName,
            "text": selection.text,
            "confidence": Double(selection.confidence),
            "regions": selection.regions.map { region in
                [
                    "points": region.points.map(pointPayload),
                    "bounds": rectPayload(region.boundingRect)
                ]
            },
            "bounds": rectPayload(selection.boundingRect)
        ]
    }

    private func handleSelectionOverlayChange(
        extensionIdentifier: String,
        requestID: String,
        items: [WebExtensionOverlayItem]?
    ) {
        guard requestID == currentRequestID else { return }
        if let items {
            let validItems = items.reduce(into: [WebExtensionOverlayItem]()) { result, item in
                guard currentSelectionsByID[item.selectionID] != nil,
                      !result.contains(where: { $0.selectionID == item.selectionID }) else { return }
                result.append(item)
            }
            if validItems.isEmpty {
                overlayItemsByExtension.removeValue(forKey: extensionIdentifier)
            } else {
                overlayItemsByExtension[extensionIdentifier] = validItems
            }
        } else {
            overlayItemsByExtension.removeValue(forKey: extensionIdentifier)
        }
        refreshSelectionOverlay()
    }

    private func refreshSelectionOverlay() {
        let configuration = settings.configuration
        guard !sourceOverlaySuspended,
              !configuration.overlay.debugEnabled,
              configuration.extensionOverlay.enabled,
              let extensionIdentifier = panelController.selectedIdentifier,
              let items = overlayItemsByExtension[extensionIdentifier],
              let displayID = currentDisplayID else {
            selectionOverlay.hide()
            panelController.updateAvoidanceRect(defaultAvoidanceRect)
            return
        }
        let selections = items.compactMap { item -> ExtensionOverlaySelection? in
            guard let selection = currentSelectionsByID[item.selectionID] else { return nil }
            return ExtensionOverlaySelection(selection: selection, style: item.style)
        }
        guard !selections.isEmpty else {
            selectionOverlay.hide()
            panelController.updateAvoidanceRect(defaultAvoidanceRect)
            return
        }
        panelController.updateAvoidanceRect(
            Self.boundingRect(of: selections.map(\.selection)) ?? defaultAvoidanceRect
        )
        selectionOverlay.showExtensionSelections(
            selections,
            on: displayID,
            configuration: configuration.extensionOverlay
        )
    }

    private static func pointPayload(_ point: CGPoint) -> [String: Double] {
        ["x": point.x, "y": point.y]
    }

    private static func rectPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": rect.minX,
            "y": rect.minY,
            "width": rect.width,
            "height": rect.height
        ]
    }

    private static func boundingRect(of selections: [SemanticSelection]) -> CGRect? {
        let rect = selections.reduce(CGRect.null) { partial, selection in
            partial.union(selection.boundingRect)
        }
        return rect.isNull || rect.isEmpty ? nil : rect
    }
}

private extension SemanticLevel {
    var extensionName: String {
        switch self {
        case .word: "word"
        case .sentence: "sentence"
        case .paragraph: "paragraph"
        case .block: "block"
        }
    }
}

struct ResultsInteractionRegion {
    static func contains(
        _ point: CGPoint,
        panelFrame: CGRect,
        anchorRect: CGRect?,
        padding: CGFloat
    ) -> Bool {
        let expandedPanel = panelFrame.insetBy(dx: -padding, dy: -padding)
        guard !expandedPanel.contains(point), let anchorRect else {
            return expandedPanel.contains(point)
        }

        let expandedAnchor = anchorRect.insetBy(dx: -padding, dy: -padding)
        if expandedAnchor.contains(point) { return true }

        let bridge: CGRect
        if panelFrame.minY >= anchorRect.maxY {
            bridge = CGRect(
                x: expandedAnchor.minX,
                y: expandedAnchor.maxY,
                width: expandedAnchor.width,
                height: max(0, expandedPanel.minY - expandedAnchor.maxY)
            )
        } else if panelFrame.maxY <= anchorRect.minY {
            bridge = CGRect(
                x: expandedAnchor.minX,
                y: expandedPanel.maxY,
                width: expandedAnchor.width,
                height: max(0, expandedAnchor.minY - expandedPanel.maxY)
            )
        } else if panelFrame.minX >= anchorRect.maxX {
            bridge = CGRect(
                x: expandedAnchor.maxX,
                y: expandedAnchor.minY,
                width: max(0, expandedPanel.minX - expandedAnchor.maxX),
                height: expandedAnchor.height
            )
        } else {
            bridge = CGRect(
                x: expandedPanel.maxX,
                y: expandedAnchor.minY,
                width: max(0, expandedAnchor.minX - expandedPanel.maxX),
                height: expandedAnchor.height
            )
        }
        return bridge.contains(point)
    }

    static func isMovingTowardPanel(
        from origin: CGPoint,
        to point: CGPoint,
        panelFrame: CGRect,
        anchorRect: CGRect?,
        padding: CGFloat
    ) -> Bool {
        guard contains(point, panelFrame: panelFrame, anchorRect: anchorRect, padding: padding) else {
            return false
        }
        return squaredDistance(from: point, to: panelFrame)
            < squaredDistance(from: origin, to: panelFrame)
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(max(rect.minX - point.x, 0), point.x - rect.maxX)
        let dy = max(max(rect.minY - point.y, 0), point.y - rect.maxY)
        return dx * dx + dy * dy
    }
}

enum ResultsPanelVerticalPlacement: Equatable, Sendable {
    case above
    case below
}

struct ResultsPanelLayout: Equatable, Sendable {
    var frame: CGRect
    var placement: ResultsPanelVerticalPlacement

    static func resolve(
        availableFrame: CGRect,
        horizontalAnchor: CGRect,
        avoidanceRect: CGRect,
        desiredSize: CGSize,
        gap: CGFloat,
        lockedPlacement: ResultsPanelVerticalPlacement? = nil
    ) -> ResultsPanelLayout {
        let width = min(max(desiredSize.width, 0), availableFrame.width)
        let desiredHeight = min(max(desiredSize.height, 0), availableFrame.height)
        let aboveCapacity = max(0, availableFrame.maxY - avoidanceRect.maxY - gap)
        let belowCapacity = max(0, avoidanceRect.minY - gap - availableFrame.minY)

        let placement: ResultsPanelVerticalPlacement
        if let lockedPlacement {
            let lockedCapacity = lockedPlacement == .above ? aboveCapacity : belowCapacity
            let otherCapacity = lockedPlacement == .above ? belowCapacity : aboveCapacity
            if lockedCapacity > 0 || otherCapacity <= 0 {
                placement = lockedPlacement
            } else {
                placement = lockedPlacement == .above ? .below : .above
            }
        } else {
            let fitsAbove = desiredHeight <= aboveCapacity
            let fitsBelow = desiredHeight <= belowCapacity
            switch (fitsAbove, fitsBelow) {
            case (true, false): placement = .above
            case (false, true): placement = .below
            default: placement = aboveCapacity >= belowCapacity ? .above : .below
            }
        }

        let capacity = placement == .above ? aboveCapacity : belowCapacity
        let height = capacity > 0 ? min(desiredHeight, capacity) : desiredHeight
        var origin = CGPoint(
            x: horizontalAnchor.midX - width / 2,
            y: placement == .above
                ? avoidanceRect.maxY + gap
                : avoidanceRect.minY - gap - height
        )
        origin.x = min(max(origin.x, availableFrame.minX), availableFrame.maxX - width)
        origin.y = min(max(origin.y, availableFrame.minY), availableFrame.maxY - height)
        return ResultsPanelLayout(
            frame: CGRect(origin: origin, size: CGSize(width: width, height: height)),
            placement: placement
        )
    }
}

@MainActor
private final class WebExtensionResultsPanelController: NSWindowController {
    var selectionDidChange: ((String) -> Void)?
    var pinStateDidChange: ((Bool) -> Void)?
    var settingsRequested: ((String) -> Void)?
    var selectedIdentifier: String? {
        resultsViewController.selectedIdentifier
    }
    private(set) var isPinned = false
    private(set) var dismissOnPointerExit = false
    var isVisible: Bool { window?.isVisible == true }
    /// Holding these while pressing 1–9 selects a tab.
    var shortcutModifiers: [RecognitionModifier] = [] {
        didSet {
            guard shortcutModifiers != oldValue else { return }
            resultsViewController.shortcutModifiers = shortcutModifiers
        }
    }

    private let resultsViewController = WebExtensionResultsViewController()
    private let shortcutMonitor = ResultsTabShortcutMonitor()
    private var presentation = HoveryConfiguration.ResultsPresentation()
    private var contentHeights: [String: CGFloat] = [:]
    /// A tab that was just selected. Its extension starts working only then, so its first
    /// reported height may be smaller than the panel.
    private var newlySelectedIdentifier: String?
    private var currentHeight: CGFloat = 0
    private var anchorRect: CGRect?
    private var avoidanceRect: CGRect?
    private var anchorDisplayID: CGDirectDisplayID?
    private var verticalPlacement: ResultsPanelVerticalPlacement?

    var shouldDismissForCurrentPointer: Bool {
        guard dismissOnPointerExit,
              window?.isVisible == true,
              let frame = window?.frame else { return false }
        let padding = CGFloat(presentation.interactionCorridorPadding)
        return !frame.insetBy(dx: -padding, dy: -padding).contains(NSEvent.mouseLocation)
    }

    init() {
        let panel = InteractiveResultsPanel(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        panel.contentViewController = resultsViewController
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        resultsViewController.selectionDidChange = { [weak self] identifier in
            self?.newlySelectedIdentifier = identifier
            self?.showContentHeight(for: identifier, allowShrink: true)
            self?.selectionDidChange?(identifier)
        }
        resultsViewController.pinStateDidChange = { [weak self] isPinned in
            self?.isPinned = isPinned
            self?.dismissOnPointerExit = !isPinned
            self?.pinStateDidChange?(isPinned)
        }
        resultsViewController.settingsRequested = { [weak self] identifier in
            self?.settingsRequested?(identifier)
        }
        shortcutMonitor.keyDownHandler = { [weak self] keyCode, flags in
            self?.handleTabShortcut(keyCode: keyCode, flags: flags) ?? false
        }
        shortcutMonitor.modifierFlagsDidChange = { [weak self] flags in
            self?.updateShortcuts(flags: flags)
        }
        panel.keyDownHandler = { [weak self] event in
            self?.handleKeyDown(event) ?? false
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(
        runtimes: [WebExtensionRuntimeController],
        configuration: HoveryConfiguration.ResultsPresentation
    ) {
        presentation = configuration
        resultsViewController.configure(
            runtimes: runtimes,
            configuration: configuration
        )
        resultsViewController.contentCornerRadius = CGFloat(configuration.cornerRadius)
    }

    func beginRequest(
        anchorRect: CGRect,
        avoidanceRect: CGRect,
        displayID: CGDirectDisplayID,
        configuration: HoveryConfiguration.ResultsPresentation
    ) {
        presentation = configuration
        self.anchorRect = anchorRect
        self.avoidanceRect = avoidanceRect
        anchorDisplayID = displayID
        dismissOnPointerExit = false
        verticalPlacement = nil
        contentHeights = [:]
        newlySelectedIdentifier = nil
        currentHeight = CGFloat(configuration.initialHeight)
        resultsViewController.contentCornerRadius = CGFloat(configuration.cornerRadius)
        resizeAndPosition()
        window?.orderFrontRegardless()
        shortcutMonitor.watchModifiers()
        updateShortcuts(flags: NSEvent.modifierFlags)
    }

    func updateContentHeight(_ contentHeight: CGFloat, for identifier: String) {
        contentHeights[identifier] = contentHeight
        guard resultsViewController.selectedIdentifier == identifier else { return }
        let allowShrink = newlySelectedIdentifier == identifier
        newlySelectedIdentifier = nil
        showContentHeight(for: identifier, allowShrink: allowShrink)
    }

    func selectTab(at index: Int) {
        resultsViewController.selectTab(at: index)
    }

    /// Whether the recognition modifiers and a number key select a tab of the visible panel.
    func isTabShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard isVisible,
              ResultsTabShortcut.matches(flags, modifiers: shortcutModifiers),
              let index = ResultsTabShortcut.tabIndex(forKeyCode: keyCode) else { return false }
        return resultsViewController.tabCount > 1 && index < resultsViewController.tabCount
    }

    func handleTabShortcut(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard isTabShortcut(keyCode: keyCode, flags: flags),
              let index = ResultsTabShortcut.tabIndex(forKeyCode: keyCode) else { return false }
        return resultsViewController.selectTab(at: index)
    }

    /// Once the user clicks the panel, it is key and plain number keys select tabs as well,
    /// unless the extension's page used them.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        guard ResultsTabShortcut.modifiers(in: flags).isEmpty
                || ResultsTabShortcut.matches(flags, modifiers: shortcutModifiers),
              let index = ResultsTabShortcut.tabIndex(forKeyCode: Int64(event.keyCode)) else { return false }
        return resultsViewController.selectTab(at: index)
    }

    /// Number keys select tabs, and tabs show their numbers, only while the shortcut's modifiers
    /// are held.
    private func updateShortcuts(flags: NSEvent.ModifierFlags) {
        let isActive = isVisible
            && resultsViewController.tabCount > 1
            && ResultsTabShortcut.matches(flags, modifiers: shortcutModifiers)
        resultsViewController.showsShortcutHints = isActive
        shortcutMonitor.setCapturingKeys(isActive)
    }

    func updateAvoidanceRect(_ avoidanceRect: CGRect?) {
        guard !isPinned, let avoidanceRect, !avoidanceRect.isNull, !avoidanceRect.isEmpty else { return }
        self.avoidanceRect = avoidanceRect
        resizeAndPosition(lockPlacement: verticalPlacement != nil)
    }

    func hide() {
        isPinned = false
        dismissOnPointerExit = false
        resultsViewController.setPinned(false)
        shortcutMonitor.stop()
        resultsViewController.showsShortcutHints = false
        window?.orderOut(nil)
        anchorRect = nil
        avoidanceRect = nil
        anchorDisplayID = nil
        verticalPlacement = nil
        contentHeights = [:]
    }

    func containsPanelPoint(_ point: CGPoint) -> Bool {
        guard window?.isVisible == true,
              let frame = window?.frame,
              let displayID = anchorDisplayID,
              let point = appKitPoint(point, displayID: displayID) else { return false }
        let padding = CGFloat(presentation.interactionCorridorPadding)
        return frame.insetBy(dx: -padding, dy: -padding).contains(point)
    }

    func containsTransitionPoint(_ point: CGPoint) -> Bool {
        guard window?.isVisible == true,
              let frame = window?.frame,
              let displayID = anchorDisplayID,
              let point = appKitPoint(point, displayID: displayID) else { return false }
        let padding = CGFloat(presentation.interactionCorridorPadding)
        guard !frame.insetBy(dx: -padding, dy: -padding).contains(point) else { return false }
        let convertedAnchor = anchorRect.flatMap { anchorRect in
            appKitRect(anchorRect, displayID: displayID)
        }
        return ResultsInteractionRegion.contains(
            point,
            panelFrame: frame,
            anchorRect: convertedAnchor,
            padding: padding
        )
    }

    func isMovingTowardPanel(from origin: CGPoint, to point: CGPoint) -> Bool {
        guard window?.isVisible == true,
              let frame = window?.frame,
              let displayID = anchorDisplayID,
              let origin = appKitPoint(origin, displayID: displayID),
              let point = appKitPoint(point, displayID: displayID) else { return false }
        let padding = CGFloat(presentation.interactionCorridorPadding)
        let convertedAnchor = anchorRect.flatMap { anchorRect in
            appKitRect(anchorRect, displayID: displayID)
        }
        return ResultsInteractionRegion.isMovingTowardPanel(
            from: origin,
            to: point,
            panelFrame: frame,
            anchorRect: convertedAnchor,
            padding: padding
        )
    }

    private func showContentHeight(for identifier: String, allowShrink: Bool) {
        guard let contentHeight = contentHeights[identifier] else { return }
        let tabHeight = resultsViewController.effectiveTabBarHeight
        let desired = clampedHeight(contentHeight + tabHeight)
        currentHeight = allowShrink ? desired : max(currentHeight, desired)
        resizeAndPosition(lockPlacement: true)
    }

    private func resizeAndPosition(lockPlacement: Bool = false) {
        guard let panel = window as? NSPanel,
              let anchorRect,
              let avoidanceRect,
              let displayID = anchorDisplayID,
              let screen = screen(for: displayID),
              let convertedAnchor = appKitRect(anchorRect, displayID: displayID),
              let convertedAvoidance = appKitRect(avoidanceRect, displayID: displayID) else { return }

        let inset = CGFloat(presentation.screenEdgeInset)
        let available = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        let width = min(CGFloat(presentation.width), available.width)
        let height = min(clampedHeight(currentHeight), available.height)
        if isPinned, panel.isVisible {
            let currentFrame = panel.frame
            let origin = CGPoint(
                x: min(max(currentFrame.minX, available.minX), available.maxX - width),
                y: min(
                    max(currentFrame.maxY - height, available.minY),
                    available.maxY - height
                )
            )
            panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
            return
        }
        let gap = CGFloat(presentation.anchorGap)
        let layout = ResultsPanelLayout.resolve(
            availableFrame: available,
            horizontalAnchor: convertedAnchor,
            avoidanceRect: convertedAvoidance,
            desiredSize: CGSize(width: width, height: height),
            gap: gap,
            lockedPlacement: lockPlacement ? verticalPlacement : nil
        )
        if lockPlacement {
            verticalPlacement = layout.placement
        }
        panel.setFrame(layout.frame, display: true)
    }

    private func clampedHeight(_ height: CGFloat) -> CGFloat {
        min(
            max(height, CGFloat(presentation.minimumHeight)),
            CGFloat(presentation.maximumHeight)
        )
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }
    }

    private func appKitRect(_ rect: CGRect, displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = screen(for: displayID) else { return nil }
        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: screen.frame.minX + rect.minX - displayBounds.minX,
            y: screen.frame.minY + displayBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func appKitPoint(_ point: CGPoint, displayID: CGDirectDisplayID) -> CGPoint? {
        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.contains(point), let screen = screen(for: displayID) else { return nil }
        return CGPoint(
            x: screen.frame.minX + point.x - displayBounds.minX,
            y: screen.frame.minY + displayBounds.maxY - point.y
        )
    }
}

@MainActor
private final class WebExtensionResultsViewController: NSViewController {
    private enum Layout {
        static let toolbarButtonSpacing: CGFloat = 8
    }

    var selectionDidChange: ((String) -> Void)?
    var pinStateDidChange: ((Bool) -> Void)?
    var settingsRequested: ((String) -> Void)?
    var shortcutModifiers: [RecognitionModifier] = [] {
        didSet { updateTabShortcuts() }
    }
    /// Shows each tab's number while the recognition modifiers are held, which is when the
    /// number keys select tabs.
    var showsShortcutHints = false {
        didSet {
            guard showsShortcutHints != oldValue else { return }
            updateTabShortcuts()
        }
    }
    private(set) var selectedIdentifier: String?
    private(set) var effectiveTabBarHeight: CGFloat = 0
    var tabCount: Int { runtimes.count }

    private let tabBar = DraggableHeaderView()
    private let tabStack = NSStackView()
    private let tabSeparator = NSBox()
    private let settingsButton = NSButton()
    private let pinButton = NSButton()
    private let contentContainer = ProviderContentView()
    private var tabHeightConstraint: NSLayoutConstraint!
    private var tabLeadingConstraint: NSLayoutConstraint!
    private var tabTrailingConstraint: NSLayoutConstraint!
    private var pinTrailingConstraint: NSLayoutConstraint!
    private var tabButtons: [ProviderTabButton] = []
    private var runtimes: [WebExtensionRuntimeController] = []
    private weak var visibleRuntime: WebExtensionRuntimeController?
    var contentCornerRadius: CGFloat = 0 {
        didSet {
            guard contentCornerRadius != oldValue else { return }
            updateCornerRadius()
        }
    }

    override func loadView() {
        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        view = effectView

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        tabBar.wantsLayer = true
        tabBar.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        tabStack.orientation = .horizontal
        tabStack.alignment = .centerY
        tabStack.distribution = .fill
        tabStack.setContentHuggingPriority(.required, for: .horizontal)
        tabStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        tabSeparator.boxType = .separator
        tabSeparator.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        settingsButton.image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: String(localized: "Extension Settings")
        )
        settingsButton.isBordered = false
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
        settingsButton.toolTip = String(localized: "Extension Settings")
        settingsButton.isHidden = true
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: String(localized: "Pin Results"))
        pinButton.isBordered = false
        pinButton.setButtonType(.toggle)
        pinButton.target = self
        pinButton.action = #selector(togglePinned(_:))
        pinButton.toolTip = String(localized: "Pin Results")
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        tabBar.addSubview(tabSeparator)
        tabBar.addSubview(tabStack)
        tabBar.addSubview(settingsButton)
        tabBar.addSubview(pinButton)
        effectView.addSubview(tabBar)
        effectView.addSubview(contentContainer)

        tabHeightConstraint = tabBar.heightAnchor.constraint(equalToConstant: 0)
        tabLeadingConstraint = tabStack.leadingAnchor.constraint(
            greaterThanOrEqualTo: tabBar.leadingAnchor
        )
        tabTrailingConstraint = tabStack.trailingAnchor.constraint(
            lessThanOrEqualTo: settingsButton.leadingAnchor
        )
        pinTrailingConstraint = pinButton.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor)
        NSLayoutConstraint.activate([
            tabBar.topAnchor.constraint(equalTo: effectView.topAnchor),
            tabBar.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            tabHeightConstraint,
            tabStack.topAnchor.constraint(equalTo: tabBar.topAnchor),
            tabStack.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            tabStack.centerXAnchor.constraint(equalTo: tabBar.centerXAnchor),
            tabLeadingConstraint,
            tabTrailingConstraint,
            tabSeparator.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
            tabSeparator.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
            tabSeparator.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor),
            settingsButton.trailingAnchor.constraint(
                equalTo: pinButton.leadingAnchor,
                constant: -Layout.toolbarButtonSpacing
            ),
            settingsButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            pinTrailingConstraint,
            pinButton.centerYAnchor.constraint(equalTo: tabBar.centerYAnchor),
            contentContainer.topAnchor.constraint(equalTo: tabBar.bottomAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: effectView.bottomAnchor)
        ])
    }

    func configure(
        runtimes: [WebExtensionRuntimeController],
        configuration: HoveryConfiguration.ResultsPresentation
    ) {
        loadViewIfNeeded()
        visibleRuntime?.view.removeFromSuperview()
        children.forEach { $0.removeFromParent() }
        tabStack.arrangedSubviews.forEach { tab in
            tabStack.removeArrangedSubview(tab)
            tab.removeFromSuperview()
        }
        tabButtons = []
        self.runtimes = runtimes
        setPinned(false)
        tabStack.spacing = CGFloat(configuration.tabItemSpacing)
        for (index, runtime) in runtimes.enumerated() {
            addChild(runtime)
            let button = ProviderTabButton(
                title: runtime.descriptor.name,
                horizontalPadding: CGFloat(configuration.tabItemHorizontalPadding),
                indicatorHeight: CGFloat(configuration.tabIndicatorHeight),
                cornerRadius: CGFloat(configuration.tabCornerRadius)
            )
            button.tag = index
            button.target = self
            button.action = #selector(selectTab(_:))
            tabStack.addArrangedSubview(button)
            button.heightAnchor.constraint(equalTo: tabStack.heightAnchor).isActive = true
            tabButtons.append(button)
        }

        tabLeadingConstraint.constant = CGFloat(configuration.tabBarHorizontalInset)
        tabTrailingConstraint.constant = -CGFloat(configuration.tabItemSpacing)
        pinTrailingConstraint.constant = -CGFloat(configuration.tabBarHorizontalInset)
        let intrinsicTabHeight = (tabButtons.first?.intrinsicContentSize.height ?? 0)
            + CGFloat(configuration.tabBarVerticalInset) * 2
        effectiveTabBarHeight = runtimes.isEmpty
            ? 0
            : max(CGFloat(configuration.tabBarHeight), intrinsicTabHeight)
        tabHeightConstraint.constant = effectiveTabBarHeight
        tabBar.isHidden = runtimes.isEmpty
        updateTabShortcuts()
        // Reloading, for example after saving an extension's settings, keeps the tab the user chose.
        let selectedIndex = runtimes.firstIndex { $0.descriptor.identifier == selectedIdentifier } ?? 0
        if runtimes.indices.contains(selectedIndex) {
            updateSelectedTab(index: selectedIndex)
            show(runtime: runtimes[selectedIndex])
        } else {
            selectedIdentifier = nil
            visibleRuntime = nil
            settingsButton.isHidden = true
        }
    }

    /// Selects a tab as clicking it does. Returns `false` when there is no other tab to switch to.
    @discardableResult
    func selectTab(at index: Int) -> Bool {
        guard runtimes.count > 1, runtimes.indices.contains(index) else { return false }
        let runtime = runtimes[index]
        guard runtime.descriptor.identifier != selectedIdentifier else { return true }
        updateSelectedTab(index: index)
        show(runtime: runtime)
        selectionDidChange?(runtime.descriptor.identifier)
        return true
    }

    @objc private func selectTab(_ sender: ProviderTabButton) {
        selectTab(at: sender.tag)
    }

    private func updateTabShortcuts() {
        let symbols = shortcutModifiers.map(\.symbol).joined()
        let hasShortcuts = tabButtons.count > 1 && !symbols.isEmpty
        for (index, button) in tabButtons.enumerated() {
            let number = hasShortcuts && index < ResultsTabShortcut.tabLimit ? index + 1 : nil
            button.setShortcut(number: number, visible: showsShortcutHints)
            button.toolTip = number.map { "\(button.providerTitle) (\(symbols)\($0))" } ?? button.providerTitle
        }
    }

    @objc private func togglePinned(_ sender: NSButton) {
        let pinned = sender.state == .on
        updatePinAppearance(pinned: pinned)
        pinStateDidChange?(pinned)
    }

    @objc private func openSettings(_ sender: NSButton) {
        guard let selectedIdentifier else { return }
        settingsRequested?(selectedIdentifier)
    }

    func setPinned(_ pinned: Bool) {
        loadViewIfNeeded()
        pinButton.state = pinned ? .on : .off
        updatePinAppearance(pinned: pinned)
    }

    private func updatePinAppearance(pinned: Bool) {
        pinButton.image = NSImage(
            systemSymbolName: pinned ? "pin.fill" : "pin",
            accessibilityDescription: pinned ? String(localized: "Unpin Results") : String(localized: "Pin Results")
        )
        pinButton.toolTip = pinned ? String(localized: "Unpin Results") : String(localized: "Pin Results")
        tabBar.isDraggingEnabled = pinned
    }

    private func updateSelectedTab(index: Int) {
        for (buttonIndex, button) in tabButtons.enumerated() {
            button.isCurrent = buttonIndex == index
        }
    }

    private func updateCornerRadius() {
        view.layer?.cornerRadius = contentCornerRadius
        // The layer's corners clip the panel's views, but the window server, which draws the
        // material behind the window, only sees the mask. Without it, it takes the material for a
        // rectangle and leaves the window's shadow out of the corners, so they look square.
        (view as? NSVisualEffectView)?.maskImage = Self.cornerMask(radius: contentCornerRadius)
        contentContainer.cornerRadius = contentCornerRadius
    }

    /// A stretchable mask with the continuous corners that the view's layer draws.
    private static func cornerMask(radius: CGFloat) -> NSImage? {
        guard radius > 0 else { return nil }
        // Continuous corners curve along this many radii of each edge; only the rest stretches.
        let capInset = ceil(radius * CALayer.cornerCurveExpansionFactor(.continuous))
        let image = NSImage(
            size: NSSize(width: capInset * 2 + 1, height: capInset * 2 + 1),
            flipped: false
        ) { rect in
            NSColor.black.setFill()
            NSBezierPath(
                cgPath: Path(roundedRect: rect, cornerRadius: radius, style: .continuous).cgPath
            ).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: capInset, left: capInset, bottom: capInset, right: capInset)
        image.resizingMode = .stretch
        return image
    }

    private func show(runtime: WebExtensionRuntimeController) {
        visibleRuntime?.view.removeFromSuperview()
        let runtimeView = runtime.view
        runtimeView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(runtimeView)
        NSLayoutConstraint.activate([
            runtimeView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            runtimeView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            runtimeView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            runtimeView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        visibleRuntime = runtime
        selectedIdentifier = runtime.descriptor.identifier
        settingsButton.isHidden = runtime.descriptor.settings.isEmpty
        settingsButton.toolTip = String(localized: "\(runtime.descriptor.name) Settings")
        settingsButton.setAccessibilityLabel(settingsButton.toolTip)
    }
}

@MainActor
private final class ProviderTabButton: NSButton {
    private enum ShortcutBadge {
        static let height: CGFloat = 15
        static let horizontalPadding: CGFloat = 4
        static let cornerRadius: CGFloat = 4
        static let spacing = " "
    }

    var isCurrent = false {
        didSet { updateAppearance() }
    }

    let providerTitle: String
    private var shortcutNumber: Int?
    private var showsShortcut = false
    private let horizontalPadding: CGFloat
    private let indicatorHeight: CGFloat
    private let cornerRadius: CGFloat
    private let indicatorLayer = CALayer()

    init(
        title: String,
        horizontalPadding: CGFloat,
        indicatorHeight: CGFloat,
        cornerRadius: CGFloat
    ) {
        providerTitle = title
        self.horizontalPadding = horizontalPadding
        self.indicatorHeight = indicatorHeight
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)

        self.title = title
        isBordered = false
        focusRingType = .none
        setButtonType(.momentaryChange)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = title
        setAccessibilityLabel(title)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        indicatorLayer.isHidden = true
        layer?.addSublayer(indicatorLayer)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let titleSize = attributedTitle.size()
        return NSSize(
            width: ceil(titleSize.width + horizontalPadding * 2),
            height: ceil(max(super.intrinsicContentSize.height, titleSize.height))
        )
    }

    override func layout() {
        super.layout()
        indicatorLayer.frame = CGRect(
            x: 0,
            y: bounds.height - indicatorHeight,
            width: bounds.width,
            height: indicatorHeight
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func setShortcut(number: Int?, visible: Bool) {
        guard number != shortcutNumber || visible != showsShortcut else { return }
        shortcutNumber = number
        showsShortcut = visible
        updateAppearance()
    }

    private func updateAppearance() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: isCurrent ? .semibold : .regular)
        let title = NSMutableAttributedString()
        if showsShortcut, let shortcutNumber {
            title.append(Self.shortcutBadge(shortcutNumber, alignedWith: font))
            title.append(NSAttributedString(string: ShortcutBadge.spacing, attributes: [.font: font]))
        }
        title.append(NSAttributedString(
            string: providerTitle,
            attributes: [
                .font: font,
                .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor
            ]
        ))
        attributedTitle = title
        indicatorLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        layer?.backgroundColor = isCurrent ? NSColor.textBackgroundColor.cgColor : NSColor.clear.cgColor
        indicatorLayer.isHidden = !isCurrent || indicatorHeight <= 0
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// A keycap-style number, centered on the capital letters of the title.
    private static func shortcutBadge(_ number: Int, alignedWith font: NSFont) -> NSAttributedString {
        let label = "\(number)"
        let labelWidth = (label as NSString).size(withAttributes: [.font: badgeFont()]).width
        let size = NSSize(
            width: max(ceil(labelWidth) + ShortcutBadge.horizontalPadding * 2, ShortcutBadge.height),
            height: ShortcutBadge.height
        )
        // Drawn on demand, so the colors follow the current appearance.
        let image = NSImage(size: size, flipped: false) { rect in
            let border = NSBezierPath(
                roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                xRadius: ShortcutBadge.cornerRadius,
                yRadius: ShortcutBadge.cornerRadius
            )
            NSColor.tertiaryLabelColor.setStroke()
            border.stroke()
            let font = badgeFont()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let width = (label as NSString).size(withAttributes: attributes).width
            let baseline = rect.midY - font.capHeight / 2
            (label as NSString).draw(
                at: NSPoint(x: rect.midX - width / 2, y: baseline + font.descender),
                withAttributes: attributes
            )
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(
            x: 0,
            y: ((font.capHeight - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
        return NSAttributedString(attachment: attachment)
    }

    private static func badgeFont() -> NSFont {
        .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
    }
}

@MainActor
private final class ProviderContentView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet { updateCornerMask() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        updateBackgroundColor()
        updateCornerMask()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    private func updateCornerMask() {
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
    }
}

@MainActor
private final class DraggableHeaderView: NSView {
    var isDraggingEnabled = false

    override func mouseDown(with event: NSEvent) {
        guard isDraggingEnabled else {
            super.mouseDown(with: event)
            return
        }
        window?.performDrag(with: event)
    }
}

@MainActor
private final class InteractiveResultsPanel: NSPanel {
    /// Receives key presses that the focused view, such as an extension's page, didn't use.
    /// Returns `true` when it used the key press.
    var keyDownHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if keyDownHandler?(event) != true {
            super.keyDown(with: event)
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            makeKey()
        }
        super.sendEvent(event)
    }
}
