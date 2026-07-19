import ApplicationServices
import CoreGraphics
import Foundation

struct AccessibilityRegionCandidate: Equatable, Sendable {
    var frame: CGRect
    var role: String
    var depth: Int
    var elementIdentifier: UInt? = nil
}

struct AccessibilityRegionResolution: Equatable, Sendable {
    var frame: CGRect
    var elementIdentifier: UInt?
}

enum AccessibilityRegionResolver {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func requestPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @MainActor
    static func region(
        at point: CGPoint,
        within windowFrame: CGRect,
        ownerPID: pid_t,
        configuration: HoveryConfiguration.Capture
    ) -> AccessibilityRegionResolution? {
        guard isTrusted, windowFrame.width > 0, windowFrame.height > 0 else {
            return nil
        }

        let systemWide = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(point.x),
            Float(point.y),
            &hitElement
        ) == .success,
        var element = hitElement else {
            return nil
        }

        var hitPID: pid_t = 0
        guard AXUIElementGetPid(element, &hitPID) == .success, hitPID == ownerPID else {
            return nil
        }

        var candidates: [AccessibilityRegionCandidate] = []
        for depth in 0..<configuration.accessibilityMaximumAncestorDepth {
            let role = stringAttribute(kAXRoleAttribute as CFString, from: element) ?? ""
            if let frame = frame(of: element) {
                candidates.append(AccessibilityRegionCandidate(
                    frame: frame,
                    role: role,
                    depth: depth,
                    elementIdentifier: CFHash(element)
                ))
            }

            guard let parent = elementAttribute(kAXParentAttribute as CFString, from: element) else {
                break
            }
            element = parent
        }

        return chooseRegionResolution(
            from: candidates,
            at: point,
            within: windowFrame,
            configuration: configuration
        )
    }

    static func chooseRegion(
        from candidates: [AccessibilityRegionCandidate],
        at point: CGPoint,
        within windowFrame: CGRect,
        configuration: HoveryConfiguration.Capture
    ) -> CGRect? {
        chooseRegionResolution(
            from: candidates,
            at: point,
            within: windowFrame,
            configuration: configuration
        )?.frame
    }

    static func chooseRegionResolution(
        from candidates: [AccessibilityRegionCandidate],
        at point: CGPoint,
        within windowFrame: CGRect,
        configuration: HoveryConfiguration.Capture
    ) -> AccessibilityRegionResolution? {
        let windowRoles = [kAXWindowRole as String, kAXApplicationRole as String]
        let validCandidates = candidates
            .filter { !windowRoles.contains($0.role) }
            .compactMap { candidate -> AccessibilityRegionCandidate? in
                let clipped = candidate.frame.intersection(windowFrame)
                guard !clipped.isNull,
                      clipped.width > 0,
                      clipped.height > 0,
                      clipped.contains(point) else {
                    return nil
                }
                return AccessibilityRegionCandidate(
                    frame: clipped,
                    role: candidate.role,
                    depth: candidate.depth,
                    elementIdentifier: candidate.elementIdentifier
                )
            }
            .sorted { $0.depth < $1.depth }

        guard let selected = validCandidates.first(where: {
            $0.frame.width >= configuration.accessibilityMinimumWidth
                && $0.frame.height >= configuration.accessibilityMinimumHeight
        }) ?? validCandidates.last else {
            return nil
        }

        let padded = selected.frame.insetBy(
            dx: -configuration.accessibilityPadding,
            dy: -configuration.accessibilityPadding
        )
        let clipped = padded.intersection(windowFrame)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }
        return AccessibilityRegionResolution(
            frame: clipped,
            elementIdentifier: selected.elementIdentifier
        )
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let positionValue = valueAttribute(kAXPositionAttribute as CFString, from: element),
              let sizeValue = valueAttribute(kAXSizeAttribute as CFString, from: element),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              position.x.isFinite,
              position.y.isFinite,
              size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0 else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        valueAttribute(attribute, from: element) as? String
    }

    private static func elementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        guard let value = valueAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private static func valueAttribute(_ attribute: CFString, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }
}
