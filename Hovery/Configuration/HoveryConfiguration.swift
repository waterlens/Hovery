import Darwin
import Foundation
import OSLog
import TOMLKit

enum RecognitionModifier: String, Codable, CaseIterable, Sendable {
    case command
    case option
    case control
    case shift
    case globe

    var displayName: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        case .globe: "Globe"
        }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        case .globe: "🌐"
        }
    }
}

struct WebExtensionConfiguration: Codable, Equatable, Sendable {
    var directory = "Extensions"
    var preload = true
    var disabled: [String] = []
    var trustedNative: [String] = []
    var nativeRequestTimeout = 5.0
    var nativeMaximumMessageBytes = 4_194_304

    private enum Limits {
        static let nativeRequestTimeout: ClosedRange<Double> = 0.1...60
        static let nativeMessageBytes: ClosedRange<Int> = 1_024...(64 * 1_024 * 1_024)
    }

    private enum CodingKeys: String, CodingKey {
        case directory
        case preload
        case disabled
        case trustedNative
        case nativeRequestTimeout
        case nativeMaximumMessageBytes
    }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decodeIfPresent(String.self, forKey: .directory)
            ?? defaults.directory
        preload = try container.decodeIfPresent(Bool.self, forKey: .preload)
            ?? defaults.preload
        disabled = try container.decodeIfPresent([String].self, forKey: .disabled) ?? []
        trustedNative = try container.decodeIfPresent([String].self, forKey: .trustedNative) ?? []
        nativeRequestTimeout = try container.decodeIfPresent(Double.self, forKey: .nativeRequestTimeout)
            ?? defaults.nativeRequestTimeout
        nativeMaximumMessageBytes = try container.decodeIfPresent(
            Int.self,
            forKey: .nativeMaximumMessageBytes
        ) ?? defaults.nativeMaximumMessageBytes
    }

    func sanitized() -> WebExtensionConfiguration {
        var value = self
        if value.directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.directory = Self().directory
        }
        value.disabled = Array(Set(value.disabled)).sorted()
        value.trustedNative = Array(Set(value.trustedNative)).sorted()
        value.nativeRequestTimeout = value.nativeRequestTimeout.clamped(
            to: Limits.nativeRequestTimeout
        )
        value.nativeMaximumMessageBytes = value.nativeMaximumMessageBytes.clamped(
            to: Limits.nativeMessageBytes
        )
        return value
    }
}

struct HoveryConfiguration: Codable, Equatable, Sendable {
    struct Interaction: Codable, Equatable, Sendable {
        var movementThreshold = 4.0
        var scanDelay = 0.05
        var refreshInterval = 2.0
        var pollingInterval = 0.045
        var resultMovementToleranceMultiplier = 2.0
        var requiredModifiers: [RecognitionModifier] = [.command]

        private enum CodingKeys: String, CodingKey {
            case movementThreshold
            case scanDelay
            case refreshInterval
            case pollingInterval
            case resultMovementToleranceMultiplier
            case requiredModifiers
        }

        init() {}

        init(from decoder: Decoder) throws {
            let defaults = Self()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            movementThreshold = try container.decodeIfPresent(Double.self, forKey: .movementThreshold)
                ?? defaults.movementThreshold
            scanDelay = try container.decodeIfPresent(Double.self, forKey: .scanDelay)
                ?? defaults.scanDelay
            refreshInterval = try container.decodeIfPresent(Double.self, forKey: .refreshInterval)
                ?? defaults.refreshInterval
            pollingInterval = try container.decodeIfPresent(Double.self, forKey: .pollingInterval)
                ?? defaults.pollingInterval
            resultMovementToleranceMultiplier = try container.decodeIfPresent(
                Double.self,
                forKey: .resultMovementToleranceMultiplier
            ) ?? defaults.resultMovementToleranceMultiplier
            requiredModifiers = try container.decodeIfPresent(
                [RecognitionModifier].self,
                forKey: .requiredModifiers
            ) ?? defaults.requiredModifiers
        }
    }

    struct Capture: Codable, Equatable, Sendable {
        var width = 960.0
        var height = 640.0
        var maximumPixelWidth = 1_800.0
        var maximumPixelHeight = 1_200.0
        var contentCacheLifetime = 15.0
        var accessibilityMinimumWidth = 240.0
        var accessibilityMinimumHeight = 120.0
        var accessibilityPadding = 12.0
        var accessibilityMaximumAncestorDepth = 12

        private enum CodingKeys: String, CodingKey {
            case width
            case height
            case maximumPixelWidth
            case maximumPixelHeight
            case contentCacheLifetime
            case accessibilityMinimumWidth
            case accessibilityMinimumHeight
            case accessibilityPadding
            case accessibilityMaximumAncestorDepth
        }

        init() {}

        init(from decoder: Decoder) throws {
            let defaults = Self()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            width = try container.decodeIfPresent(Double.self, forKey: .width) ?? defaults.width
            height = try container.decodeIfPresent(Double.self, forKey: .height) ?? defaults.height
            maximumPixelWidth = try container.decodeIfPresent(Double.self, forKey: .maximumPixelWidth)
                ?? defaults.maximumPixelWidth
            maximumPixelHeight = try container.decodeIfPresent(Double.self, forKey: .maximumPixelHeight)
                ?? defaults.maximumPixelHeight
            contentCacheLifetime = try container.decodeIfPresent(Double.self, forKey: .contentCacheLifetime)
                ?? defaults.contentCacheLifetime
            accessibilityMinimumWidth = try container.decodeIfPresent(
                Double.self,
                forKey: .accessibilityMinimumWidth
            ) ?? defaults.accessibilityMinimumWidth
            accessibilityMinimumHeight = try container.decodeIfPresent(
                Double.self,
                forKey: .accessibilityMinimumHeight
            ) ?? defaults.accessibilityMinimumHeight
            accessibilityPadding = try container.decodeIfPresent(Double.self, forKey: .accessibilityPadding)
                ?? defaults.accessibilityPadding
            accessibilityMaximumAncestorDepth = try container.decodeIfPresent(
                Int.self,
                forKey: .accessibilityMaximumAncestorDepth
            ) ?? defaults.accessibilityMaximumAncestorDepth
        }
    }

    struct Recognition: Codable, Equatable, Sendable {
        var minimumTextHeightFraction = 0.012
        var automaticallyDetectLanguage = true
        var useLanguageCorrection = true
        var maximumCandidateCount = 1
        var fallbackConfidence = 0.5
    }

    struct RegionSelection: Codable, Equatable, Sendable {
        var fallbackLineHeight = 14.0
        var minimumLineHeight = 8.0
        var minimumGeometryDimension = 1.0

        var magneticHorizontalScale = 0.30
        var magneticVerticalScale = 0.38
        var minimumMagneticPadding = 3.0
        var maximumHorizontalPadding = 14.0
        var maximumVerticalPadding = 16.0

        var directHitScore = 100.0
        var nearbyHitScore = 35.0
        var confidenceWeight = 20.0
        var distancePenalty = 40.0
        var verticalCenterPenalty = 8.0

        var blockMaximumVerticalGap = 2.4
        var blockAlignmentTolerance = 2.5
        var blockMinimumHorizontalOverlap = 0.25
        var sameColumnMinimumOverlap = 0.45
    }

    struct Overlay: Codable, Equatable, Sendable {
        var debugEnabled = false
        var initialFillOpacity = 0.035
        var initialStrokeOpacity = 0.92
        var initialLineWidth = 2.0
        var initialCornerRadius = 5.0
        var initialDashLength = 7.0
        var initialDashGap = 4.0

        var selectionFillOpacity = 0.18
        var selectionStrokeOpacity = 0.92
        var selectionLineWidth = 1.5

        var labelFontSize = 10.0
        var labelHorizontalPadding = 6.0
        var labelVerticalPadding = 3.0
        var labelGap = 5.0
        var labelCornerRadius = 5.0
        var labelEdgeInset = 8.0
        var labelBackgroundOpacity = 0.94

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case debugEnabled
            case initialFillOpacity
            case initialStrokeOpacity
            case initialLineWidth
            case initialCornerRadius
            case initialDashLength
            case initialDashGap
            case selectionFillOpacity
            case selectionStrokeOpacity
            case selectionLineWidth
            case labelFontSize
            case labelHorizontalPadding
            case labelVerticalPadding
            case labelGap
            case labelCornerRadius
            case labelEdgeInset
            case labelBackgroundOpacity
        }

        init() {}

        init(from decoder: Decoder) throws {
            let defaults = Self()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            debugEnabled = try container.decodeIfPresent(Bool.self, forKey: .debugEnabled)
                ?? defaults.debugEnabled
            initialFillOpacity = try container.decodeIfPresent(Double.self, forKey: .initialFillOpacity)
                ?? defaults.initialFillOpacity
            initialStrokeOpacity = try container.decodeIfPresent(Double.self, forKey: .initialStrokeOpacity)
                ?? defaults.initialStrokeOpacity
            initialLineWidth = try container.decodeIfPresent(Double.self, forKey: .initialLineWidth)
                ?? defaults.initialLineWidth
            initialCornerRadius = try container.decodeIfPresent(Double.self, forKey: .initialCornerRadius)
                ?? defaults.initialCornerRadius
            initialDashLength = try container.decodeIfPresent(Double.self, forKey: .initialDashLength)
                ?? defaults.initialDashLength
            initialDashGap = try container.decodeIfPresent(Double.self, forKey: .initialDashGap)
                ?? defaults.initialDashGap
            selectionFillOpacity = try container.decodeIfPresent(Double.self, forKey: .selectionFillOpacity)
                ?? defaults.selectionFillOpacity
            selectionStrokeOpacity = try container.decodeIfPresent(Double.self, forKey: .selectionStrokeOpacity)
                ?? defaults.selectionStrokeOpacity
            selectionLineWidth = try container.decodeIfPresent(Double.self, forKey: .selectionLineWidth)
                ?? defaults.selectionLineWidth
            labelFontSize = try container.decodeIfPresent(Double.self, forKey: .labelFontSize)
                ?? defaults.labelFontSize
            labelHorizontalPadding = try container.decodeIfPresent(Double.self, forKey: .labelHorizontalPadding)
                ?? defaults.labelHorizontalPadding
            labelVerticalPadding = try container.decodeIfPresent(Double.self, forKey: .labelVerticalPadding)
                ?? defaults.labelVerticalPadding
            labelGap = try container.decodeIfPresent(Double.self, forKey: .labelGap)
                ?? defaults.labelGap
            labelCornerRadius = try container.decodeIfPresent(Double.self, forKey: .labelCornerRadius)
                ?? defaults.labelCornerRadius
            labelEdgeInset = try container.decodeIfPresent(Double.self, forKey: .labelEdgeInset)
                ?? defaults.labelEdgeInset
            labelBackgroundOpacity = try container.decodeIfPresent(Double.self, forKey: .labelBackgroundOpacity)
                ?? defaults.labelBackgroundOpacity
        }
    }

    struct ExtensionOverlay: Codable, Equatable, Sendable {
        var enabled = true
        var fillOpacity = 0.0
        var strokeOpacity = 0.55
        var lineWidth = 1.0
        var material = "hudWindow"
        var materialOpacity = 0.18

        private enum CodingKeys: String, CodingKey {
            case enabled
            case fillOpacity
            case strokeOpacity
            case lineWidth
            case material
            case materialOpacity
        }

        init() {}

        init(from decoder: Decoder) throws {
            let defaults = Self()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            fillOpacity = try container.decodeIfPresent(Double.self, forKey: .fillOpacity)
                ?? defaults.fillOpacity
            strokeOpacity = try container.decodeIfPresent(Double.self, forKey: .strokeOpacity)
                ?? defaults.strokeOpacity
            lineWidth = try container.decodeIfPresent(Double.self, forKey: .lineWidth)
                ?? defaults.lineWidth
            material = try container.decodeIfPresent(String.self, forKey: .material)
                ?? defaults.material
            materialOpacity = try container.decodeIfPresent(Double.self, forKey: .materialOpacity)
                ?? defaults.materialOpacity
        }
    }

    struct ResultsPresentation: Codable, Equatable, Sendable {
        var enabled = true
        var width = 520.0
        var initialHeight = 240.0
        var minimumHeight = 120.0
        var maximumHeight = 620.0
        var tabBarHeight = 36.0
        var tabBarHorizontalInset = 8.0
        var tabBarVerticalInset = 5.0
        var tabItemHorizontalPadding = 14.0
        var tabItemSpacing = 4.0
        var tabIndicatorHeight = 2.0
        var tabCornerRadius = 8.0
        var anchorGap = 10.0
        var screenEdgeInset = 12.0
        var cornerRadius = 12.0
        var interactionCorridorPadding = 12.0

        private enum CodingKeys: String, CodingKey {
            case enabled
            case width
            case initialHeight
            case minimumHeight
            case maximumHeight
            case tabBarHeight
            case tabBarHorizontalInset
            case tabBarVerticalInset
            case tabItemHorizontalPadding
            case tabItemSpacing
            case tabIndicatorHeight
            case tabCornerRadius
            case anchorGap
            case screenEdgeInset
            case cornerRadius
            case interactionCorridorPadding
        }

        init() {}

        init(from decoder: Decoder) throws {
            let defaults = Self()
            let container = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
            width = try container.decodeIfPresent(Double.self, forKey: .width) ?? defaults.width
            initialHeight = try container.decodeIfPresent(Double.self, forKey: .initialHeight)
                ?? defaults.initialHeight
            minimumHeight = try container.decodeIfPresent(Double.self, forKey: .minimumHeight)
                ?? defaults.minimumHeight
            maximumHeight = try container.decodeIfPresent(Double.self, forKey: .maximumHeight)
                ?? defaults.maximumHeight
            tabBarHeight = try container.decodeIfPresent(Double.self, forKey: .tabBarHeight)
                ?? defaults.tabBarHeight
            tabBarHorizontalInset = try container.decodeIfPresent(
                Double.self,
                forKey: .tabBarHorizontalInset
            ) ?? defaults.tabBarHorizontalInset
            tabBarVerticalInset = try container.decodeIfPresent(Double.self, forKey: .tabBarVerticalInset)
                ?? defaults.tabBarVerticalInset
            tabItemHorizontalPadding = try container.decodeIfPresent(
                Double.self,
                forKey: .tabItemHorizontalPadding
            ) ?? defaults.tabItemHorizontalPadding
            tabItemSpacing = try container.decodeIfPresent(Double.self, forKey: .tabItemSpacing)
                ?? defaults.tabItemSpacing
            tabIndicatorHeight = try container.decodeIfPresent(Double.self, forKey: .tabIndicatorHeight)
                ?? defaults.tabIndicatorHeight
            tabCornerRadius = try container.decodeIfPresent(Double.self, forKey: .tabCornerRadius)
                ?? defaults.tabCornerRadius
            anchorGap = try container.decodeIfPresent(Double.self, forKey: .anchorGap)
                ?? defaults.anchorGap
            screenEdgeInset = try container.decodeIfPresent(Double.self, forKey: .screenEdgeInset)
                ?? defaults.screenEdgeInset
            cornerRadius = try container.decodeIfPresent(Double.self, forKey: .cornerRadius)
                ?? defaults.cornerRadius
            interactionCorridorPadding = try container.decodeIfPresent(
                Double.self,
                forKey: .interactionCorridorPadding
            ) ?? defaults.interactionCorridorPadding
        }
    }

    var interaction = Interaction()
    var capture = Capture()
    var recognition = Recognition()
    var regionSelection = RegionSelection()
    var overlay = Overlay()
    var extensionOverlay = ExtensionOverlay()
    var resultsPresentation = ResultsPresentation()

    private enum CodingKeys: String, CodingKey {
        case interaction
        case capture
        case recognition
        case regionSelection
        case overlay
        case extensionOverlay
        case resultsPresentation
    }

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = Self()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        interaction = try container.decodeIfPresent(Interaction.self, forKey: .interaction)
            ?? defaults.interaction
        capture = try container.decodeIfPresent(Capture.self, forKey: .capture)
            ?? defaults.capture
        recognition = try container.decodeIfPresent(Recognition.self, forKey: .recognition)
            ?? defaults.recognition
        regionSelection = try container.decodeIfPresent(RegionSelection.self, forKey: .regionSelection)
            ?? defaults.regionSelection
        overlay = try container.decodeIfPresent(Overlay.self, forKey: .overlay)
            ?? defaults.overlay
        extensionOverlay = try container.decodeIfPresent(ExtensionOverlay.self, forKey: .extensionOverlay)
            ?? defaults.extensionOverlay
        resultsPresentation = try container.decodeIfPresent(
            ResultsPresentation.self,
            forKey: .resultsPresentation
        ) ?? defaults.resultsPresentation
    }

    static let standard = HoveryConfiguration()

    private enum Limits {
        enum Interaction {
            static let movementThreshold: ClosedRange<Double> = 0.5...64
            static let scanDelay: ClosedRange<Double> = 0.01...5
            static let refreshInterval: ClosedRange<Double> = 0.1...60
            static let pollingInterval: ClosedRange<Double> = 0.01...1
            static let resultMovementToleranceMultiplier: ClosedRange<Double> = 1...10
        }

        enum Capture {
            static let width: ClosedRange<Double> = 160...4_096
            static let height: ClosedRange<Double> = 120...4_096
            static let maximumPixelWidth: ClosedRange<Double> = 320...8_192
            static let maximumPixelHeight: ClosedRange<Double> = 240...8_192
            static let contentCacheLifetime: ClosedRange<Double> = 0...300
            static let accessibilityMinimumWidth: ClosedRange<Double> = 1...4_096
            static let accessibilityMinimumHeight: ClosedRange<Double> = 1...4_096
            static let accessibilityPadding: ClosedRange<Double> = 0...512
            static let accessibilityMaximumAncestorDepth: ClosedRange<Int> = 1...64
        }

        enum Recognition {
            static let minimumTextHeightFraction: ClosedRange<Double> = 0.001...0.25
            static let maximumCandidateCount: ClosedRange<Int> = 1...10
            static let fallbackConfidence: ClosedRange<Double> = 0...1
        }

        enum RegionSelection {
            static let fallbackLineHeight: ClosedRange<Double> = 1...200
            static let minimumLineHeight: ClosedRange<Double> = 1...200
            static let minimumGeometryDimension: ClosedRange<Double> = 0.1...100
            static let magneticScale: ClosedRange<Double> = 0...4
            static let minimumMagneticPadding: ClosedRange<Double> = 0...100
            static let maximumPadding: ClosedRange<Double> = 0...300
            static let score: ClosedRange<Double> = -1_000...1_000
            static let nonnegativeScoreComponent: ClosedRange<Double> = 0...1_000
            static let blockDistanceScale: ClosedRange<Double> = 0...20
            static let overlapRatio: ClosedRange<Double> = 0...1
        }

        enum Overlay {
            static let opacity: ClosedRange<Double> = 0...1
            static let lineWidth: ClosedRange<Double> = 0.1...20
            static let cornerRadius: ClosedRange<Double> = 0...100
            static let dashComponent: ClosedRange<Double> = 0.1...100
            static let labelFontSize: ClosedRange<Double> = 6...72
            static let labelSpacing: ClosedRange<Double> = 0...100
        }

        enum ResultsPresentation {
            static let width: ClosedRange<Double> = 240...1_600
            static let height: ClosedRange<Double> = 80...1_600
            static let spacing: ClosedRange<Double> = 0...200
            static let cornerRadius: ClosedRange<Double> = 0...100
        }

    }

    func sanitized() -> HoveryConfiguration {
        var value = self

        value.interaction.movementThreshold = value.interaction.movementThreshold.clamped(
            to: Limits.Interaction.movementThreshold
        )
        value.interaction.scanDelay = value.interaction.scanDelay.clamped(to: Limits.Interaction.scanDelay)
        value.interaction.refreshInterval = value.interaction.refreshInterval.clamped(
            to: Limits.Interaction.refreshInterval
        )
        value.interaction.pollingInterval = value.interaction.pollingInterval.clamped(
            to: Limits.Interaction.pollingInterval
        )
        value.interaction.resultMovementToleranceMultiplier =
            value.interaction.resultMovementToleranceMultiplier.clamped(
                to: Limits.Interaction.resultMovementToleranceMultiplier
            )
        let requiredModifiers = Set(value.interaction.requiredModifiers)
        value.interaction.requiredModifiers = RecognitionModifier.allCases.filter(requiredModifiers.contains)

        value.capture.width = value.capture.width.clamped(to: Limits.Capture.width)
        value.capture.height = value.capture.height.clamped(to: Limits.Capture.height)
        value.capture.maximumPixelWidth = value.capture.maximumPixelWidth.clamped(
            to: Limits.Capture.maximumPixelWidth
        )
        value.capture.maximumPixelHeight = value.capture.maximumPixelHeight.clamped(
            to: Limits.Capture.maximumPixelHeight
        )
        value.capture.contentCacheLifetime = value.capture.contentCacheLifetime.clamped(
            to: Limits.Capture.contentCacheLifetime
        )
        value.capture.accessibilityMinimumWidth = value.capture.accessibilityMinimumWidth.clamped(
            to: Limits.Capture.accessibilityMinimumWidth
        )
        value.capture.accessibilityMinimumHeight = value.capture.accessibilityMinimumHeight.clamped(
            to: Limits.Capture.accessibilityMinimumHeight
        )
        value.capture.accessibilityPadding = value.capture.accessibilityPadding.clamped(
            to: Limits.Capture.accessibilityPadding
        )
        value.capture.accessibilityMaximumAncestorDepth =
            value.capture.accessibilityMaximumAncestorDepth.clamped(
                to: Limits.Capture.accessibilityMaximumAncestorDepth
            )

        value.recognition.minimumTextHeightFraction =
            value.recognition.minimumTextHeightFraction.clamped(
                to: Limits.Recognition.minimumTextHeightFraction
            )
        value.recognition.maximumCandidateCount = value.recognition.maximumCandidateCount.clamped(
            to: Limits.Recognition.maximumCandidateCount
        )
        value.recognition.fallbackConfidence = value.recognition.fallbackConfidence.clamped(
            to: Limits.Recognition.fallbackConfidence
        )

        value.regionSelection.fallbackLineHeight = value.regionSelection.fallbackLineHeight.clamped(
            to: Limits.RegionSelection.fallbackLineHeight
        )
        value.regionSelection.minimumLineHeight = value.regionSelection.minimumLineHeight.clamped(
            to: Limits.RegionSelection.minimumLineHeight
        )
        value.regionSelection.minimumGeometryDimension =
            value.regionSelection.minimumGeometryDimension.clamped(
                to: Limits.RegionSelection.minimumGeometryDimension
            )
        value.regionSelection.magneticHorizontalScale =
            value.regionSelection.magneticHorizontalScale.clamped(to: Limits.RegionSelection.magneticScale)
        value.regionSelection.magneticVerticalScale =
            value.regionSelection.magneticVerticalScale.clamped(to: Limits.RegionSelection.magneticScale)
        value.regionSelection.minimumMagneticPadding =
            value.regionSelection.minimumMagneticPadding.clamped(
                to: Limits.RegionSelection.minimumMagneticPadding
            )
        value.regionSelection.maximumHorizontalPadding = max(
            value.regionSelection.minimumMagneticPadding,
            value.regionSelection.maximumHorizontalPadding.clamped(to: Limits.RegionSelection.maximumPadding)
        )
        value.regionSelection.maximumVerticalPadding = max(
            value.regionSelection.minimumMagneticPadding,
            value.regionSelection.maximumVerticalPadding.clamped(to: Limits.RegionSelection.maximumPadding)
        )
        value.regionSelection.directHitScore = value.regionSelection.directHitScore.clamped(
            to: Limits.RegionSelection.score
        )
        value.regionSelection.nearbyHitScore = value.regionSelection.nearbyHitScore.clamped(
            to: Limits.RegionSelection.score
        )
        value.regionSelection.confidenceWeight = value.regionSelection.confidenceWeight.clamped(
            to: Limits.RegionSelection.nonnegativeScoreComponent
        )
        value.regionSelection.distancePenalty = value.regionSelection.distancePenalty.clamped(
            to: Limits.RegionSelection.nonnegativeScoreComponent
        )
        value.regionSelection.verticalCenterPenalty =
            value.regionSelection.verticalCenterPenalty.clamped(
                to: Limits.RegionSelection.nonnegativeScoreComponent
            )
        value.regionSelection.blockMaximumVerticalGap =
            value.regionSelection.blockMaximumVerticalGap.clamped(
                to: Limits.RegionSelection.blockDistanceScale
            )
        value.regionSelection.blockAlignmentTolerance =
            value.regionSelection.blockAlignmentTolerance.clamped(
                to: Limits.RegionSelection.blockDistanceScale
            )
        value.regionSelection.blockMinimumHorizontalOverlap =
            value.regionSelection.blockMinimumHorizontalOverlap.clamped(
                to: Limits.RegionSelection.overlapRatio
            )
        value.regionSelection.sameColumnMinimumOverlap =
            value.regionSelection.sameColumnMinimumOverlap.clamped(to: Limits.RegionSelection.overlapRatio)

        value.overlay.initialFillOpacity = value.overlay.initialFillOpacity.clamped(to: Limits.Overlay.opacity)
        value.overlay.initialStrokeOpacity = value.overlay.initialStrokeOpacity.clamped(to: Limits.Overlay.opacity)
        value.overlay.initialLineWidth = value.overlay.initialLineWidth.clamped(to: Limits.Overlay.lineWidth)
        value.overlay.initialCornerRadius = value.overlay.initialCornerRadius.clamped(
            to: Limits.Overlay.cornerRadius
        )
        value.overlay.initialDashLength = value.overlay.initialDashLength.clamped(
            to: Limits.Overlay.dashComponent
        )
        value.overlay.initialDashGap = value.overlay.initialDashGap.clamped(to: Limits.Overlay.dashComponent)
        value.overlay.selectionFillOpacity = value.overlay.selectionFillOpacity.clamped(to: Limits.Overlay.opacity)
        value.overlay.selectionStrokeOpacity = value.overlay.selectionStrokeOpacity.clamped(
            to: Limits.Overlay.opacity
        )
        value.overlay.selectionLineWidth = value.overlay.selectionLineWidth.clamped(to: Limits.Overlay.lineWidth)
        value.overlay.labelFontSize = value.overlay.labelFontSize.clamped(to: Limits.Overlay.labelFontSize)
        value.overlay.labelHorizontalPadding = value.overlay.labelHorizontalPadding.clamped(
            to: Limits.Overlay.labelSpacing
        )
        value.overlay.labelVerticalPadding = value.overlay.labelVerticalPadding.clamped(
            to: Limits.Overlay.labelSpacing
        )
        value.overlay.labelGap = value.overlay.labelGap.clamped(to: Limits.Overlay.labelSpacing)
        value.overlay.labelCornerRadius = value.overlay.labelCornerRadius.clamped(to: Limits.Overlay.cornerRadius)
        value.overlay.labelEdgeInset = value.overlay.labelEdgeInset.clamped(to: Limits.Overlay.labelSpacing)
        value.overlay.labelBackgroundOpacity = value.overlay.labelBackgroundOpacity.clamped(
            to: Limits.Overlay.opacity
        )

        value.extensionOverlay.fillOpacity = value.extensionOverlay.fillOpacity.clamped(
            to: Limits.Overlay.opacity
        )
        value.extensionOverlay.strokeOpacity = value.extensionOverlay.strokeOpacity.clamped(
            to: Limits.Overlay.opacity
        )
        value.extensionOverlay.lineWidth = value.extensionOverlay.lineWidth.clamped(
            to: Limits.Overlay.lineWidth
        )
        value.extensionOverlay.materialOpacity = value.extensionOverlay.materialOpacity.clamped(
            to: Limits.Overlay.opacity
        )

        value.resultsPresentation.width = value.resultsPresentation.width.clamped(
            to: Limits.ResultsPresentation.width
        )
        value.resultsPresentation.minimumHeight = value.resultsPresentation.minimumHeight.clamped(
            to: Limits.ResultsPresentation.height
        )
        value.resultsPresentation.maximumHeight = max(
            value.resultsPresentation.minimumHeight,
            value.resultsPresentation.maximumHeight.clamped(to: Limits.ResultsPresentation.height)
        )
        value.resultsPresentation.initialHeight = value.resultsPresentation.initialHeight.clamped(
            to: value.resultsPresentation.minimumHeight...value.resultsPresentation.maximumHeight
        )
        value.resultsPresentation.tabBarHeight = value.resultsPresentation.tabBarHeight.clamped(
            to: Limits.ResultsPresentation.spacing
        )
        value.resultsPresentation.tabBarHorizontalInset =
            value.resultsPresentation.tabBarHorizontalInset.clamped(
                to: Limits.ResultsPresentation.spacing
            )
        value.resultsPresentation.tabBarVerticalInset =
            value.resultsPresentation.tabBarVerticalInset.clamped(
                to: Limits.ResultsPresentation.spacing
            )
        value.resultsPresentation.tabItemHorizontalPadding =
            value.resultsPresentation.tabItemHorizontalPadding.clamped(
                to: Limits.ResultsPresentation.spacing
            )
        value.resultsPresentation.tabItemSpacing =
            value.resultsPresentation.tabItemSpacing.clamped(
                to: Limits.ResultsPresentation.spacing
            )
        value.resultsPresentation.tabIndicatorHeight =
            value.resultsPresentation.tabIndicatorHeight.clamped(
                to: Limits.ResultsPresentation.spacing
            )
        value.resultsPresentation.tabCornerRadius = value.resultsPresentation.tabCornerRadius.clamped(
            to: Limits.ResultsPresentation.cornerRadius
        )
        value.resultsPresentation.anchorGap = value.resultsPresentation.anchorGap.clamped(
            to: Limits.ResultsPresentation.spacing
        )
        value.resultsPresentation.screenEdgeInset = value.resultsPresentation.screenEdgeInset.clamped(
            to: Limits.ResultsPresentation.spacing
        )
        value.resultsPresentation.cornerRadius = value.resultsPresentation.cornerRadius.clamped(
            to: Limits.ResultsPresentation.cornerRadius
        )
        value.resultsPresentation.interactionCorridorPadding =
            value.resultsPresentation.interactionCorridorPadding.clamped(
                to: Limits.ResultsPresentation.spacing
            )

        return value
    }
}

@MainActor
final class HoverySettings: ObservableObject {
    private enum FileFormat {
        static let numberFormat = "%.12g"
        static let extensionsFileName = "extensions.toml"
    }

    @Published private(set) var configuration: HoveryConfiguration
    @Published private(set) var extensionConfiguration: WebExtensionConfiguration
    @Published private(set) var loadError: String?

    let configurationURL: URL
    let extensionConfigurationURL: URL
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "app.hovery.Hovery", category: "Configuration")
    private var directoryMonitor: DispatchSourceFileSystemObject?

    init(
        configurationURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let resolvedConfigurationURL = configurationURL
            ?? Self.defaultConfigurationURL(fileManager: fileManager)
        self.configurationURL = resolvedConfigurationURL
        extensionConfigurationURL = resolvedConfigurationURL
            .deletingLastPathComponent()
            .appendingPathComponent(FileFormat.extensionsFileName, isDirectory: false)
        configuration = .standard
        extensionConfiguration = WebExtensionConfiguration()

        do {
            try createConfigurationFilesIfNeeded()
        } catch {
            loadError = error.localizedDescription
            logger.error("Failed to initialize configuration: \(error.localizedDescription, privacy: .public)")
        }
        reload()
        startMonitoringConfigurationDirectory()
    }

    var extensionsDirectoryURL: URL {
        let expanded = (extensionConfiguration.directory as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        }
        return configurationURL
            .deletingLastPathComponent()
            .appendingPathComponent(expanded, isDirectory: true)
            .standardizedFileURL
    }

    func reload() {
        do {
            try loadConfiguration()
            loadError = nil
            logger.notice("Reloaded TOML configuration")
        } catch {
            loadError = error.localizedDescription
            logger.error("Ignoring invalid TOML configuration: \(error.localizedDescription, privacy: .public)")
        }
        do {
            try loadExtensionConfiguration()
            logger.notice("Reloaded extension TOML configuration")
        } catch {
            logger.error(
                "Ignoring invalid extension TOML configuration: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func update(_ change: (inout HoveryConfiguration) -> Void) {
        var next = configuration
        change(&next)
        replace(with: next)
    }

    func updateExtensions(_ change: (inout WebExtensionConfiguration) -> Void) {
        var next = extensionConfiguration
        change(&next)
        replaceExtensions(with: next)
    }

    func replace(with next: HoveryConfiguration) {
        let previous = configuration
        configuration = next.sanitized()

        do {
            try writeConfiguration(configuration)
            loadError = nil
        } catch {
            configuration = previous
            loadError = error.localizedDescription
            logger.error("Failed to save TOML configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func replaceExtensions(with next: WebExtensionConfiguration) {
        let previous = extensionConfiguration
        extensionConfiguration = next.sanitized()

        do {
            try writeExtensionConfiguration(extensionConfiguration)
        } catch {
            extensionConfiguration = previous
            logger.error("Failed to save extension configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    func reset() {
        let previous = configuration
        configuration = .standard
        do {
            try writeConfiguration(configuration)
            loadError = nil
        } catch {
            configuration = previous
            loadError = error.localizedDescription
            logger.error("Failed to reset TOML configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func defaultConfigurationURL(fileManager: FileManager) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["HOVERY_CONFIG_PATH"],
           !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath).standardizedFileURL
        }

        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("Hovery", isDirectory: true)
            .appendingPathComponent("config.toml", isDirectory: false)
    }

    private func createConfigurationFilesIfNeeded() throws {
        try fileManager.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !fileManager.fileExists(atPath: configurationURL.path) {
            try writeConfiguration(.standard)
        }
        if !fileManager.fileExists(atPath: extensionConfigurationURL.path) {
            try writeExtensionConfiguration(WebExtensionConfiguration())
        }
    }

    private func loadConfiguration() throws {
        let text = try String(contentsOf: configurationURL, encoding: .utf8)
        let table = try TOMLTable(string: text)
        let decoded = try TOMLDecoder().decode(HoveryConfiguration.self, from: table)
        let nextConfiguration = decoded.sanitized()
        if configuration != nextConfiguration {
            configuration = nextConfiguration
        }
    }

    private func loadExtensionConfiguration() throws {
        let text = try String(contentsOf: extensionConfigurationURL, encoding: .utf8)
        let table = try TOMLTable(string: text)
        let decoded = try TOMLDecoder().decode(WebExtensionConfiguration.self, from: table)
        let nextExtensionConfiguration = decoded.sanitized()
        if extensionConfiguration != nextExtensionConfiguration {
            extensionConfiguration = nextExtensionConfiguration
        }
    }

    static func serialized(_ configuration: HoveryConfiguration) throws -> String {
        let capture = configuration.capture
        let interaction = configuration.interaction
        let recognition = configuration.recognition
        let region = configuration.regionSelection
        let overlay = configuration.overlay
        let extensionOverlay = configuration.extensionOverlay
        let resultsPresentation = configuration.resultsPresentation

        return """
        [capture]
        width = \(tomlNumber(capture.width))
        height = \(tomlNumber(capture.height))
        maximumPixelWidth = \(tomlNumber(capture.maximumPixelWidth))
        maximumPixelHeight = \(tomlNumber(capture.maximumPixelHeight))
        contentCacheLifetime = \(tomlNumber(capture.contentCacheLifetime))
        accessibilityMinimumWidth = \(tomlNumber(capture.accessibilityMinimumWidth))
        accessibilityMinimumHeight = \(tomlNumber(capture.accessibilityMinimumHeight))
        accessibilityPadding = \(tomlNumber(capture.accessibilityPadding))
        accessibilityMaximumAncestorDepth = \(capture.accessibilityMaximumAncestorDepth)

        [interaction]
        movementThreshold = \(tomlNumber(interaction.movementThreshold))
        scanDelay = \(tomlNumber(interaction.scanDelay))
        refreshInterval = \(tomlNumber(interaction.refreshInterval))
        pollingInterval = \(tomlNumber(interaction.pollingInterval))
        resultMovementToleranceMultiplier = \(tomlNumber(interaction.resultMovementToleranceMultiplier))
        requiredModifiers = \(tomlStringArray(interaction.requiredModifiers.map(\.rawValue)))
        [recognition]
        minimumTextHeightFraction = \(tomlNumber(recognition.minimumTextHeightFraction))
        automaticallyDetectLanguage = \(recognition.automaticallyDetectLanguage)
        useLanguageCorrection = \(recognition.useLanguageCorrection)
        maximumCandidateCount = \(recognition.maximumCandidateCount)
        fallbackConfidence = \(tomlNumber(recognition.fallbackConfidence))

        [regionSelection]
        fallbackLineHeight = \(tomlNumber(region.fallbackLineHeight))
        minimumLineHeight = \(tomlNumber(region.minimumLineHeight))
        minimumGeometryDimension = \(tomlNumber(region.minimumGeometryDimension))
        magneticHorizontalScale = \(tomlNumber(region.magneticHorizontalScale))
        magneticVerticalScale = \(tomlNumber(region.magneticVerticalScale))
        minimumMagneticPadding = \(tomlNumber(region.minimumMagneticPadding))
        maximumHorizontalPadding = \(tomlNumber(region.maximumHorizontalPadding))
        maximumVerticalPadding = \(tomlNumber(region.maximumVerticalPadding))
        directHitScore = \(tomlNumber(region.directHitScore))
        nearbyHitScore = \(tomlNumber(region.nearbyHitScore))
        confidenceWeight = \(tomlNumber(region.confidenceWeight))
        distancePenalty = \(tomlNumber(region.distancePenalty))
        verticalCenterPenalty = \(tomlNumber(region.verticalCenterPenalty))
        blockMaximumVerticalGap = \(tomlNumber(region.blockMaximumVerticalGap))
        blockAlignmentTolerance = \(tomlNumber(region.blockAlignmentTolerance))
        blockMinimumHorizontalOverlap = \(tomlNumber(region.blockMinimumHorizontalOverlap))
        sameColumnMinimumOverlap = \(tomlNumber(region.sameColumnMinimumOverlap))

        [overlay]
        debugEnabled = \(overlay.debugEnabled)
        initialFillOpacity = \(tomlNumber(overlay.initialFillOpacity))
        initialStrokeOpacity = \(tomlNumber(overlay.initialStrokeOpacity))
        initialLineWidth = \(tomlNumber(overlay.initialLineWidth))
        initialCornerRadius = \(tomlNumber(overlay.initialCornerRadius))
        initialDashLength = \(tomlNumber(overlay.initialDashLength))
        initialDashGap = \(tomlNumber(overlay.initialDashGap))
        selectionFillOpacity = \(tomlNumber(overlay.selectionFillOpacity))
        selectionStrokeOpacity = \(tomlNumber(overlay.selectionStrokeOpacity))
        selectionLineWidth = \(tomlNumber(overlay.selectionLineWidth))
        labelFontSize = \(tomlNumber(overlay.labelFontSize))
        labelHorizontalPadding = \(tomlNumber(overlay.labelHorizontalPadding))
        labelVerticalPadding = \(tomlNumber(overlay.labelVerticalPadding))
        labelGap = \(tomlNumber(overlay.labelGap))
        labelCornerRadius = \(tomlNumber(overlay.labelCornerRadius))
        labelEdgeInset = \(tomlNumber(overlay.labelEdgeInset))
        labelBackgroundOpacity = \(tomlNumber(overlay.labelBackgroundOpacity))

        [extensionOverlay]
        enabled = \(extensionOverlay.enabled)
        fillOpacity = \(tomlNumber(extensionOverlay.fillOpacity))
        strokeOpacity = \(tomlNumber(extensionOverlay.strokeOpacity))
        lineWidth = \(tomlNumber(extensionOverlay.lineWidth))
        material = \(tomlString(extensionOverlay.material))
        materialOpacity = \(tomlNumber(extensionOverlay.materialOpacity))

        [resultsPresentation]
        enabled = \(resultsPresentation.enabled)
        width = \(tomlNumber(resultsPresentation.width))
        initialHeight = \(tomlNumber(resultsPresentation.initialHeight))
        minimumHeight = \(tomlNumber(resultsPresentation.minimumHeight))
        maximumHeight = \(tomlNumber(resultsPresentation.maximumHeight))
        tabBarHeight = \(tomlNumber(resultsPresentation.tabBarHeight))
        tabBarHorizontalInset = \(tomlNumber(resultsPresentation.tabBarHorizontalInset))
        tabBarVerticalInset = \(tomlNumber(resultsPresentation.tabBarVerticalInset))
        tabItemHorizontalPadding = \(tomlNumber(resultsPresentation.tabItemHorizontalPadding))
        tabItemSpacing = \(tomlNumber(resultsPresentation.tabItemSpacing))
        tabIndicatorHeight = \(tomlNumber(resultsPresentation.tabIndicatorHeight))
        tabCornerRadius = \(tomlNumber(resultsPresentation.tabCornerRadius))
        anchorGap = \(tomlNumber(resultsPresentation.anchorGap))
        screenEdgeInset = \(tomlNumber(resultsPresentation.screenEdgeInset))
        cornerRadius = \(tomlNumber(resultsPresentation.cornerRadius))
        interactionCorridorPadding = \(tomlNumber(resultsPresentation.interactionCorridorPadding))
        """
    }

    static func serializedExtensions(_ extensions: WebExtensionConfiguration) -> String {
        """
        directory = \(tomlString(extensions.directory))
        preload = \(extensions.preload)
        disabled = \(tomlStringArray(extensions.disabled))
        trustedNative = \(tomlStringArray(extensions.trustedNative))
        nativeRequestTimeout = \(tomlNumber(extensions.nativeRequestTimeout))
        nativeMaximumMessageBytes = \(extensions.nativeMaximumMessageBytes)
        """
    }

    private static func tomlNumber(_ value: Double) -> String {
        var text = String(format: FileFormat.numberFormat, locale: Locale(identifier: "en_US_POSIX"), value)
        if !text.contains(".") && !text.lowercased().contains("e") {
            text += ".0"
        }
        return text
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func tomlStringArray(_ values: [String]) -> String {
        "[\(values.map(tomlString).joined(separator: ", "))]"
    }

    private func writeConfiguration(_ configuration: HoveryConfiguration) throws {
        let text = try Self.serialized(configuration)
        try text.write(to: configurationURL, atomically: true, encoding: .utf8)
    }

    private func writeExtensionConfiguration(_ extensions: WebExtensionConfiguration) throws {
        let text = Self.serializedExtensions(extensions)
        try text.write(to: extensionConfigurationURL, atomically: true, encoding: .utf8)
    }

    private func startMonitoringConfigurationDirectory() {
        let directoryPath = configurationURL.deletingLastPathComponent().path
        let descriptor = Darwin.open(directoryPath, O_EVTONLY)
        guard descriptor >= 0 else {
            logger.error("Could not monitor the configuration directory")
            return
        }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: .main
        )
        monitor.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload()
            }
        }
        monitor.setCancelHandler {
            Darwin.close(descriptor)
        }
        directoryMonitor = monitor
        monitor.resume()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
