import CoreML
import CoreImage
import Foundation
import QuartzCore
import Vision
import ImageIO

struct DetectionBox: Identifiable, Equatable {
    let id: UUID
    let label: String
    let confidence: Float
    let rect: CGRect

    init(id: UUID = UUID(), label: String, confidence: Float, rect: CGRect) {
        self.id = id
        self.label = label
        self.confidence = confidence
        self.rect = rect
    }
}

struct RecognitionStrip: Identifiable, Equatable {
    let id = UUID()
    let y: CGFloat
    let startX: CGFloat
    let endX: CGFloat
}

struct PersonSilhouette: Equatable {
    let strips: [RecognitionStrip]
    let bounds: CGRect
    let coverage: Double
    let source: String
    let zoneReadout: String
}

struct DetectorDebugInfo {
    var yoloCandidates: Int = 0
    var segmentationDetected = false
    var humanRectangles: Int = 0
    var activeSource = "NONE"
    var lastError = "OK"
}

enum LockState: String {
    case scanning = "SCANNING"
    case acquiring = "ACQUIRING"
    case analyzing = "ANALYZING"
    case locked = "LOCKED"
}

struct TargetTelemetry {
    var lockState: LockState = .scanning
    var lockProgress: CGFloat = 0
    var threatScore: Int = 0
    var estimatedDistanceMeters: Double = 0
    var lateralOffset: Int = 0
    var verticalOffset: Int = 0
    var stabilityScore: Int = 0
}

final class Detector: ObservableObject {
    @Published private(set) var boxes: [DetectionBox] = []
    @Published private(set) var debugInfo = DetectorDebugInfo()
    @Published private(set) var telemetry = TargetTelemetry()
    @Published private(set) var silhouette: PersonSilhouette?

    private let confidenceThreshold: Float = 0.18
    private let iouThreshold: CGFloat = 0.45
    private let minimumInferenceInterval: TimeInterval = 1.0 / 12.0
    private let smoothingFactor: CGFloat = 0.22
    private let modelInputSize: CGFloat = 640
    private let candidateCount = 8400
    private let personClassChannel = 4
    private let segmentationThreshold: UInt8 = 32
    private let ciContext = CIContext()

    private var model: yolov8n?
    private let segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private var isProcessingFrame = false
    private var lastInferenceTime: CFTimeInterval = 0
    private var trackedTarget: DetectionBox?
    private var targetLockStartTime: CFTimeInterval?

    init() {
        setupModel()
    }

    func detect(pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let now = CACurrentMediaTime()
        guard now - lastInferenceTime >= minimumInferenceInterval else { return }
        guard !isProcessingFrame else { return }

        lastInferenceTime = now
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let imageSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        let yoloDetections = yoloDetections(from: pixelBuffer, imageSize: imageSize)
        let segmentationResult = segmentationResult(from: pixelBuffer, orientation: orientation)
        let segmentationDetection = segmentationResult?.box
        let humanRectangleDetections = fallbackHumanDetections(from: pixelBuffer, orientation: orientation)

        var detections = refinedDetections(
            yoloDetections: yoloDetections,
            humanRectangleDetections: humanRectangleDetections,
            segmentationDetection: segmentationDetection
        )

        if detections.isEmpty {
            detections = humanRectangleDetections
        }

        let orderedDetections = prioritizeDetections(detections)
        let nextTarget = orderedDetections.first
        let activeSource: String
        if segmentationDetection != nil {
            activeSource = yoloDetections.isEmpty ? "SEG" : "SEG+YOLO"
        } else if !humanRectangleDetections.isEmpty {
            activeSource = "HUMAN_RECT"
        } else if !yoloDetections.isEmpty {
            activeSource = "YOLO"
        } else {
            activeSource = "NONE"
        }

        DispatchQueue.main.async {
            self.debugInfo.yoloCandidates = yoloDetections.count
            self.debugInfo.segmentationDetected = segmentationDetection != nil
            self.debugInfo.humanRectangles = humanRectangleDetections.count
            self.debugInfo.activeSource = activeSource

            if let nextTarget {
                self.trackedTarget = nextTarget
                self.boxes = orderedDetections
                self.telemetry = self.makeTelemetry(for: nextTarget, at: now)
                self.silhouette = self.matchSilhouette(
                    segmentationResult?.silhouette,
                    to: nextTarget
                )
            } else {
                self.trackedTarget = nil
                self.boxes = []
                self.targetLockStartTime = nil
                self.telemetry = TargetTelemetry()
                self.silhouette = nil
            }
        }
    }

    private func setupModel() {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        do {
            model = try yolov8n(configuration: configuration)
            print("Model loaded successfully")
        } catch {
            print("Failed to load Core ML model: \(error)")
        }
    }

    private func yoloDetections(from pixelBuffer: CVPixelBuffer, imageSize: CGSize) -> [DetectionBox] {
        guard let model else { return [] }

        do {
            let resizedBuffer = try resizedPixelBuffer(from: pixelBuffer, width: Int(modelInputSize), height: Int(modelInputSize))
            let output = try model.prediction(image: resizedBuffer)
            return makeDetections(from: output.var_911, imageSize: imageSize)
        } catch {
            print("Failed to run model prediction: \(error)")
            DispatchQueue.main.async {
                self.debugInfo.lastError = "MODEL \(error.localizedDescription)"
            }
            return []
        }
    }

    private func makeDetections(from output: MLMultiArray, imageSize: CGSize) -> [DetectionBox] {
        guard output.count >= candidateCount * 5 else { return [] }

        var candidates: [DetectionBox] = []
        candidates.reserveCapacity(12)

        for anchor in 0..<candidateCount {
            let confidence = output[personClassChannel * candidateCount + anchor].floatValue
            guard confidence >= confidenceThreshold else { continue }

            let centerX = normalizeCoordinate(output[anchor].floatValue)
            let centerY = normalizeCoordinate(output[candidateCount + anchor].floatValue)
            let width = normalizeCoordinate(output[(candidateCount * 2) + anchor].floatValue)
            let height = normalizeCoordinate(output[(candidateCount * 3) + anchor].floatValue)

            let squareRect = CGRect(
                x: centerX - (width / 2),
                y: centerY - (height / 2),
                width: width,
                height: height
            )

            let mappedRect = remapFromModelSquare(squareRect, imageSize: imageSize)
                .standardized
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))

            guard !mappedRect.isNull else { continue }
            guard mappedRect.width > 0.02, mappedRect.height > 0.02 else { continue }

            candidates.append(
                DetectionBox(
                    label: "person",
                    confidence: confidence,
                    rect: mappedRect
                )
            )
        }

        return nonMaximumSuppression(candidates)
    }

    private func normalizeCoordinate(_ value: Float) -> CGFloat {
        let coordinate = CGFloat(value)
        if coordinate > 1.5 || coordinate < -0.5 {
            return coordinate / modelInputSize
        }
        return coordinate
    }

    private func remapFromModelSquare(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        if imageSize.height > imageSize.width {
            let scale = imageSize.width / imageSize.height
            let verticalInset = (1 - scale) / 2
            return CGRect(
                x: rect.minX,
                y: verticalInset + (rect.minY * scale),
                width: rect.width,
                height: rect.height * scale
            )
        }

        let scale = imageSize.height / imageSize.width
        let horizontalInset = (1 - scale) / 2
        return CGRect(
            x: horizontalInset + (rect.minX * scale),
            y: rect.minY,
            width: rect.width * scale,
            height: rect.height
        )
    }

    private func nonMaximumSuppression(_ detections: [DetectionBox]) -> [DetectionBox] {
        let sorted = detections.sorted { $0.confidence > $1.confidence }
        var kept: [DetectionBox] = []

        for detection in sorted {
            let hasOverlap = kept.contains { intersectionOverUnion(lhs: detection.rect, rhs: $0.rect) > iouThreshold }
            if !hasOverlap {
                kept.append(detection)
            }
        }

        return kept
    }

    private func segmentationResult(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> (box: DetectionBox, silhouette: PersonSilhouette)? {
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            try handler.perform([segmentationRequest])

            guard let result = segmentationRequest.results?.first else { return nil }
            return detectionFromSegmentationMask(result.pixelBuffer)
        } catch {
            print("Vision person segmentation failed: \(error)")
            return nil
        }
    }

    private func detectionFromSegmentationMask(_ pixelBuffer: CVPixelBuffer) -> (box: DetectionBox, silhouette: PersonSilhouette)? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var activeCount = 0
        var strips: [RecognitionStrip] = []
        let rowStep = max(3, height / 80)

        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            var rowMinX = width
            var rowMaxX = -1

            for x in 0..<width where row[x] >= segmentationThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                rowMinX = min(rowMinX, x)
                rowMaxX = max(rowMaxX, x)
                activeCount += 1
            }

            if y.isMultiple(of: rowStep), rowMaxX >= rowMinX {
                let rowWidth = rowMaxX - rowMinX + 1
                let inset = max(1, Int(Double(rowWidth) * 0.12))
                strips.append(
                    RecognitionStrip(
                        y: 1 - (CGFloat(y) / CGFloat(height)),
                        startX: CGFloat(min(rowMinX + inset, rowMaxX)) / CGFloat(width),
                        endX: CGFloat(max(rowMinX, rowMaxX - inset) + 1) / CGFloat(width)
                    )
                )
            }
        }

        guard maxX >= minX, maxY >= minY else { return nil }

        let normalizedRect = CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: 1 - (CGFloat(maxY + 1) / CGFloat(height)),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )

        guard normalizedRect.width > 0.06, normalizedRect.height > 0.12 else { return nil }

        let coverage = Double(activeCount) / Double(width * height)
        let silhouette = PersonSilhouette(
            strips: trimmedStrips(from: strips, bounds: normalizedRect),
            bounds: normalizedRect,
            coverage: coverage,
            source: "SEGMENTATION",
            zoneReadout: zoneReadout(from: strips)
        )

        return (
            DetectionBox(
                label: "person",
                confidence: 0.95,
                rect: normalizedRect
            ),
            silhouette
        )
    }

    private func refinedDetections(
        yoloDetections: [DetectionBox],
        humanRectangleDetections: [DetectionBox],
        segmentationDetection: DetectionBox?
    ) -> [DetectionBox] {
        if !humanRectangleDetections.isEmpty {
            return humanRectangleDetections
                .map { humanRect in
                    let yoloMatch = bestMatch(for: humanRect, in: yoloDetections)
                    let segmentationMatch = segmentationDetection.flatMap { segmentation in
                        intersectionOverUnion(lhs: humanRect.rect, rhs: segmentation.rect) > 0.08 ? segmentation : nil
                    }

                    let refinedRect = refinedHumanRect(
                        humanRect: humanRect.rect,
                        yoloRect: yoloMatch?.rect,
                        segmentationRect: segmentationMatch?.rect
                    )

                    return DetectionBox(
                        id: humanRect.id,
                        label: "person",
                        confidence: max(
                            humanRect.confidence,
                            yoloMatch?.confidence ?? 0,
                            segmentationMatch?.confidence ?? 0
                        ),
                        rect: refinedRect
                    )
                }
                .sorted { $0.confidence > $1.confidence }
        }

        guard let segmentationDetection else {
            return yoloDetections
        }

        guard !yoloDetections.isEmpty else {
            return [segmentationDetection]
        }

        if let matchedDetection = bestMatch(for: segmentationDetection, in: yoloDetections),
           intersectionOverUnion(lhs: matchedDetection.rect, rhs: segmentationDetection.rect) > 0.15 {
            let merged = DetectionBox(
                id: matchedDetection.id,
                label: "person",
                confidence: max(matchedDetection.confidence, segmentationDetection.confidence),
                rect: blendRects(primary: matchedDetection.rect, secondary: segmentationDetection.rect, factor: 0.2)
            )

            let remainder = yoloDetections
                .filter { $0.id != matchedDetection.id }
                .sorted { $0.confidence > $1.confidence }

            return [merged] + remainder
        }

        return yoloDetections.sorted { $0.confidence > $1.confidence } + [segmentationDetection]
    }

    private func fallbackHumanDetections(from pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> [DetectionBox] {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        request.revision = VNDetectHumanRectanglesRequestRevision2

        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
            try handler.perform([request])
            let observations = request.results ?? []

            return observations.map {
                DetectionBox(
                    label: "person",
                    confidence: $0.confidence,
                    rect: $0.boundingBox
                )
            }
        } catch {
            print("Vision human detection failed: \(error)")
            DispatchQueue.main.async {
                self.debugInfo.lastError = "VISION \(error.localizedDescription)"
            }
            return []
        }
    }

    private func intersectionOverUnion(lhs: CGRect, rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }

        let union = lhs.area + rhs.area - intersection.area
        guard union > 0 else { return 0 }

        return intersection.area / union
    }

    private func prioritizeDetections(_ candidates: [DetectionBox]) -> [DetectionBox] {
        guard !candidates.isEmpty else { return [] }

        let selected: DetectionBox
        if let trackedTarget {
            selected = candidates.max { lhs, rhs in
                score(for: lhs, against: trackedTarget) < score(for: rhs, against: trackedTarget)
            } ?? candidates[0]
        } else {
            selected = candidates.max(by: { $0.confidence < $1.confidence }) ?? candidates[0]
        }

        let target = smoothedTarget(from: selected)
        let remainder = candidates
            .filter { $0.id != selected.id }
            .sorted { $0.confidence > $1.confidence }

        return [target] + remainder
    }

    private func score(for candidate: DetectionBox, against currentTarget: DetectionBox) -> CGFloat {
        let confidenceScore = CGFloat(candidate.confidence) * 100
        let overlapScore = candidate.rect.intersection(currentTarget.rect).isNull ? 0 : candidate.rect.intersection(currentTarget.rect).area * 250
        let distancePenalty = normalizedDistance(from: candidate.rect.center, to: currentTarget.rect.center) * 80
        return confidenceScore + overlapScore - distancePenalty
    }

    private func smoothedTarget(from candidate: DetectionBox) -> DetectionBox {
        guard let previous = trackedTarget else { return candidate }

        let smoothedRect = CGRect(
            x: previous.rect.minX + (candidate.rect.minX - previous.rect.minX) * smoothingFactor,
            y: previous.rect.minY + (candidate.rect.minY - previous.rect.minY) * smoothingFactor,
            width: previous.rect.width + (candidate.rect.width - previous.rect.width) * smoothingFactor,
            height: previous.rect.height + (candidate.rect.height - previous.rect.height) * smoothingFactor
        )

        let smoothedConfidence = previous.confidence + Float(smoothingFactor) * (candidate.confidence - previous.confidence)

        return DetectionBox(
            id: previous.id,
            label: candidate.label,
            confidence: smoothedConfidence,
            rect: smoothedRect
        )
    }

    private func normalizedDistance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return sqrt(dx * dx + dy * dy)
    }

    private func blendRects(primary: CGRect, secondary: CGRect, factor: CGFloat) -> CGRect {
        CGRect(
            x: primary.minX + (secondary.minX - primary.minX) * factor,
            y: primary.minY + (secondary.minY - primary.minY) * factor,
            width: primary.width + (secondary.width - primary.width) * factor,
            height: primary.height + (secondary.height - primary.height) * factor
        )
    }

    private func bestMatch(for detection: DetectionBox, in candidates: [DetectionBox]) -> DetectionBox? {
        candidates.max {
            intersectionOverUnion(lhs: $0.rect, rhs: detection.rect) <
            intersectionOverUnion(lhs: $1.rect, rhs: detection.rect)
        }
    }

    private func refinedHumanRect(humanRect: CGRect, yoloRect: CGRect?, segmentationRect: CGRect?) -> CGRect {
        var rect = humanRect

        if let yoloRect, intersectionOverUnion(lhs: humanRect, rhs: yoloRect) > 0.08 {
            rect = blendRects(primary: rect, secondary: yoloRect, factor: 0.18)
        }

        if let segmentationRect, intersectionOverUnion(lhs: rect, rhs: segmentationRect) > 0.08 {
            rect = CGRect(
                x: max(rect.minX, segmentationRect.minX),
                y: max(rect.minY, segmentationRect.minY),
                width: min(rect.maxX, segmentationRect.maxX) - max(rect.minX, segmentationRect.minX),
                height: min(rect.maxY, segmentationRect.maxY) - max(rect.minY, segmentationRect.minY)
            ).standardized
        }

        let insetX = rect.width * 0.06
        let insetY = rect.height * 0.05
        return rect
            .insetBy(dx: insetX, dy: insetY)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func resizedPixelBuffer(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) throws -> CVPixelBuffer {
        var resizedBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &resizedBuffer
        )

        guard let resizedBuffer else {
            throw NSError(domain: "Detector", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create resized pixel buffer"])
        }

        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let scaleX = CGFloat(width) / sourceImage.extent.width
        let scaleY = CGFloat(height) / sourceImage.extent.height
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        ciContext.render(scaledImage, to: resizedBuffer)
        return resizedBuffer
    }

    private func makeTelemetry(for target: DetectionBox, at now: CFTimeInterval) -> TargetTelemetry {
        if targetLockStartTime == nil {
            targetLockStartTime = now
        }

        let elapsed = now - (targetLockStartTime ?? now)
        let progress = min(max(elapsed / 0.95, 0), 1)
        let lockState: LockState
        switch progress {
        case ..<0.28:
            lockState = .acquiring
        case ..<0.72:
            lockState = .analyzing
        default:
            lockState = .locked
        }

        let area = max(target.rect.width * target.rect.height, 0.001)
        let estimatedDistance = max(0.6, min(9.9, 1.85 / sqrt(area * 8.5)))
        let threatBase = (Double(target.confidence) * 62) + ((1 / estimatedDistance) * 30) + (Double(progress) * 8)
        let threatScore = min(99, max(12, Int(threatBase.rounded())))
        let lateralOffset = Int((target.rect.midX - 0.5) * 1000)
        let verticalOffset = Int((0.5 - target.rect.midY) * 1000)
        let stabilityScore = min(99, max(18, Int((progress * 100) * 0.7 + Double(target.confidence) * 30)))

        return TargetTelemetry(
            lockState: lockState,
            lockProgress: progress,
            threatScore: threatScore,
            estimatedDistanceMeters: estimatedDistance,
            lateralOffset: lateralOffset,
            verticalOffset: verticalOffset,
            stabilityScore: stabilityScore
        )
    }

    private func zoneReadout(from strips: [RecognitionStrip]) -> String {
        guard !strips.isEmpty else { return "HEAD:0 TORSO:0 LEGS:0" }

        let head = strips.filter { $0.y > 0.66 }.count
        let torso = strips.filter { $0.y <= 0.66 && $0.y > 0.33 }.count
        let legs = strips.filter { $0.y <= 0.33 }.count

        return "HEAD:\(head > 1 ? 1 : 0) TORSO:\(torso > 1 ? 1 : 0) LEGS:\(legs > 1 ? 1 : 0)"
    }

    private func matchSilhouette(_ silhouette: PersonSilhouette?, to target: DetectionBox) -> PersonSilhouette? {
        guard let silhouette else { return nil }
        return intersectionOverUnion(lhs: silhouette.bounds, rhs: target.rect) > 0.08 ? silhouette : nil
    }

    private func trimmedStrips(from strips: [RecognitionStrip], bounds: CGRect) -> [RecognitionStrip] {
        strips.compactMap { strip in
            guard strip.y <= bounds.maxY, strip.y >= bounds.minY else { return nil }

            let center = (strip.startX + strip.endX) / 2
            let halfWidth = max((strip.endX - strip.startX) * 0.36, 0.008)
            let tightenedStart = max(bounds.minX, center - halfWidth)
            let tightenedEnd = min(bounds.maxX, center + halfWidth)

            guard tightenedEnd - tightenedStart > 0.01 else { return nil }

            return RecognitionStrip(
                y: strip.y,
                startX: tightenedStart,
                endX: tightenedEnd
            )
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    var area: CGFloat {
        width * height
    }
}
