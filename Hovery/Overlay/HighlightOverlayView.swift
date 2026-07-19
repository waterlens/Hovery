import AppKit

final class HighlightOverlayView: NSView {
    var configuration = HoveryConfiguration.Overlay() {
        didSet { needsDisplay = true }
    }

    var initialRegion: CGRect? {
        didSet { needsDisplay = true }
    }

    var initialRegionSource: CaptureRegionSource? {
        didSet { needsDisplay = true }
    }

    var selections: [SemanticSelection] = [] {
        didSet { needsDisplay = true }
    }

    var pointerLocation: CGPoint? {
        didSet { needsDisplay = true }
    }

    var extensionOverlayConfiguration: HoveryConfiguration.ExtensionOverlay? {
        didSet { needsDisplay = true }
    }

    var extensionSelectionStyles: [SemanticLevel: WebExtensionOverlayStyle] = [:] {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawInitialRegion()
        let drawingOrder = selections.sorted { $0.level.rawValue > $1.level.rawValue }

        for selection in drawingOrder {
            let extensionStyle = extensionSelectionStyles[selection.level]
            for region in selection.regions where region.points.count >= 3 {
                let path = NSBezierPath()
                path.move(to: region.points[0])
                region.points.dropFirst().forEach { path.line(to: $0) }
                path.close()

                if extensionOverlayConfiguration != nil {
                    drawExtensionPath(path, style: extensionStyle ?? .init())
                } else {
                    let color = color(for: selection.level)
                    color.withAlphaComponent(CGFloat(configuration.selectionFillOpacity)).setFill()
                    path.fill()
                    color.withAlphaComponent(CGFloat(configuration.selectionStrokeOpacity)).setStroke()
                    path.lineWidth = CGFloat(configuration.selectionLineWidth)
                    path.stroke()
                }
            }
        }

        guard extensionOverlayConfiguration == nil else { return }
        let labelOrder = selections.sorted { $0.level.rawValue < $1.level.rawValue }
        let labelRects = levelLabelRects(for: labelOrder)
        for selection in labelOrder {
            guard let labelRect = labelRects[selection.level] else { continue }
            drawLabel(
                selection.level.displayName,
                in: labelRect,
                color: color(for: selection.level)
            )
        }
    }

    private func drawExtensionPath(_ path: NSBezierPath, style: WebExtensionOverlayStyle) {
        guard let extensionOverlayConfiguration else { return }
        let fillColor = style.fillColor?.color
            ?? NSColor.white.withAlphaComponent(CGFloat(extensionOverlayConfiguration.fillOpacity))
        let strokeColor = style.strokeColor?.color
            ?? NSColor.separatorColor.withAlphaComponent(CGFloat(extensionOverlayConfiguration.strokeOpacity))
        let lineWidth = max(0, style.lineWidth ?? extensionOverlayConfiguration.lineWidth)

        NSGraphicsContext.saveGraphicsState()
        if let shadowColor = style.shadowColor?.color {
            let shadow = NSShadow()
            shadow.shadowColor = shadowColor
            shadow.shadowBlurRadius = CGFloat(max(0, style.shadowRadius ?? 0))
            shadow.shadowOffset = NSSize(
                width: style.shadowOffsetX ?? 0,
                height: style.shadowOffsetY ?? 0
            )
            shadow.set()
        }

        fillColor.setFill()
        path.fill()
        if lineWidth > 0 {
            strokeColor.setStroke()
            path.lineWidth = CGFloat(lineWidth)
            if let lineDash = style.lineDash, !lineDash.isEmpty {
                let pattern = lineDash.map { CGFloat($0) }
                path.setLineDash(pattern, count: pattern.count, phase: 0)
            }
            switch style.lineCap {
            case "round": path.lineCapStyle = .round
            case "square": path.lineCapStyle = .square
            default: path.lineCapStyle = .butt
            }
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawInitialRegion() {
        guard let initialRegion, !initialRegion.isNull else { return }

        let path = NSBezierPath(
            roundedRect: initialRegion,
            xRadius: CGFloat(configuration.initialCornerRadius),
            yRadius: CGFloat(configuration.initialCornerRadius)
        )
        let color = NSColor.systemYellow
        color.withAlphaComponent(CGFloat(configuration.initialFillOpacity)).setFill()
        path.fill()
        color.withAlphaComponent(CGFloat(configuration.initialStrokeOpacity)).setStroke()
        path.lineWidth = CGFloat(configuration.initialLineWidth)
        let dashPattern = [
            CGFloat(configuration.initialDashLength),
            CGFloat(configuration.initialDashGap)
        ]
        path.setLineDash(
            dashPattern,
            count: dashPattern.count,
            phase: 0
        )
        path.stroke()

        if let initialRegionSource, let labelRect = initialRegionLabelRect() {
            drawLabel(initialRegionSource.displayName, in: labelRect, color: color)
        }
    }

    func labelRectsForTesting() -> [SemanticLevel: CGRect] {
        levelLabelRects(for: selections.sorted { $0.level.rawValue < $1.level.rawValue })
    }

    private func levelLabelRects(
        for orderedSelections: [SemanticSelection]
    ) -> [SemanticLevel: CGRect] {
        var occupiedRects = initialRegionLabelRect().map { [$0] } ?? []
        var result: [SemanticLevel: CGRect] = [:]

        for selection in orderedSelections {
            guard let anchorRect = anchorRect(for: selection) else { continue }
            let labelRect = placeLabel(
                size: labelSize(for: selection.level.displayName),
                beside: anchorRect,
                avoiding: occupiedRects
            )
            result[selection.level] = labelRect
            occupiedRects.append(labelRect)
        }

        return result
    }

    private func anchorRect(for selection: SemanticSelection) -> CGRect? {
        let regionRects = selection.regions
            .map(\.boundingRect)
            .filter { !$0.isNull && !$0.isEmpty }
        guard !regionRects.isEmpty else { return nil }
        guard let pointerLocation else { return regionRects.first }

        let containingRects = regionRects.filter { $0.contains(pointerLocation) }
        if let smallestContainingRect = containingRects.min(by: { area(of: $0) < area(of: $1) }) {
            return smallestContainingRect
        }

        return regionRects.min {
            squaredDistance(from: pointerLocation, to: $0)
                < squaredDistance(from: pointerLocation, to: $1)
        }
    }

    private func placeLabel(
        size: CGSize,
        beside anchorRect: CGRect,
        avoiding occupiedRects: [CGRect]
    ) -> CGRect {
        let gap = CGFloat(configuration.labelGap)
        let topY = anchorRect.maxY + gap
        let bottomY = anchorRect.minY - gap - size.height
        let leftX = anchorRect.minX - gap - size.width
        let rightX = anchorRect.maxX + gap

        var candidates = [
            CGRect(origin: CGPoint(x: anchorRect.minX, y: topY), size: size),
            CGRect(origin: CGPoint(x: anchorRect.maxX - size.width, y: topY), size: size),
            CGRect(origin: CGPoint(x: anchorRect.minX, y: bottomY), size: size),
            CGRect(origin: CGPoint(x: anchorRect.maxX - size.width, y: bottomY), size: size),
            CGRect(origin: CGPoint(x: rightX, y: anchorRect.maxY - size.height), size: size),
            CGRect(origin: CGPoint(x: leftX, y: anchorRect.maxY - size.height), size: size)
        ]

        for stackIndex in 1...max(occupiedRects.count, 1) {
            let stackDistance = CGFloat(stackIndex) * (size.height + gap)
            candidates.append(
                CGRect(
                    origin: CGPoint(x: anchorRect.minX, y: topY + stackDistance),
                    size: size
                )
            )
            candidates.append(
                CGRect(
                    origin: CGPoint(x: anchorRect.minX, y: bottomY - stackDistance),
                    size: size
                )
            )
        }

        let constrainedCandidates = candidates.map(constrainToVisibleBounds)
        let outsideCandidates = constrainedCandidates.filter { !$0.intersects(anchorRect) }
        let usableCandidates = outsideCandidates.isEmpty ? constrainedCandidates : outsideCandidates

        if let collisionFree = usableCandidates.first(where: {
            !collides($0, with: occupiedRects)
        }) {
            return collisionFree
        }

        return usableCandidates.min {
            overlapArea(of: $0, with: occupiedRects)
                < overlapArea(of: $1, with: occupiedRects)
        } ?? constrainToVisibleBounds(CGRect(origin: anchorRect.origin, size: size))
    }

    private func initialRegionLabelRect() -> CGRect? {
        guard let initialRegion, let initialRegionSource, !initialRegion.isNull else { return nil }
        let size = labelSize(for: initialRegionSource.displayName)
        return constrainToVisibleBounds(
            CGRect(
                x: initialRegion.minX,
                y: initialRegion.maxY - size.height,
                width: size.width,
                height: size.height
            )
        )
    }

    private func labelSize(for value: String) -> CGSize {
        let title = value as NSString
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(configuration.labelFontSize), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let textSize = title.size(withAttributes: attributes)
        return CGSize(
            width: textSize.width + CGFloat(configuration.labelHorizontalPadding * 2),
            height: textSize.height + CGFloat(configuration.labelVerticalPadding * 2)
        )
    }

    private func constrainToVisibleBounds(_ rect: CGRect) -> CGRect {
        let edgeInset = CGFloat(configuration.labelEdgeInset)
        let visibleBounds = bounds.insetBy(dx: edgeInset, dy: edgeInset)
        let x = rect.width <= visibleBounds.width
            ? min(max(rect.minX, visibleBounds.minX), visibleBounds.maxX - rect.width)
            : visibleBounds.minX
        let y = rect.height <= visibleBounds.height
            ? min(max(rect.minY, visibleBounds.minY), visibleBounds.maxY - rect.height)
            : visibleBounds.minY
        return CGRect(origin: CGPoint(x: x, y: y), size: rect.size)
    }

    private func collides(_ rect: CGRect, with occupiedRects: [CGRect]) -> Bool {
        let collisionInset = CGFloat(configuration.labelGap) / 2
        let collisionRect = rect.insetBy(dx: -collisionInset, dy: -collisionInset)
        return occupiedRects.contains { collisionRect.intersects($0) }
    }

    private func overlapArea(of rect: CGRect, with occupiedRects: [CGRect]) -> CGFloat {
        occupiedRects.reduce(0) { total, occupiedRect in
            let intersection = rect.intersection(occupiedRect)
            guard !intersection.isNull else { return total }
            return total + area(of: intersection)
        }
    }

    private func area(of rect: CGRect) -> CGFloat {
        rect.width * rect.height
    }

    private func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let horizontalDistance: CGFloat
        if point.x < rect.minX {
            horizontalDistance = rect.minX - point.x
        } else if point.x > rect.maxX {
            horizontalDistance = point.x - rect.maxX
        } else {
            horizontalDistance = 0
        }

        let verticalDistance: CGFloat
        if point.y < rect.minY {
            verticalDistance = rect.minY - point.y
        } else if point.y > rect.maxY {
            verticalDistance = point.y - rect.maxY
        } else {
            verticalDistance = 0
        }

        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }

    private func drawLabel(_ value: String, in labelRect: CGRect, color: NSColor) {
        let title = value as NSString
        let font = NSFont.monospacedSystemFont(ofSize: CGFloat(configuration.labelFontSize), weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]

        let background = NSBezierPath(
            roundedRect: labelRect,
            xRadius: CGFloat(configuration.labelCornerRadius),
            yRadius: CGFloat(configuration.labelCornerRadius)
        )
        color.withAlphaComponent(CGFloat(configuration.labelBackgroundOpacity)).setFill()
        background.fill()
        title.draw(
            at: CGPoint(
                x: labelRect.minX + CGFloat(configuration.labelHorizontalPadding),
                y: labelRect.minY + CGFloat(configuration.labelVerticalPadding)
            ),
            withAttributes: attributes
        )
    }

    private func color(for level: SemanticLevel) -> NSColor {
        switch level {
        case .word: .systemBlue
        case .sentence: .systemTeal
        case .paragraph: .systemOrange
        case .block: .systemPurple
        }
    }
}
