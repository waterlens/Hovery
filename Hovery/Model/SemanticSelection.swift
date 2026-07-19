import CoreGraphics
import Foundation

enum SemanticLevel: Int, CaseIterable, Codable, Sendable {
    case word
    case sentence
    case paragraph
    case block

    var displayName: String {
        switch self {
        case .word: "WORD"
        case .sentence: "SENTENCE"
        case .paragraph: "PARAGRAPH"
        case .block: "BLOCK"
        }
    }

}

struct HighlightRegion: Equatable, Sendable {
    var points: [CGPoint]

    var boundingRect: CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }

    static func rectangle(_ rect: CGRect) -> HighlightRegion {
        HighlightRegion(points: [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ])
    }
}

struct SemanticSelection: Equatable, Sendable {
    var level: SemanticLevel
    var text: String
    var regions: [HighlightRegion]
    var confidence: Float

    var boundingRect: CGRect {
        regions.reduce(.null) { $0.union($1.boundingRect) }
    }
}

struct HoverHierarchy: Equatable, Sendable {
    var displayID: CGDirectDisplayID
    var selections: [SemanticLevel: SemanticSelection]

    func selection(for desiredLevel: SemanticLevel) -> SemanticSelection? {
        if let exact = selections[desiredLevel] {
            return exact
        }

        let lower = SemanticLevel.allCases
            .filter { $0.rawValue < desiredLevel.rawValue }
            .sorted { $0.rawValue > $1.rawValue }
            .first { selections[$0] != nil }
        if let lower {
            return selections[lower]
        }

        return SemanticLevel.allCases
            .filter { $0.rawValue > desiredLevel.rawValue }
            .sorted { $0.rawValue < $1.rawValue }
            .first { selections[$0] != nil }
            .flatMap { selections[$0] }
    }
}

struct CapturedFrame: @unchecked Sendable {
    var image: CGImage
    var globalRect: CGRect
    var displayID: CGDirectDisplayID
    var regionSource: CaptureRegionSource = .fixedFallback
    var target: CaptureTarget? = nil

    var scaleX: CGFloat {
        CGFloat(image.width) / globalRect.width
    }

    var scaleY: CGFloat {
        CGFloat(image.height) / globalRect.height
    }
}

struct CaptureTarget: Equatable, Sendable {
    var source: CaptureRegionSource
    var captureRect: CGRect
    var windowID: CGWindowID?
    var ownerPID: pid_t?
    var windowFrame: CGRect?
    var accessibilityElementID: UInt?
}

enum CaptureRegionSource: String, Sendable {
    case accessibilityElement
    case window
    case fixedFallback

    var displayName: String {
        switch self {
        case .accessibilityElement: "AX ELEMENT"
        case .window: "WINDOW"
        case .fixedFallback: "FALLBACK"
        }
    }
}
