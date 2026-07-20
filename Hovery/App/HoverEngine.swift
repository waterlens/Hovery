import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation
import OSLog

@MainActor
final class HoverEngine: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var permissionGranted = CGPreflightScreenCaptureAccess()
    @Published private(set) var accessibilityPermissionGranted = AccessibilityRegionResolver.isTrusted
    @Published private(set) var status = "Waiting"
    @Published private(set) var currentSelection: SemanticSelection?

    private let settings: HoverySettings
    private let captureService = ScreenCaptureService()
    private let ocrService = DocumentOCRService()
    private let overlay = HighlightOverlayController()
    let webExtensions: WebExtensionCoordinator
    private let logger = Logger(subsystem: "app.hovery.Hovery", category: "HoverEngine")

    private var loopTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var scanTaskID: UUID?
    private var anchorPoint: CGPoint?
    private var stableSince = ContinuousClock.now
    private var hierarchy: HoverHierarchy?
    private var cachedRecognitionID: UUID?
    private var cachedRecognitionAt: ContinuousClock.Instant?
    private var cachedCaptureTarget: CaptureTarget?
    private var lastRefreshAt = ContinuousClock.now
    private var hasAttemptedScanAtAnchor = false
    private var stoppedForMissingPermissions = false
    private var modifierKeysWereSatisfied = false
    private var configurationCancellable: AnyCancellable?
    private var contentMutationMonitor: Any?
    private var modifierEventMonitor: Any?
    private var workspaceActivationObserver: NSObjectProtocol?

    private let clock = ContinuousClock()
    init(settings: HoverySettings) {
        self.settings = settings
        webExtensions = WebExtensionCoordinator(settings: settings)
        configurationCancellable = settings.$configuration
            .map { $0.overlay.debugEnabled }
            .removeDuplicates()
            .sink { [weak self] debugEnabled in
                if debugEnabled {
                    self?.anchorPoint = nil
                    self?.hasAttemptedScanAtAnchor = false
                } else {
                    self?.overlay.hide()
                }
            }
    }

    func start() {
        guard loopTask == nil else { return }

        refreshPermissionState()

        guard permissionGranted, accessibilityPermissionGranted else {
            stoppedForMissingPermissions = true
            updateMissingPermissionStatus()
            logger.error(
                "Hover recognition requires Screen & System Audio Recording and Accessibility permissions"
            )
            return
        }

        stoppedForMissingPermissions = false
        isRunning = true
        logger.notice("Hover recognition started")
        anchorPoint = nil
        hasAttemptedScanAtAnchor = false
        modifierKeysWereSatisfied = requiredModifiersArePressed()
        status = modifierKeysWereSatisfied ? "Hover over visible text" : requiredModifiersStatus()
        stableSince = clock.now
        startContentMutationMonitoring()
        let contentCacheLifetime = settings.configuration.capture.contentCacheLifetime
        Task { [captureService] in
            await captureService.prepare(cacheLifetime: contentCacheLifetime)
        }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        scanTask?.cancel()
        scanTask = nil
        scanTaskID = nil
        isRunning = false
        anchorPoint = nil
        hasAttemptedScanAtAnchor = false
        hierarchy = nil
        clearRecognitionCache()
        currentSelection = nil
        modifierKeysWereSatisfied = false
        overlay.hide()
        webExtensions.hide()
        stoppedForMissingPermissions = false
        stopContentMutationMonitoring()
        status = "Paused"
        logger.notice("Hover recognition paused")
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    func requestScreenRecordingPermission() {
        permissionGranted = CGRequestScreenCaptureAccess()
        if permissionGranted {
            start()
        } else {
            stoppedForMissingPermissions = true
            updateMissingPermissionStatus()
        }
    }

    func requestAccessibilityPermission() {
        accessibilityPermissionGranted = AccessibilityRegionResolver.requestPermission()
        if accessibilityPermissionGranted {
            start()
        } else {
            stoppedForMissingPermissions = true
            updateMissingPermissionStatus()
        }
    }

    func refreshPermissions() {
        let shouldResume = stoppedForMissingPermissions
        refreshPermissionState()

        guard permissionGranted, accessibilityPermissionGranted else {
            if isRunning {
                stopForMissingPermissions()
            } else {
                stoppedForMissingPermissions = true
                updateMissingPermissionStatus()
            }
            return
        }

        if shouldResume {
            start()
        }
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func refreshPermissionState() {
        permissionGranted = CGPreflightScreenCaptureAccess()
        accessibilityPermissionGranted = AccessibilityRegionResolver.isTrusted
    }

    private func updateMissingPermissionStatus() {
        switch (permissionGranted, accessibilityPermissionGranted) {
        case (false, false):
            status = "Screen & System Audio Recording and Accessibility permissions required"
        case (false, true):
            status = "Screen & System Audio Recording permission required"
        case (true, false):
            status = "Accessibility permission required"
        case (true, true):
            status = "Ready"
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            tick()
            let interval = settings.configuration.interaction.pollingInterval
            try? await Task.sleep(for: duration(seconds: interval))
        }
    }

    private func tick() {
        webExtensions.dismissUnpinnedResultsIfNeeded()
        let modifiersSatisfied = requiredModifiersArePressed()
        guard modifiersSatisfied else {
            if modifierKeysWereSatisfied || anchorPoint != nil || scanTask != nil {
                suspendForRequiredModifiers()
            } else {
                updateStatus(requiredModifiersStatus())
            }
            modifierKeysWereSatisfied = false
            return
        }

        if !modifierKeysWereSatisfied {
            modifierKeysWereSatisfied = true
            guard let pointer = CGEvent(source: nil)?.location else { return }
            resetHover(at: pointer, now: clock.now)
            beginScan(at: pointer)
            return
        }

        guard let pointer = CGEvent(source: nil)?.location else { return }
        if webExtensions.shouldKeepVisible(at: pointer) {
            return
        }
        let now = clock.now
        let interaction = settings.configuration.interaction
        let movementThreshold = CGFloat(interaction.movementThreshold)

        if let anchorPoint, hypot(pointer.x - anchorPoint.x, pointer.y - anchorPoint.y) > movementThreshold {
            if webExtensions.isPointerMovingTowardResults(from: anchorPoint, to: pointer) { return }
            if let cachedRecognitionAt,
               cachedRecognitionAt.duration(to: now) < duration(seconds: interaction.refreshInterval),
               cachedRecognitionID != nil {
                retargetCachedRecognition(at: pointer, now: now)
                return
            }
            resetHover(at: pointer, now: now)
            return
        }

        if anchorPoint == nil {
            resetHover(at: pointer, now: now)
            return
        }

        let stableDuration = stableSince.duration(to: now)
        let refreshDue = lastRefreshAt.duration(to: now) >= duration(seconds: interaction.refreshInterval)
        if stableDuration >= duration(seconds: interaction.scanDelay),
           scanTask == nil,
           !hasAttemptedScanAtAnchor || refreshDue {
            beginScan(at: pointer)
        }
    }

    private func suspendForRequiredModifiers() {
        scanTask?.cancel()
        scanTask = nil
        scanTaskID = nil
        anchorPoint = nil
        hasAttemptedScanAtAnchor = false
        hierarchy = nil
        clearRecognitionCache()
        currentSelection = nil
        overlay.hide()
        webExtensions.hide()
        updateStatus(requiredModifiersStatus())
    }

    private func requiredModifiersArePressed() -> Bool {
        Self.modifiersSatisfied(
            settings.configuration.interaction.requiredModifiers,
            flags: CGEventSource.flagsState(.combinedSessionState)
        )
    }

    nonisolated static func modifiersSatisfied(
        _ requiredModifiers: [RecognitionModifier],
        flags: CGEventFlags
    ) -> Bool {
        requiredModifiers.allSatisfy { modifier in
            switch modifier {
            case .command: flags.contains(.maskCommand)
            case .option: flags.contains(.maskAlternate)
            case .control: flags.contains(.maskControl)
            case .shift: flags.contains(.maskShift)
            case .globe: flags.contains(.maskSecondaryFn)
            }
        }
    }

    nonisolated static func modifiersSatisfied(
        _ requiredModifiers: [RecognitionModifier],
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        requiredModifiers.allSatisfy { modifier in
            switch modifier {
            case .command: flags.contains(.command)
            case .option: flags.contains(.option)
            case .control: flags.contains(.control)
            case .shift: flags.contains(.shift)
            case .globe: flags.contains(.function)
            }
        }
    }

    private func requiredModifiersStatus() -> String {
        let symbols = settings.configuration.interaction.requiredModifiers.map(\.symbol).joined()
        return symbols.isEmpty ? "Hover over visible text" : "Hold \(symbols) to recognize text"
    }

    private func updateStatus(_ value: String) {
        if status != value {
            status = value
        }
    }

    private func resetHover(at point: CGPoint, now: ContinuousClock.Instant) {
        anchorPoint = point
        stableSince = now
        hasAttemptedScanAtAnchor = false
        hierarchy = nil
        currentSelection = nil
        scanTask?.cancel()
        scanTask = nil
        scanTaskID = nil
        clearRecognitionCache()
        overlay.hide()
        webExtensions.suspendSourceOverlay()
        status = "Reading…"
    }

    private func retargetCachedRecognition(at point: CGPoint, now: ContinuousClock.Instant) {
        guard let cachedRecognitionID else {
            resetHover(at: point, now: now)
            return
        }

        anchorPoint = point
        stableSince = now
        hasAttemptedScanAtAnchor = true
        scanTask?.cancel()

        let taskID = UUID()
        scanTaskID = taskID
        let overlayConfiguration = settings.configuration.overlay
        let cachedCaptureTarget = self.cachedCaptureTarget
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if scanTaskID == taskID {
                    scanTask = nil
                    scanTaskID = nil
                }
            }

            if let cachedCaptureTarget {
                let targetIsValid = await captureService.targetIsStillValid(cachedCaptureTarget, at: point)
                guard !Task.isCancelled else { return }
                guard targetIsValid else {
                    resetHover(at: point, now: clock.now)
                    return
                }
            }

            let result = await ocrService.hierarchy(from: cachedRecognitionID, at: point)
            guard !Task.isCancelled else { return }
            switch result {
            case .unavailable:
                resetHover(at: point, now: clock.now)
            case .noHit:
                applyCachedNoHit(retargetedAt: point)
            case let .hit(hierarchy):
                applyCached(
                    hierarchy,
                    retargetedAt: point,
                    overlayConfiguration: overlayConfiguration
                )
            }
        }
    }

    private func beginScan(at point: CGPoint) {
        lastRefreshAt = clock.now
        hasAttemptedScanAtAnchor = true
        accessibilityPermissionGranted = AccessibilityRegionResolver.isTrusted
        guard accessibilityPermissionGranted else {
            stopForMissingPermissions()
            return
        }
        logger.debug("Starting hover scan at x=\(point.x, privacy: .public), y=\(point.y, privacy: .public)")
        let configuration = settings.configuration
        let taskID = UUID()
        scanTaskID = taskID
        scanTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if scanTaskID == taskID {
                    scanTask = nil
                    scanTaskID = nil
                }
            }

            do {
                let frame = try await captureService.capture(
                    around: point,
                    configuration: configuration.capture
                )
                try Task.checkCancellation()
                logger.debug("Capture region source: \(frame.regionSource.rawValue, privacy: .public)")
                if configuration.overlay.debugEnabled {
                    overlay.showCaptureRegion(
                        frame.globalRect,
                        source: frame.regionSource,
                        on: frame.displayID,
                        configuration: configuration.overlay
                    )
                }
                let recognition = try await ocrService.recognize(
                    frame: frame,
                    pointer: point,
                    configuration: configuration
                )
                try Task.checkCancellation()
                apply(
                    recognition,
                    scannedAt: point,
                    overlayConfiguration: configuration.overlay
                )
            } catch is CancellationError {
                return
            } catch where Task.isCancelled {
                return
            } catch CaptureError.ownApplicationWindow {
                hierarchy = nil
                currentSelection = nil
                overlay.hide()
                webExtensions.suspendSourceOverlay()
                status = requiredModifiersStatus()
                return
            } catch {
                hierarchy = nil
                currentSelection = nil
                overlay.hide()
                webExtensions.suspendSourceOverlay()

                if CaptureError.isPermissionDenied(error) {
                    permissionGranted = false
                    stopForMissingPermissions()
                    logger.error(
                        "Hover recognition stopped after ScreenCaptureKit reported that capture permission was declined"
                    )
                    return
                }

                refreshPermissionState()
                if !permissionGranted || !accessibilityPermissionGranted {
                    stopForMissingPermissions()
                } else {
                    status = error.localizedDescription
                }
                logger.error("Hover scan failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func apply(
        _ recognition: OCRRecognition,
        scannedAt point: CGPoint,
        overlayConfiguration: HoveryConfiguration.Overlay
    ) {
        guard pointerRemainsNear(point) else { return }
        cachedRecognitionID = recognition.identifier
        cachedRecognitionAt = recognition.identifier == nil ? nil : clock.now
        cachedCaptureTarget = recognition.target
        applyHierarchy(
            recognition.hierarchy,
            at: point,
            overlayConfiguration: overlayConfiguration
        )
    }

    private func applyCached(
        _ result: HoverHierarchy,
        retargetedAt point: CGPoint,
        overlayConfiguration: HoveryConfiguration.Overlay
    ) {
        guard pointerRemainsNear(point) else { return }
        guard hierarchy != result else { return }
        applyHierarchy(result, at: point, overlayConfiguration: overlayConfiguration)
    }

    private func applyCachedNoHit(retargetedAt point: CGPoint) {
        guard pointerRemainsNear(point) else { return }
        guard hierarchy != nil || currentSelection != nil else {
            status = "No text under pointer"
            return
        }
        hierarchy = nil
        currentSelection = nil
        overlay.clearSelection()
        webExtensions.suspendSourceOverlay()
        status = "No text under pointer"
    }

    private func pointerRemainsNear(_ point: CGPoint) -> Bool {
        let interaction = settings.configuration.interaction
        let resultMovementTolerance = CGFloat(
            interaction.movementThreshold * interaction.resultMovementToleranceMultiplier
        )
        guard let currentPoint = CGEvent(source: nil)?.location,
              hypot(currentPoint.x - point.x, currentPoint.y - point.y) <= resultMovementTolerance else {
            return false
        }
        return true
    }

    private func applyHierarchy(
        _ result: HoverHierarchy?,
        at point: CGPoint,
        overlayConfiguration: HoveryConfiguration.Overlay
    ) {
        hierarchy = result
        guard let result else {
            currentSelection = nil
            overlay.clearSelection()
            webExtensions.suspendSourceOverlay()
            status = "No text under pointer"
            logger.debug("No text candidate matched the pointer")
            return
        }

        let selections = SemanticLevel.allCases.compactMap { result.selections[$0] }
        guard !selections.isEmpty else {
            currentSelection = nil
            overlay.clearSelection()
            webExtensions.suspendSourceOverlay()
            status = "No text under pointer"
            return
        }

        currentSelection = result.selection(for: .word)
        webExtensions.present(hierarchy: result, pointer: point)
        if overlayConfiguration.debugEnabled {
            overlay.show(
                selections,
                pointer: point,
                on: result.displayID,
                configuration: overlayConfiguration
            )
        }
        status = "Showing \(selections.count) semantic levels"
        logger.notice("Hover hierarchy ready with \(result.selections.count, privacy: .public) semantic levels")
    }

    private func duration(seconds: TimeInterval) -> Duration {
        .milliseconds(Int64((seconds * 1_000).rounded()))
    }

    private func startContentMutationMonitoring() {
        guard contentMutationMonitor == nil else { return }
        let mutationEvents: NSEvent.EventTypeMask = [
            .scrollWheel,
            .keyDown,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]
        contentMutationMonitor = NSEvent.addGlobalMonitorForEvents(matching: mutationEvents) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateCachedContent()
            }
        }
        modifierEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            let flags = event.modifierFlags
            Task { @MainActor [weak self] in
                self?.modifierFlagsDidChange(flags)
            }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invalidateCachedContent()
            }
        }
    }

    private func stopContentMutationMonitoring() {
        if let contentMutationMonitor {
            NSEvent.removeMonitor(contentMutationMonitor)
            self.contentMutationMonitor = nil
        }
        if let modifierEventMonitor {
            NSEvent.removeMonitor(modifierEventMonitor)
            self.modifierEventMonitor = nil
        }
        if let workspaceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
            self.workspaceActivationObserver = nil
        }
    }

    private func invalidateCachedContent() {
        guard isRunning else { return }
        guard cachedRecognitionID != nil || hierarchy != nil else { return }
        guard let point = CGEvent(source: nil)?.location else { return }
        resetHover(at: point, now: clock.now)
    }

    private func modifierFlagsDidChange(_ flags: NSEvent.ModifierFlags) {
        guard isRunning else { return }
        let modifiersSatisfied = Self.modifiersSatisfied(
            settings.configuration.interaction.requiredModifiers,
            flags: flags
        )
        guard modifiersSatisfied != modifierKeysWereSatisfied else { return }
        modifierKeysWereSatisfied = modifiersSatisfied

        guard modifiersSatisfied else {
            suspendForRequiredModifiers()
            return
        }
        guard let pointer = CGEvent(source: nil)?.location else { return }
        resetHover(at: pointer, now: clock.now)
        beginScan(at: pointer)
    }

    private func clearRecognitionCache() {
        let identifier = cachedRecognitionID
        cachedRecognitionID = nil
        cachedRecognitionAt = nil
        cachedCaptureTarget = nil
        if let identifier {
            Task { [ocrService] in
                await ocrService.discardRecognition(identifier)
            }
        }
    }

    private func stopForMissingPermissions() {
        loopTask?.cancel()
        loopTask = nil
        scanTask?.cancel()
        scanTask = nil
        scanTaskID = nil
        isRunning = false
        anchorPoint = nil
        hierarchy = nil
        clearRecognitionCache()
        currentSelection = nil
        overlay.hide()
        webExtensions.hide()
        stoppedForMissingPermissions = true
        stopContentMutationMonitoring()
        updateMissingPermissionStatus()
    }
}
