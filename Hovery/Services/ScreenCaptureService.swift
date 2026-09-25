import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case noDisplay
    case ownApplicationWindow

    static func isPermissionDenied(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        if cocoaError.domain == SCStreamErrorDomain,
           cocoaError.code == SCStreamError.Code.userDeclined.rawValue {
            return true
        }

        if let underlyingError = cocoaError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isPermissionDenied(underlyingError)
        }

        return false
    }

    var errorDescription: String? {
        switch self {
        case .noDisplay: String(localized: "No display contains the pointer.")
        case .ownApplicationWindow: String(localized: "Hovery does not capture its own windows.")
        }
    }
}

struct CaptureRegionResolution: Equatable, Sendable {
    var rect: CGRect
    var source: CaptureRegionSource
}

private struct WindowTarget: Sendable {
    var windowID: CGWindowID
    var frame: CGRect
    var ownerPID: pid_t
}

private struct ShareableContentBox: @unchecked Sendable {
    var content: SCShareableContent
}

actor ScreenCaptureService {
    private var cachedContent: SCShareableContent?
    private var contentRefreshedAt = Date.distantPast
    private var contentRefreshTask: Task<ShareableContentBox, Error>?

    func prepare(cacheLifetime: TimeInterval) async {
        _ = try? await shareableContent(cacheLifetime: cacheLifetime)
    }

    func capture(
        around globalPoint: CGPoint,
        configuration: HoveryConfiguration.Capture = .init()
    ) async throws -> CapturedFrame {
        guard !(await Self.pointerIsOverOwnInteractiveWindow()) else {
            throw CaptureError.ownApplicationWindow
        }

        let content = try await shareableContent(cacheLifetime: configuration.contentCacheLifetime)
        guard let display = content.displays.first(where: {
            CGDisplayBounds($0.displayID).contains(globalPoint)
        }) else {
            throw CaptureError.noDisplay
        }

        let displayBounds = CGDisplayBounds(display.displayID)
        let fallbackSize = CGSize(
            width: configuration.width,
            height: configuration.height
        )
        let window = Self.topmostWindow(at: globalPoint)
        let element: AccessibilityRegionResolution?
        if let window {
            element = await AccessibilityRegionResolver.region(
                at: globalPoint,
                within: window.frame.intersection(displayBounds),
                ownerPID: window.ownerPID,
                configuration: configuration
            )
        } else {
            element = nil
        }
        let region = Self.resolveCaptureRegion(
            around: globalPoint,
            displayBounds: displayBounds,
            elementRect: element?.frame,
            windowRect: window?.frame,
            fallbackSize: fallbackSize
        )
        let cropRect = region.rect
        let localRect = cropRect.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)

        let ownApplication = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: ownApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )

        let nativeScale = CGFloat(display.width) / displayBounds.width
        let outputScale = min(
            nativeScale,
            CGFloat(configuration.maximumPixelWidth) / max(cropRect.width, 1),
            CGFloat(configuration.maximumPixelHeight) / max(cropRect.height, 1)
        )

        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.sourceRect = localRect
        streamConfiguration.width = max(1, Int((cropRect.width * outputScale).rounded()))
        streamConfiguration.height = max(1, Int((cropRect.height * outputScale).rounded()))
        streamConfiguration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: streamConfiguration
        )

        return CapturedFrame(
            image: image,
            globalRect: cropRect,
            displayID: display.displayID,
            regionSource: region.source,
            target: CaptureTarget(
                source: region.source,
                captureRect: cropRect,
                windowID: window?.windowID,
                ownerPID: window?.ownerPID,
                windowFrame: window?.frame,
                accessibilityElementID: region.source == .accessibilityElement
                    ? element?.elementIdentifier
                    : nil
            )
        )
    }

    func targetIsStillValid(_ target: CaptureTarget, at point: CGPoint) -> Bool {
        guard target.captureRect.contains(point) else { return false }
        guard let windowID = target.windowID else {
            return target.source == .fixedFallback
        }
        guard let current = Self.topmostWindow(at: point),
              current.windowID == windowID,
              current.ownerPID == target.ownerPID else {
            return false
        }
        if let windowFrame = target.windowFrame, current.frame != windowFrame {
            return false
        }
        return true
    }

    private func shareableContent(cacheLifetime: TimeInterval) async throws -> SCShareableContent {
        if let cachedContent, Date().timeIntervalSince(contentRefreshedAt) < cacheLifetime {
            return cachedContent
        }

        if let contentRefreshTask {
            return try await contentRefreshTask.value.content
        }

        let refreshTask = Task {
            ShareableContentBox(
                content: try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: true
                )
            )
        }
        contentRefreshTask = refreshTask
        defer { contentRefreshTask = nil }
        let content = try await refreshTask.value.content
        cachedContent = content
        contentRefreshedAt = Date()
        return content
    }

    static func resolveCaptureRegion(
        around point: CGPoint,
        displayBounds: CGRect,
        elementRect: CGRect?,
        windowRect: CGRect?,
        fallbackSize: CGSize
    ) -> CaptureRegionResolution {
        if let elementRect,
           let clipped = validIntersection(elementRect, displayBounds),
           clipped.contains(point) {
            return CaptureRegionResolution(rect: clipped, source: .accessibilityElement)
        }

        if let windowRect,
           let clipped = validIntersection(windowRect, displayBounds),
           clipped.contains(point) {
            return CaptureRegionResolution(rect: clipped, source: .window)
        }

        return CaptureRegionResolution(
            rect: centeredCrop(around: point, size: fallbackSize, within: displayBounds),
            source: .fixedFallback
        )
    }

    private static func validIntersection(_ lhs: CGRect, _ rhs: CGRect) -> CGRect? {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return nil
        }
        return intersection
    }

    private static func centeredCrop(around point: CGPoint, size: CGSize, within bounds: CGRect) -> CGRect {
        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let x = min(max(point.x - width / 2, bounds.minX), bounds.maxX - width)
        let y = min(max(point.y - height / 2, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func topmostWindow(at point: CGPoint) -> WindowTarget? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else {
            return nil
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for info in windowInfo {
            guard let windowID = (info[kCGWindowNumber] as? NSNumber)?.uint32Value,
                  let ownerPID = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  ownerPID != ownPID,
                  let alpha = (info[kCGWindowAlpha] as? NSNumber)?.doubleValue,
                  alpha > 0,
                  let boundsValue = info[kCGWindowBounds] else {
                continue
            }

            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsValue as! CFDictionary, &frame),
                  frame.width > 0,
                  frame.height > 0,
                  frame.contains(point) else {
                continue
            }

            return WindowTarget(windowID: windowID, frame: frame, ownerPID: ownerPID)
        }

        return nil
    }

    @MainActor
    private static func pointerIsOverOwnInteractiveWindow() -> Bool {
        let pointer = NSEvent.mouseLocation
        return NSApp.windows.contains { window in
            window.isVisible
                && !window.ignoresMouseEvents
                && window.alphaValue > 0
                && window.frame.contains(pointer)
        }
    }
}
