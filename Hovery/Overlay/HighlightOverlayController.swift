import AppKit
import CoreGraphics
import OSLog

@MainActor
final class HighlightOverlayController {
    private var panel: NSPanel?
    private var overlayView: HighlightOverlayView?
    private var backdropView: ExtensionOverlayBackdropView?
    private var activeDisplayID: CGDirectDisplayID?
    private let logger = Logger(subsystem: "app.hovery.Hovery", category: "Overlay")

    var panelFrameForTesting: CGRect? {
        panel?.frame
    }

    var panelLevelForTesting: NSWindow.Level? {
        panel?.level
    }

    func showCaptureRegion(
        _ region: CGRect,
        source: CaptureRegionSource,
        on displayID: CGDirectDisplayID,
        configuration: HoveryConfiguration.Overlay = .init()
    ) {
        guard let screen = NSScreen.screen(for: displayID) else {
            hide()
            return
        }

        if panel == nil || activeDisplayID != displayID {
            rebuildPanel(for: screen, displayID: displayID)
        }

        guard let panel, let overlayView else { return }
        overlayView.configuration = configuration
        overlayView.extensionOverlayConfiguration = nil
        overlayView.extensionSelectionStyles = [:]
        backdropView?.selections = []
        overlayView.initialRegion = convert(region, displayID: displayID)
        overlayView.initialRegionSource = source
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    func show(
        _ selections: [SemanticSelection],
        pointer: CGPoint,
        on displayID: CGDirectDisplayID,
        configuration: HoveryConfiguration.Overlay = .init()
    ) {
        guard let screen = NSScreen.screen(for: displayID) else {
            hide()
            return
        }

        if panel == nil || activeDisplayID != displayID {
            rebuildPanel(for: screen, displayID: displayID)
        }

        guard let panel, let overlayView else { return }
        overlayView.configuration = configuration
        overlayView.extensionOverlayConfiguration = nil
        overlayView.extensionSelectionStyles = [:]
        backdropView?.selections = []
        overlayView.selections = selections.map {
            convert($0, displayID: displayID, screen: screen)
        }
        overlayView.pointerLocation = convert(pointer, displayID: displayID)
        panel.level = .screenSaver
        panel.orderFrontRegardless()
    }

    func showExtensionSelections(
        _ selections: [ExtensionOverlaySelection],
        on displayID: CGDirectDisplayID,
        configuration: HoveryConfiguration.ExtensionOverlay
    ) {
        guard configuration.enabled, let screen = NSScreen.screen(for: displayID) else {
            hide()
            return
        }

        if panel == nil || activeDisplayID != displayID {
            rebuildPanel(for: screen, displayID: displayID)
        }

        guard let panel, let overlayView, let backdropView else { return }
        let convertedSelections = selections.map {
            ExtensionOverlaySelection(
                selection: convert($0.selection, displayID: displayID, screen: screen),
                style: $0.style
            )
        }
        overlayView.extensionOverlayConfiguration = configuration
        overlayView.initialRegion = nil
        overlayView.initialRegionSource = nil
        overlayView.pointerLocation = nil
        overlayView.extensionSelectionStyles = Dictionary(
            uniqueKeysWithValues: convertedSelections.map { ($0.selection.level, $0.style) }
        )
        overlayView.selections = convertedSelections.map(\.selection)
        backdropView.configuration = configuration
        backdropView.selections = convertedSelections
        panel.level = .statusBar
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
        overlayView?.selections = []
        overlayView?.pointerLocation = nil
        overlayView?.initialRegion = nil
        overlayView?.initialRegionSource = nil
        overlayView?.extensionOverlayConfiguration = nil
        overlayView?.extensionSelectionStyles = [:]
        backdropView?.selections = []
    }

    func clearSelection() {
        overlayView?.selections = []
        overlayView?.pointerLocation = nil
        backdropView?.selections = []
    }

    private func rebuildPanel(for screen: NSScreen, displayID: CGDirectDisplayID) {
        panel?.close()

        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.autoresizingMask = [.width, .height]
        let backdropView = ExtensionOverlayBackdropView(frame: container.bounds)
        backdropView.autoresizingMask = [.width, .height]
        let view = HighlightOverlayView(frame: container.bounds)
        view.autoresizingMask = [.width, .height]
        container.addSubview(backdropView)
        container.addSubview(view)

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        logger.notice(
            "Overlay moved to display \(displayID, privacy: .public), frame \(String(describing: screen.frame), privacy: .public)"
        )

        self.panel = panel
        overlayView = view
        self.backdropView = backdropView
        activeDisplayID = displayID
    }

    private func convert(
        _ selection: SemanticSelection,
        displayID: CGDirectDisplayID,
        screen: NSScreen
    ) -> SemanticSelection {
        let displayBounds = CGDisplayBounds(displayID)
        let converted = selection.regions.map { region in
            HighlightRegion(points: region.points.map { point in
                CGPoint(
                    x: point.x - displayBounds.minX,
                    y: displayBounds.maxY - point.y
                )
            })
        }
        return SemanticSelection(
            level: selection.level,
            text: selection.text,
            regions: converted,
            confidence: selection.confidence
        )
    }

    private func convert(_ rect: CGRect, displayID: CGDirectDisplayID) -> CGRect {
        let displayBounds = CGDisplayBounds(displayID)
        return CGRect(
            x: rect.minX - displayBounds.minX,
            y: displayBounds.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func convert(_ point: CGPoint, displayID: CGDirectDisplayID) -> CGPoint {
        let displayBounds = CGDisplayBounds(displayID)
        return CGPoint(
            x: point.x - displayBounds.minX,
            y: displayBounds.maxY - point.y
        )
    }
}

@MainActor
private final class ExtensionOverlayBackdropView: NSView {
    var configuration = HoveryConfiguration.ExtensionOverlay() {
        didSet { rebuildEffects() }
    }

    var selections: [ExtensionOverlaySelection] = [] {
        didSet { rebuildEffects() }
    }

    override var isOpaque: Bool { false }

    private func rebuildEffects() {
        subviews.forEach { $0.removeFromSuperview() }
        for item in selections {
            let materialName = item.style.material ?? configuration.material
            guard materialName != "none",
                  let material = NSVisualEffectView.Material(webExtensionName: materialName) else { continue }
            let path = CGMutablePath()
            var hasRegion = false
            for region in item.selection.regions where region.points.count >= 3 {
                hasRegion = true
                path.move(to: region.points[0])
                for point in region.points.dropFirst() {
                    path.addLine(to: point)
                }
                path.closeSubpath()
            }
            guard hasRegion else { continue }

            let effectView = NSVisualEffectView(frame: bounds)
            effectView.autoresizingMask = [.width, .height]
            effectView.material = material
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.alphaValue = CGFloat(
                min(max(item.style.materialOpacity ?? configuration.materialOpacity, 0), 1)
            )
            effectView.wantsLayer = true

            let mask = CAShapeLayer()
            mask.frame = effectView.bounds
            mask.path = path
            effectView.layer?.mask = mask
            addSubview(effectView)
        }
    }
}

private extension NSScreen {
    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return number.uint32Value == displayID
        }
    }
}
