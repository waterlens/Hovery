import AppKit
import Foundation

struct OverlayRGBAColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    var color: NSColor {
        NSColor(
            srgbRed: CGFloat(min(max(red, 0), 1)),
            green: CGFloat(min(max(green, 0), 1)),
            blue: CGFloat(min(max(blue, 0), 1)),
            alpha: CGFloat(min(max(alpha, 0), 1))
        )
    }
}

struct WebExtensionOverlayStyle: Equatable, Sendable {
    var fillColor: OverlayRGBAColor? = nil
    var strokeColor: OverlayRGBAColor? = nil
    var lineWidth: Double? = nil
    var lineDash: [Double]? = nil
    var lineCap: String? = nil
    var material: String? = nil
    var materialOpacity: Double? = nil
    var shadowColor: OverlayRGBAColor? = nil
    var shadowRadius: Double? = nil
    var shadowOffsetX: Double? = nil
    var shadowOffsetY: Double? = nil
}

struct WebExtensionOverlayItem: Equatable, Sendable {
    let selectionID: String
    let style: WebExtensionOverlayStyle
}

struct ExtensionOverlaySelection {
    let selection: SemanticSelection
    let style: WebExtensionOverlayStyle
}

extension NSVisualEffectView.Material {
    init?(webExtensionName: String) {
        switch webExtensionName {
        case "titlebar": self = .titlebar
        case "selection": self = .selection
        case "menu": self = .menu
        case "popover": self = .popover
        case "sidebar": self = .sidebar
        case "headerView": self = .headerView
        case "sheet": self = .sheet
        case "windowBackground": self = .windowBackground
        case "hudWindow": self = .hudWindow
        case "fullScreenUI": self = .fullScreenUI
        case "toolTip": self = .toolTip
        case "contentBackground": self = .contentBackground
        case "underWindowBackground": self = .underWindowBackground
        case "underPageBackground": self = .underPageBackground
        default: return nil
        }
    }
}
