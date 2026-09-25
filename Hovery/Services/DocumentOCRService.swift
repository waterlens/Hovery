import CoreGraphics
import CoreText
import Foundation
import Vision

struct OCRRecognition: Sendable {
    var identifier: UUID?
    var hierarchy: HoverHierarchy?
    var target: CaptureTarget?
}

enum CachedHierarchyLookup: Equatable, Sendable {
    case unavailable
    case noHit
    case hit(HoverHierarchy)
}

actor DocumentOCRService {
    private struct CachedDocument {
        var identifier: UUID
        var frame: CapturedFrame
        var document: DocumentObservation.Container
        var regionConfiguration: HoveryConfiguration.RegionSelection
        var fallbackConfidence: Float
    }

    private enum WarmUpSample {
        /// Each language's models load separately, so English text is ready before Chinese.
        static let texts = ["Hovery prepares text recognition.", "Hovery 正在准备文字识别。"]
        static let size = CGSize(width: 900, height: 120)
        static let fontSize: CGFloat = 40
        static let margin: CGFloat = 30
    }

    private var cachedDocument: CachedDocument?

    /// Vision prepares its text recognition models during the first request. When their compiled
    /// form isn't cached, such as after installing a new build, that takes tens of seconds. Hover
    /// scans are cancelled whenever the pointer moves, and a cancelled request stops preparing the
    /// models, so the first hovers after launch would rarely finish without this.
    ///
    /// Returns the text recognized in the sample images.
    @discardableResult
    func warmUp(configuration: HoveryConfiguration = .standard) async throws -> [String] {
        var transcripts: [String] = []
        for text in WarmUpSample.texts {
            guard let image = Self.warmUpImage(text: text) else { continue }
            let observations = try await Self.request(configuration: configuration).perform(on: image)
            transcripts.append(observations.first?.document.text.transcript ?? "")
        }
        return transcripts
    }

    func recognize(
        frame: CapturedFrame,
        pointer: CGPoint,
        configuration: HoveryConfiguration = .standard
    ) async throws -> OCRRecognition {
        let observations = try await Self.request(configuration: configuration).perform(on: frame.image)
        try Task.checkCancellation()
        guard let document = observations.first?.document else {
            cachedDocument = nil
            return OCRRecognition(identifier: nil, hierarchy: nil, target: nil)
        }

        let identifier = UUID()
        let builder = SemanticHierarchyBuilder(
            frame: frame,
            pointer: pointer,
            regionConfiguration: configuration.regionSelection,
            fallbackConfidence: Float(configuration.recognition.fallbackConfidence)
        )
        cachedDocument = CachedDocument(
            identifier: identifier,
            frame: frame,
            document: document,
            regionConfiguration: configuration.regionSelection,
            fallbackConfidence: Float(configuration.recognition.fallbackConfidence)
        )
        return OCRRecognition(
            identifier: identifier,
            hierarchy: builder.build(from: document),
            target: frame.target
        )
    }

    func hierarchy(from identifier: UUID, at pointer: CGPoint) -> CachedHierarchyLookup {
        guard let cachedDocument,
              cachedDocument.identifier == identifier,
              cachedDocument.frame.globalRect.contains(pointer) else {
            return .unavailable
        }

        let hierarchy = SemanticHierarchyBuilder(
            frame: cachedDocument.frame,
            pointer: pointer,
            regionConfiguration: cachedDocument.regionConfiguration,
            fallbackConfidence: cachedDocument.fallbackConfidence
        ).build(from: cachedDocument.document)
        return hierarchy.map(CachedHierarchyLookup.hit) ?? .noHit
    }

    func discardRecognition(_ identifier: UUID) {
        guard cachedDocument?.identifier == identifier else { return }
        cachedDocument = nil
    }

    private static func request(configuration: HoveryConfiguration) -> RecognizeDocumentsRequest {
        var request = RecognizeDocumentsRequest()
        var textOptions = request.textRecognitionOptions
        textOptions.minimumTextHeightFraction = Float(configuration.recognition.minimumTextHeightFraction)
        textOptions.automaticallyDetectLanguage = configuration.recognition.automaticallyDetectLanguage
        textOptions.useLanguageCorrection = configuration.recognition.useLanguageCorrection
        textOptions.maximumCandidateCount = configuration.recognition.maximumCandidateCount
        request.textRecognitionOptions = textOptions

        var barcodeOptions = request.barcodeDetectionOptions
        barcodeOptions.enabled = false
        request.barcodeDetectionOptions = barcodeOptions
        return request
    }

    /// Dark text on white.
    private static func warmUpImage(text: String) -> CGImage? {
        let size = WarmUpSample.size
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let attributes: [NSAttributedString.Key: Any] = [
            .font: CTFontCreateUIFontForLanguage(.system, WarmUpSample.fontSize, nil) as Any,
            .foregroundColor: CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = CGPoint(x: WarmUpSample.margin, y: size.height - WarmUpSample.margin - WarmUpSample.fontSize)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes)), context)
        return context.makeImage()
    }
}

private struct SemanticHierarchyBuilder {
    private struct TextCandidate {
        var text: DocumentObservation.Container.Text
        var region: HighlightRegion
    }

    private struct RangeCandidate {
        var text: String
        var region: HighlightRegion
        var confidence: Float
        var score: CGFloat
    }

    var frame: CapturedFrame
    var pointer: CGPoint
    var regionConfiguration: HoveryConfiguration.RegionSelection
    var fallbackConfidence: Float

    private var heuristics: RegionSelectionHeuristics {
        RegionSelectionHeuristics(configuration: regionConfiguration)
    }

    func build(from document: DocumentObservation.Container) -> HoverHierarchy? {
        let paragraphs = document.paragraphs.isEmpty ? [document.text] : document.paragraphs
        let paragraphCandidates = paragraphs.map { paragraph in
            TextCandidate(
                text: paragraph,
                region: globalRegion(paragraph.boundingRegion)
            )
        }

        let scoredParagraphs = paragraphCandidates.compactMap { candidate -> (TextCandidate, CGFloat)? in
            let score = heuristics.hitScore(
                region: candidate.region,
                pointer: pointer,
                confidence: paragraphConfidence(candidate.text)
            )
            return score.isFinite ? (candidate, score) : nil
        }
        guard let selectedParagraph = scoredParagraphs.max(by: { $0.1 < $1.1 })?.0 else {
            return nil
        }

        let word = bestWord(in: selectedParagraph.text)
        let sentence = bestSentence(in: selectedParagraph.text)
        let paragraphSelection = SemanticSelection(
            level: .paragraph,
            text: selectedParagraph.text.transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            regions: [selectedParagraph.region],
            confidence: paragraphConfidence(selectedParagraph.text)
        )
        let block = buildBlock(
            selectedParagraph: selectedParagraph,
            candidates: paragraphCandidates,
            document: document
        )

        var selections: [SemanticLevel: SemanticSelection] = [:]
        if let word { selections[.word] = word }
        if let sentence { selections[.sentence] = sentence }
        if !paragraphSelection.text.isEmpty { selections[.paragraph] = paragraphSelection }
        if let block { selections[.block] = block }

        guard !selections.isEmpty else { return nil }
        return HoverHierarchy(displayID: frame.displayID, selections: selections)
    }

    private func bestWord(in paragraph: DocumentObservation.Container.Text) -> SemanticSelection? {
        var candidates: [RangeCandidate] = []

        if let words = paragraph.words {
            candidates = words.compactMap { word in
                let value = word.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                let region = globalRegion(word.boundingRegion)
                let score = heuristics.hitScore(region: region, pointer: pointer, confidence: word.confidence)
                guard score.isFinite else { return nil }
                return RangeCandidate(text: value, region: region, confidence: word.confidence, score: score)
            }
        }

        if candidates.isEmpty {
            paragraph.transcript.enumerateSubstrings(
                in: paragraph.transcript.startIndex..<paragraph.transcript.endIndex,
                options: [.byWords, .substringNotRequired]
            ) { _, range, _, _ in
                guard let normalizedRegion = paragraph.boundingRegion(for: range) else { return }
                let value = String(paragraph.transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return }
                let region = globalRegion(normalizedRegion)
                let score = heuristics.hitScore(
                    region: region,
                    pointer: pointer,
                    confidence: paragraphConfidence(paragraph)
                )
                guard score.isFinite else { return }
                candidates.append(RangeCandidate(
                    text: value,
                    region: region,
                    confidence: paragraphConfidence(paragraph),
                    score: score
                ))
            }
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        return SemanticSelection(level: .word, text: best.text, regions: [best.region], confidence: best.confidence)
    }

    private func bestSentence(in paragraph: DocumentObservation.Container.Text) -> SemanticSelection? {
        var candidates: [RangeCandidate] = []
        let transcript = paragraph.transcript

        transcript.enumerateSubstrings(
            in: transcript.startIndex..<transcript.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, _, _ in
            guard let normalizedRegion = paragraph.boundingRegion(for: range) else { return }
            let value = String(transcript[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            let region = globalRegion(normalizedRegion)
            let score = heuristics.hitScore(
                region: region,
                pointer: pointer,
                confidence: paragraphConfidence(paragraph)
            )
            guard score.isFinite else { return }
            candidates.append(RangeCandidate(
                text: value,
                region: region,
                confidence: paragraphConfidence(paragraph),
                score: score
            ))
        }

        if candidates.isEmpty {
            let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let region = globalRegion(paragraph.boundingRegion)
            candidates.append(RangeCandidate(
                text: value,
                region: region,
                confidence: paragraphConfidence(paragraph),
                score: heuristics.hitScore(
                    region: region,
                    pointer: pointer,
                    confidence: paragraphConfidence(paragraph)
                )
            ))
        }

        guard let best = candidates.max(by: { $0.score < $1.score }) else { return nil }
        return SemanticSelection(
            level: .sentence,
            text: best.text,
            regions: [best.region],
            confidence: best.confidence
        )
    }

    private func buildBlock(
        selectedParagraph: TextCandidate,
        candidates: [TextCandidate],
        document: DocumentObservation.Container
    ) -> SemanticSelection? {
        if let table = document.tables.first(where: {
            heuristics.magneticRect(globalRegion($0.boundingRegion).boundingRect).contains(pointer)
        }) {
            let text = table.rows
                .map { row in row.map { $0.content.text.transcript }.joined(separator: "\t") }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return SemanticSelection(
                    level: .block,
                    text: text,
                    regions: [globalRegion(table.boundingRegion)],
                    confidence: paragraphConfidence(selectedParagraph.text)
                )
            }
        }

        if let list = document.lists.first(where: {
            heuristics.magneticRect(globalRegion($0.boundingRegion).boundingRect).contains(pointer)
        }) {
            let text = list.items
                .map { item in
                    let marker = item.markerString
                    return marker.isEmpty ? item.itemString : "\(marker) \(item.itemString)"
                }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                return SemanticSelection(
                    level: .block,
                    text: text,
                    regions: [globalRegion(list.boundingRegion)],
                    confidence: paragraphConfidence(selectedParagraph.text)
                )
            }
        }

        let selectedRect = selectedParagraph.region.boundingRect
        let lineHeight = max(
            selectedParagraph.text.lines.map { globalRegion($0.boundingRegion).boundingRect.height }.median
                ?? CGFloat(regionConfiguration.fallbackLineHeight),
            CGFloat(regionConfiguration.minimumLineHeight)
        )

        var included = [selectedParagraph]
        var changed = true
        while changed {
            changed = false
            for candidate in candidates where !included.contains(where: { $0.text == candidate.text }) {
                if included.contains(where: {
                    heuristics.belongsToSameBlock(
                        $0.region.boundingRect,
                        candidate.region.boundingRect,
                        lineHeight: lineHeight
                    )
                }) {
                    included.append(candidate)
                    changed = true
                }
            }
        }

        if included.count == 1, candidates.count > 1 {
            let sameColumn = candidates.filter {
                heuristics.horizontalOverlapRatio(selectedRect, $0.region.boundingRect)
                    > CGFloat(regionConfiguration.sameColumnMinimumOverlap)
            }
            if !sameColumn.isEmpty {
                included = sameColumn
            }
        }

        included.sort {
            let lhs = $0.region.boundingRect
            let rhs = $1.region.boundingRect
            if abs(lhs.minY - rhs.minY) > lineHeight { return lhs.minY < rhs.minY }
            return lhs.minX < rhs.minX
        }

        let text = included
            .map(\.text.transcript)
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        return SemanticSelection(
            level: .block,
            text: text,
            regions: included.map(\.region),
            confidence: paragraphConfidence(selectedParagraph.text)
        )
    }

    private func paragraphConfidence(_ text: DocumentObservation.Container.Text) -> Float {
        guard !text.lines.isEmpty else { return fallbackConfidence }
        return text.lines.map(\.confidence).reduce(0, +) / Float(text.lines.count)
    }

    private func globalRegion(_ region: NormalizedRegion) -> HighlightRegion {
        let points = region.points.map { point in
            CGPoint(
                x: frame.globalRect.minX + point.x * frame.globalRect.width,
                y: frame.globalRect.minY + (1 - point.y) * frame.globalRect.height
            )
        }
        if points.count >= 3 {
            return HighlightRegion(points: points)
        }

        let box = region.boundingQuad.boundingBox.toImageCoordinates(
            frame.globalRect.size,
            origin: .upperLeft
        ).offsetBy(dx: frame.globalRect.minX, dy: frame.globalRect.minY)
        return .rectangle(box)
    }

}

struct RegionSelectionHeuristics: Sendable {
    var configuration: HoveryConfiguration.RegionSelection

    init(configuration: HoveryConfiguration.RegionSelection = .init()) {
        self.configuration = configuration
    }

    func hitScore(region: HighlightRegion, pointer: CGPoint, confidence: Float) -> CGFloat {
        let rect = region.boundingRect
        guard !rect.isNull, rect.width > 0, rect.height > 0 else { return -.infinity }

        guard magneticRect(rect).contains(pointer) else { return -.infinity }

        let baseScore = rect.contains(pointer)
            ? CGFloat(configuration.directHitScore)
            : CGFloat(configuration.nearbyHitScore)
        let lineHeight = max(rect.height, CGFloat(configuration.minimumLineHeight))
        let normalizedDistance = distance(from: pointer, to: rect) / lineHeight
        let normalizedCenterDistance = abs(pointer.y - rect.midY) / lineHeight
        return baseScore
            + CGFloat(confidence) * CGFloat(configuration.confidenceWeight)
            - normalizedDistance * CGFloat(configuration.distancePenalty)
            - normalizedCenterDistance * CGFloat(configuration.verticalCenterPenalty)
    }

    func magneticRect(_ rect: CGRect) -> CGRect {
        let minimumPadding = CGFloat(configuration.minimumMagneticPadding)
        let horizontal = min(
            max(rect.height * CGFloat(configuration.magneticHorizontalScale), minimumPadding),
            CGFloat(configuration.maximumHorizontalPadding)
        )
        let vertical = min(
            max(rect.height * CGFloat(configuration.magneticVerticalScale), minimumPadding),
            CGFloat(configuration.maximumVerticalPadding)
        )
        return rect.insetBy(dx: -horizontal, dy: -vertical)
    }

    func belongsToSameBlock(_ lhs: CGRect, _ rhs: CGRect, lineHeight: CGFloat) -> Bool {
        let verticalGap = max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY, 0)
        guard verticalGap <= lineHeight * CGFloat(configuration.blockMaximumVerticalGap) else {
            return false
        }

        let overlap = horizontalOverlapRatio(lhs, rhs)
        let alignmentTolerance = lineHeight * CGFloat(configuration.blockAlignmentTolerance)
        let leadingAlignment = abs(lhs.minX - rhs.minX) <= alignmentTolerance
        let trailingAlignment = abs(lhs.maxX - rhs.maxX) <= alignmentTolerance
        return overlap > CGFloat(configuration.blockMinimumHorizontalOverlap)
            || leadingAlignment
            || trailingAlignment
    }

    func horizontalOverlapRatio(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let overlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let minimumDimension = CGFloat(configuration.minimumGeometryDimension)
        return overlap / max(min(lhs.width, rhs.width), minimumDimension)
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

private extension Array where Element == CGFloat {
    var median: CGFloat? {
        guard !isEmpty else { return nil }
        let values = sorted()
        if values.count.isMultiple(of: 2) {
            return (values[values.count / 2 - 1] + values[values.count / 2]) / 2
        }
        return values[values.count / 2]
    }
}
