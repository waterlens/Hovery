import AppKit
import XCTest
@testable import Hovery

final class ResultsPanelTests: XCTestCase {
    private enum TestLayout {
        static let panelSize = CGSize(width: 520, height: 240)
        static let scale: CGFloat = 2
        /// A quarter of a pixel's coverage: enough for differences in anti-aliasing, but not for
        /// corners of a different shape.
        static let coverageTolerance = 64
    }

    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HoveryResultsPanelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    /// The window server draws the material behind the panel in the shape of its mask, and leaves
    /// the window's shadow out of that shape. A mask without the panel's corners makes them look square.
    @MainActor
    func testMaterialMaskMatchesTheRoundedCorners() throws {
        let settings = HoverySettings(configurationURL: temporaryDirectory.appendingPathComponent("config.toml"))
        let manager = WebExtensionCoordinator(settings: settings)
        let window = try XCTUnwrap(manager.resultsWindowForTesting)
        let material = try XCTUnwrap(window.contentView as? NSVisualEffectView)
        let layer = try XCTUnwrap(material.layer)

        for cornerRadius in [12.0, 30.0] {
            settings.update { $0.resultsPresentation.cornerRadius = cornerRadius }
            XCTAssertEqual(layer.cornerRadius, CGFloat(cornerRadius))
            let mask = try XCTUnwrap(material.maskImage)
            let maskCoverage = try coverage { _, bounds in
                mask.draw(in: bounds)
            }
            let layerCoverage = try coverage { context, bounds in
                let shape = CALayer()
                shape.frame = bounds
                shape.backgroundColor = .black
                shape.cornerRadius = layer.cornerRadius
                shape.cornerCurve = layer.cornerCurve
                shape.render(in: context)
            }
            let difference = zip(maskCoverage, layerCoverage).map { abs(Int($0) - Int($1)) }.max() ?? 0
            XCTAssertLessThan(difference, TestLayout.coverageTolerance, "Corner radius \(cornerRadius)")
        }

        settings.update { $0.resultsPresentation.cornerRadius = 0 }
        XCTAssertEqual(layer.cornerRadius, 0)
        XCTAssertNil(material.maskImage)
    }

    /// The alpha of every pixel of a panel-sized Retina bitmap after `draw` fills it.
    private func coverage(_ draw: (CGContext, CGRect) -> Void) throws -> [UInt8] {
        let width = Int(TestLayout.panelSize.width * TestLayout.scale)
        let height = Int(TestLayout.panelSize.height * TestLayout.scale)
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: TestLayout.scale, y: TestLayout.scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        draw(context, CGRect(origin: .zero, size: TestLayout.panelSize))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return stride(from: 3, to: width * height * 4, by: 4).map { pixels[$0] }
    }
}
