import CoreVideo
import Foundation
import simd

enum PhotoObjectMeasurementError: Error, Equatable, Sendable {
    case invalidLabelMaskDimensions
    case invalidDepthMaskDimensions
    case invalidPolicy
    case unsupportedLabelMaskPixelFormat(OSType)
    case invalidLabelMaskPixelValue
    case noForegroundInstance
    case ambiguousForegroundInstances(labels: [UInt32])
    case noReticleDepthSurface
    case maskAreaTooSmall(actual: Float, minimum: Float)
    case maskAreaTooLarge(actual: Float, maximum: Float)
    case maskTouchesImageEdge
    case maskCalibrationAspectRatioMismatch
    case depthGridResolutionMismatch
    case insufficientDepthSamples(actual: Int, minimum: Int)
    case insufficientDepthCoverage(actual: Float, minimum: Float)
    case insufficientHorizontalDepthSupport(actual: Float, minimum: Float)
    case insufficientVerticalDepthSupport(actual: Float, minimum: Float)
    case insufficientHorizontalDepthEndpointCoverage(actual: Float, minimum: Float)
    case insufficientVerticalDepthEndpointCoverage(actual: Float, minimum: Float)
    case multipleRigidItemsDetected(PhotoRigidItemMultiplicityEvidence)
    case invalidCameraCalibration
    case invalidWorldPoint
}

/// Immutable selection intent captured with the settled camera frame.
///
/// A missing prompt preserves the legacy automatic-center path. `.stale`
/// deliberately remains distinct from no prompt so a superseded explicit tap
/// cannot silently fall back to whatever happens to occupy image center.
enum PhotoTargetSelectionPrompt: Equatable, Sendable {
    case target(normalizedImagePoint: SIMD2<Float>)
    case stale
}

enum PhotoTargetSelectionError: Error, Equatable, Sendable {
    case invalidTargetSelectionPoint
    case staleTargetSelectionPrompt
    case noForegroundAtTargetPoint
}

/// Integer instance labels produced by a foreground segmentation adapter.
/// Label zero is treated as background by default; this type is independent of
/// Vision so the selection and registration rules remain deterministic.
struct PhotoInstanceLabelMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let labels: [UInt32]

    init(width: Int, height: Int, labels: [UInt32]) throws {
        guard width > 0,
              height > 0,
              labels.count == width * height else {
            throw PhotoObjectMeasurementError.invalidLabelMaskDimensions
        }
        self.width = width
        self.height = height
        self.labels = labels
    }

    init(pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw PhotoObjectMeasurementError.invalidLabelMaskDimensions
        }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw PhotoObjectMeasurementError.unsupportedLabelMaskPixelFormat(format)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw PhotoObjectMeasurementError.unsupportedLabelMaskPixelFormat(format)
        }

        switch format {
        case kCVPixelFormatType_OneComponent8:
            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt8>.stride
            let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var labels = Array(repeating: UInt32.zero, count: width * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowStride)
                for x in 0..<width {
                    labels[y * width + x] = UInt32(row[x])
                }
            }
            try self.init(width: width, height: height, labels: labels)
        case kCVPixelFormatType_OneComponent16:
            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer) / MemoryLayout<UInt16>.stride
            let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
            var labels = Array(repeating: UInt32.zero, count: width * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowStride)
                for x in 0..<width {
                    labels[y * width + x] = UInt32(row[x])
                }
            }
            try self.init(width: width, height: height, labels: labels)
        case kCVPixelFormatType_OneComponent32Float:
            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                / MemoryLayout<Float32>.stride
            let pointer = baseAddress.assumingMemoryBound(to: Float32.self)
            var labels = Array(repeating: UInt32.zero, count: width * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowStride)
                for x in 0..<width {
                    let value = row[x]
                    guard value.isFinite,
                          value >= 0,
                          Double(value) <= Double(UInt32.max) else {
                        throw PhotoObjectMeasurementError.invalidLabelMaskPixelValue
                    }
                    labels[y * width + x] = UInt32(value.rounded())
                }
            }
            try self.init(width: width, height: height, labels: labels)
        default:
            throw PhotoObjectMeasurementError.unsupportedLabelMaskPixelFormat(format)
        }
    }

    func labelAt(x: Int, y: Int) -> UInt32 {
        labels[y * width + x]
    }
}

/// A compact vector trace of the image pixels selected for measurement.
///
/// Points use normalized camera-image coordinates. Keeping only contour loops
/// avoids retaining an AR frame, pixel buffer, or full-resolution mask after
/// the settled photo has been processed.
struct MeasurementObjectOutline: Equatable, Sendable {
    private static let maximumSegmentCount = 12_000

    let loops: [[SIMD2<Float>]]

    var isEmpty: Bool { loops.isEmpty }

    /// Returns the display silhouette of the selected measurement region.
    ///
    /// Marching squares intentionally retains every boundary so the measurement
    /// outline remains an exact, auditable description of its support mask. For
    /// presentation, however, an interior hole should not receive the same cyan
    /// stroke as the object's exterior. Even-odd nesting removes only hole
    /// boundaries while preserving each original exterior loop point-for-point,
    /// including concavities and disconnected exterior islands.
    var exteriorSilhouette: MeasurementObjectOutline {
        guard loops.count > 1 else { return self }

        let exteriorLoops: [[SIMD2<Float>]] = loops.indices.compactMap { index in
            let loop = loops[index]
            guard let probe = loop.first else { return nil }
            let nestingDepth = loops.enumerated().reduce(into: 0) { depth, candidate in
                guard candidate.offset != index else { return }
                if Self.contains(probe, in: candidate.element) {
                    depth += 1
                }
            }
            return nestingDepth.isMultiple(of: 2) ? loop : nil
        }

        // Valid mask-derived outlines always have at least one exterior. Keep
        // malformed manually supplied outlines visible rather than hiding them.
        guard !exteriorLoops.isEmpty else { return self }
        return MeasurementObjectOutline(loops: exteriorLoops)
    }

    init(loops: [[SIMD2<Float>]]) {
        self.loops = loops.filter { $0.count >= 3 }
    }

    init?(width: Int, height: Int, selectedIndices: [Int]) {
        guard width > 0, height > 0, !selectedIndices.isEmpty else { return nil }

        var selected = Array(repeating: false, count: width * height)
        for index in selectedIndices where selected.indices.contains(index) {
            selected[index] = true
        }
        guard selected.contains(true) else { return nil }

        let segments = Self.marchingSquaresSegments(
            width: width,
            height: height,
            selected: selected
        )
        guard segments.count <= Self.maximumSegmentCount else { return nil }
        let tracedLoops = Self.traceLoops(from: segments)
            .map { loop in
                loop.map { point in
                    let imageX = Float(point.x - 1) / 2
                    let imageY = Float(point.y - 1) / 2
                    return SIMD2<Float>(
                        imageX / Float(width),
                        imageY / Float(height)
                    )
                }
            }
            .filter { $0.count >= 3 }

        guard !tracedLoops.isEmpty else { return nil }
        self.loops = tracedLoops
    }

    func mappingPoints(
        _ transform: (SIMD2<Float>) -> SIMD2<Float>
    ) -> MeasurementObjectOutline {
        MeasurementObjectOutline(loops: loops.map { $0.map(transform) })
    }

    /// Even-odd polygon containment for nonintersecting marching-squares loops.
    /// A vertex from a nested loop is strictly inside its parent boundary, so it
    /// is a stable probe without inventing a centroid that may leave a concavity.
    private static func contains(
        _ point: SIMD2<Float>,
        in polygon: [SIMD2<Float>]
    ) -> Bool {
        guard polygon.count >= 3,
              point.x.isFinite,
              point.y.isFinite,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return false
        }

        var isInside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            let crossesRay = (current.y > point.y) != (previous.y > point.y)
            if crossesRay {
                let intersectionX = current.x
                    + (point.y - current.y) * (previous.x - current.x)
                        / (previous.y - current.y)
                if point.x < intersectionX {
                    isInside.toggle()
                }
            }
            previous = current
        }
        return isInside
    }

    private struct LatticePoint: Hashable {
        let x: Int
        let y: Int
    }

    private struct Segment: Hashable {
        let first: LatticePoint
        let second: LatticePoint

        init(_ first: LatticePoint, _ second: LatticePoint) {
            if first.x < second.x || (first.x == second.x && first.y <= second.y) {
                self.first = first
                self.second = second
            } else {
                self.first = second
                self.second = first
            }
        }
    }

    /// Marching squares over a one-pixel false border produces closed contours
    /// for edge-adjacent selections without any special-case clipping logic.
    private static func marchingSquaresSegments(
        width: Int,
        height: Int,
        selected: [Bool]
    ) -> [Segment] {
        func contains(paddedX: Int, paddedY: Int) -> Bool {
            let x = paddedX - 1
            let y = paddedY - 1
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return selected[y * width + x]
        }

        var segments: [Segment] = []
        segments.reserveCapacity((width + height) * 2)

        for y in 0...height {
            for x in 0...width {
                let topLeft = contains(paddedX: x, paddedY: y) ? 8 : 0
                let topRight = contains(paddedX: x + 1, paddedY: y) ? 4 : 0
                let bottomRight = contains(paddedX: x + 1, paddedY: y + 1) ? 2 : 0
                let bottomLeft = contains(paddedX: x, paddedY: y + 1) ? 1 : 0
                let value = topLeft | topRight | bottomRight | bottomLeft

                let top = LatticePoint(x: 2 * x + 1, y: 2 * y)
                let right = LatticePoint(x: 2 * x + 2, y: 2 * y + 1)
                let bottom = LatticePoint(x: 2 * x + 1, y: 2 * y + 2)
                let left = LatticePoint(x: 2 * x, y: 2 * y + 1)

                switch value {
                case 1: segments.append(Segment(left, bottom))
                case 2: segments.append(Segment(bottom, right))
                case 3: segments.append(Segment(left, right))
                case 4: segments.append(Segment(top, right))
                case 5:
                    segments.append(Segment(top, right))
                    segments.append(Segment(bottom, left))
                case 6: segments.append(Segment(top, bottom))
                case 7: segments.append(Segment(top, left))
                case 8: segments.append(Segment(left, top))
                case 9: segments.append(Segment(top, bottom))
                case 10:
                    segments.append(Segment(left, top))
                    segments.append(Segment(right, bottom))
                case 11: segments.append(Segment(top, right))
                case 12: segments.append(Segment(left, right))
                case 13: segments.append(Segment(right, bottom))
                case 14: segments.append(Segment(bottom, left))
                default: break
                }
            }
        }
        return segments
    }

    private static func traceLoops(from segments: [Segment]) -> [[LatticePoint]] {
        var adjacency: [LatticePoint: [LatticePoint]] = [:]
        for segment in segments {
            adjacency[segment.first, default: []].append(segment.second)
            adjacency[segment.second, default: []].append(segment.first)
        }

        var visited: Set<Segment> = []
        var loops: [[LatticePoint]] = []

        for segment in segments where !visited.contains(segment) {
            let start = segment.first
            var previous = segment.first
            var current = segment.second
            var loop = [start]
            visited.insert(segment)

            while current != start {
                loop.append(current)
                guard let next = adjacency[current]?.first(where: { candidate in
                    candidate != previous && !visited.contains(Segment(current, candidate))
                }) else {
                    loop.removeAll()
                    break
                }
                visited.insert(Segment(current, next))
                previous = current
                current = next
            }

            if loop.count >= 3 {
                loops.append(loop)
            }
        }
        return loops
    }
}

/// The outline produced from the exact settled camera frame used for an angle.
///
/// The contour is converted into display-oriented image coordinates while that
/// frame is still available. The preview can therefore reproject it after a
/// layout change without consulting `ARSession.currentFrame`, which may already
/// have advanced past the measured RGB/depth pair.
struct MeasurementObjectOverlay: Equatable, Sendable {
    let displayOrientedImageSize: SIMD2<Float>
    let outline: MeasurementObjectOutline
    /// The live camera viewport aspect ratio used when this exact frame was
    /// captured. The paused result must preserve it so the visible image and
    /// measured contour cannot acquire a new aspect-fill crop during review.
    let capturedPreviewAspectRatio: Float

    init(
        displayOrientedImageSize: SIMD2<Float>,
        outline: MeasurementObjectOutline,
        capturedPreviewAspectRatio: Float? = nil
    ) {
        self.displayOrientedImageSize = displayOrientedImageSize
        // The measured support retains all contour loops. Only the presentation
        // overlay suppresses hole boundaries to communicate one exterior trace.
        self.outline = outline.exteriorSilhouette
        self.capturedPreviewAspectRatio = capturedPreviewAspectRatio
            ?? displayOrientedImageSize.x / displayOrientedImageSize.y
    }

    var isRenderable: Bool {
        displayOrientedImageSize.x.isFinite
            && displayOrientedImageSize.y.isFinite
            && displayOrientedImageSize.x > 0
            && displayOrientedImageSize.y > 0
            && capturedPreviewAspectRatio.isFinite
            && capturedPreviewAspectRatio > 0
            && !outline.isEmpty
            && outline.loops.flatMap { $0 }.allSatisfy { point in
                point.x.isFinite && point.y.isFinite
            }
    }

    /// Maps an oriented-image point through the same centered aspect-fill rule
    /// used by the camera background into normalized preview coordinates.
    func normalizedPreviewPoint(
        _ point: SIMD2<Float>,
        viewportSize: SIMD2<Float>
    ) -> SIMD2<Float>? {
        guard isRenderable,
              viewportSize.x.isFinite,
              viewportSize.y.isFinite,
              viewportSize.x > 0,
              viewportSize.y > 0 else {
            return nil
        }

        let scale = max(
            viewportSize.x / displayOrientedImageSize.x,
            viewportSize.y / displayOrientedImageSize.y
        )
        let displayedSize = displayOrientedImageSize * scale
        let origin = (viewportSize - displayedSize) / 2
        return (origin + point * displayedSize) / viewportSize
    }

    /// Verifies the measured contour remains inside the portion of the camera
    /// image the user could actually see. The source mask can be clear of the
    /// captured-image edge while a short, wide SwiftUI preview aspect-fills and
    /// crops it. Accepting that capture would draw a contour closed against the
    /// preview boundary and can hide a missing endpoint from the measurement.
    func isFullyVisible(
        in viewportSize: SIMD2<Float>,
        protectedInsetFraction: Float = 0
    ) -> Bool {
        guard isRenderable,
              protectedInsetFraction.isFinite,
              protectedInsetFraction >= 0,
              protectedInsetFraction < 0.5 else {
            return false
        }

        let maximum = 1 - protectedInsetFraction
        return outline.loops.flatMap { $0 }.allSatisfy { point in
            guard let mapped = normalizedPreviewPoint(
                point,
                viewportSize: viewportSize
            ) else {
                return false
            }
            return mapped.x >= protectedInsetFraction
                && mapped.x <= maximum
                && mapped.y >= protectedInsetFraction
                && mapped.y <= maximum
        }
    }
}

struct PhotoMaskQuality: Equatable, Sendable {
    let selectedPixelCount: Int
    let areaFraction: Float
    let touchesProtectedEdge: Bool
}

struct PhotoSelectedInstanceMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let label: UInt32
    private let selected: [Bool]

    fileprivate init(width: Int, height: Int, label: UInt32, selected: [Bool]) {
        self.width = width
        self.height = height
        self.label = label
        self.selected = selected
    }

    var selectedPixelCount: Int {
        selected.reduce(into: 0) { count, isSelected in
            if isSelected { count += 1 }
        }
    }

    func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return selected[y * width + x]
    }

    func quality(edgeMarginPixels: Int) -> PhotoMaskQuality {
        let margin = max(0, edgeMarginPixels)
        var count = 0
        var touchesProtectedEdge = false

        for index in selected.indices where selected[index] {
            count += 1
            let x = index % width
            let y = index / width
            if x <= margin
                || y <= margin
                || x >= width - 1 - margin
                || y >= height - 1 - margin {
                touchesProtectedEdge = true
            }
        }

        return PhotoMaskQuality(
            selectedPixelCount: count,
            areaFraction: Float(count) / Float(width * height),
            touchesProtectedEdge: touchesProtectedEdge
        )
    }

    /// Nearest-neighbor sampling at each depth cell's normalized center keeps
    /// the mask aligned even when image and LiDAR grids have non-integer scale.
    func resampled(toWidth targetWidth: Int, height targetHeight: Int) throws
        -> PhotoDepthSelectionMask {
        guard targetWidth > 0, targetHeight > 0 else {
            throw PhotoObjectMeasurementError.invalidDepthMaskDimensions
        }

        var depthSelection = Array(repeating: false, count: targetWidth * targetHeight)
        let scaleX = Float(width) / Float(targetWidth)
        let scaleY = Float(height) / Float(targetHeight)
        for y in 0..<targetHeight {
            let sourceY = min(height - 1, Int((Float(y) + 0.5) * scaleY))
            for x in 0..<targetWidth {
                let sourceX = min(width - 1, Int((Float(x) + 0.5) * scaleX))
                depthSelection[y * targetWidth + x] = contains(x: sourceX, y: sourceY)
            }
        }

        return try PhotoDepthSelectionMask(
            width: targetWidth,
            height: targetHeight,
            selected: depthSelection
        )
    }
}

struct PhotoForegroundInstanceSelector: Sendable {
    var backgroundLabel: UInt32 = 0

    func select(
        in mask: PhotoInstanceLabelMask,
        prompt: PhotoTargetSelectionPrompt? = nil
    ) throws -> PhotoSelectedInstanceMask {
        let explicitTargetPixel: (x: Int, y: Int)?
        switch prompt {
        case .none:
            explicitTargetPixel = nil
        case .stale:
            throw PhotoTargetSelectionError.staleTargetSelectionPrompt
        case .target(let normalizedImagePoint):
            explicitTargetPixel = try pixel(
                at: normalizedImagePoint,
                width: mask.width,
                height: mask.height
            )
        }

        let centerLabel = mask.labelAt(x: mask.width / 2, y: mask.height / 2)
        let foregroundLabels = Set(mask.labels.filter { $0 != backgroundLabel }).sorted()

        let selectedLabel: UInt32
        if let explicitTargetPixel {
            let targetLabel = mask.labelAt(
                x: explicitTargetPixel.x,
                y: explicitTargetPixel.y
            )
            guard targetLabel != backgroundLabel else {
                throw PhotoTargetSelectionError.noForegroundAtTargetPoint
            }
            selectedLabel = targetLabel
        } else if centerLabel != backgroundLabel {
            selectedLabel = centerLabel
        } else if foregroundLabels.count == 1, let soleLabel = foregroundLabels.first {
            selectedLabel = soleLabel
        } else if foregroundLabels.isEmpty {
            throw PhotoObjectMeasurementError.noForegroundInstance
        } else {
            throw PhotoObjectMeasurementError.ambiguousForegroundInstances(
                labels: foregroundLabels
            )
        }

        let matchingSelection = mask.labels.map { $0 == selectedLabel }
        let selectedComponent: [Int]
        if let explicitTargetPixel {
            selectedComponent = component(
                containing: explicitTargetPixel.y * mask.width + explicitTargetPixel.x,
                in: matchingSelection,
                width: mask.width,
                height: mask.height
            )
        } else {
            selectedComponent = componentNearestImageCenter(
                in: matchingSelection,
                width: mask.width,
                height: mask.height
            )
        }
        var isolatedSelection = Array(repeating: false, count: matchingSelection.count)
        for index in selectedComponent {
            isolatedSelection[index] = true
        }

        return PhotoSelectedInstanceMask(
            width: mask.width,
            height: mask.height,
            label: selectedLabel,
            selected: isolatedSelection
        )
    }

    private func pixel(
        at normalizedImagePoint: SIMD2<Float>,
        width: Int,
        height: Int
    ) throws -> (x: Int, y: Int) {
        guard normalizedImagePoint.x.isFinite,
              normalizedImagePoint.y.isFinite,
              (0...1).contains(normalizedImagePoint.x),
              (0...1).contains(normalizedImagePoint.y) else {
            throw PhotoTargetSelectionError.invalidTargetSelectionPoint
        }

        return (
            min(width - 1, Int(normalizedImagePoint.x * Float(width))),
            min(height - 1, Int(normalizedImagePoint.y * Float(height)))
        )
    }

    private func component(
        containing seed: Int,
        in selected: [Bool],
        width: Int,
        height: Int
    ) -> [Int] {
        guard selected.indices.contains(seed), selected[seed] else { return [] }

        var visited = Array(repeating: false, count: selected.count)
        visited[seed] = true
        var component = [seed]
        var readIndex = 0
        while readIndex < component.count {
            let index = component[readIndex]
            readIndex += 1
            let x = index % width
            let y = index / width
            for offsetY in -1...1 {
                for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                    let neighborX = x + offsetX
                    let neighborY = y + offsetY
                    guard neighborX >= 0,
                          neighborX < width,
                          neighborY >= 0,
                          neighborY < height else {
                        continue
                    }
                    let neighbor = neighborY * width + neighborX
                    guard selected[neighbor], !visited[neighbor] else { continue }
                    visited[neighbor] = true
                    component.append(neighbor)
                }
            }
        }
        return component
    }

    /// Vision can occasionally assign one instance label to multiple disconnected
    /// foreground islands. The scanner contract is reticle-driven, so retain only
    /// the island containing or nearest the image center instead of measuring every
    /// same-label object in the photo.
    private func componentNearestImageCenter(
        in selected: [Bool],
        width: Int,
        height: Int
    ) -> [Int] {
        var visited = Array(repeating: false, count: selected.count)
        var components: [[Int]] = []

        for seed in selected.indices where selected[seed] && !visited[seed] {
            visited[seed] = true
            var component = [seed]
            var readIndex = 0
            while readIndex < component.count {
                let index = component[readIndex]
                readIndex += 1
                let x = index % width
                let y = index / width
                for offsetY in -1...1 {
                    for offsetX in -1...1 where offsetX != 0 || offsetY != 0 {
                        let neighborX = x + offsetX
                        let neighborY = y + offsetY
                        guard neighborX >= 0,
                              neighborX < width,
                              neighborY >= 0,
                              neighborY < height else {
                            continue
                        }
                        let neighbor = neighborY * width + neighborX
                        guard selected[neighbor], !visited[neighbor] else { continue }
                        visited[neighbor] = true
                        component.append(neighbor)
                    }
                }
            }
            components.append(component)
        }

        let centerX = width / 2
        let centerY = height / 2
        return components.min { lhs, rhs in
            let lhsDistance = minimumSquaredDistance(
                from: lhs,
                toX: centerX,
                y: centerY,
                width: width
            )
            let rhsDistance = minimumSquaredDistance(
                from: rhs,
                toX: centerX,
                y: centerY,
                width: width
            )
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.min() ?? .max) < (rhs.min() ?? .max)
        } ?? []
    }

    private func minimumSquaredDistance(
        from component: [Int],
        toX centerX: Int,
        y centerY: Int,
        width: Int
    ) -> Int {
        component.reduce(Int.max) { distance, index in
            let deltaX = index % width - centerX
            let deltaY = index / width - centerY
            return min(distance, deltaX * deltaX + deltaY * deltaY)
        }
    }
}

struct PhotoDepthSelectionMask: Equatable, Sendable {
    let width: Int
    let height: Int
    private let selected: [Bool]

    init(width: Int, height: Int, selected: [Bool]) throws {
        guard width > 0,
              height > 0,
              selected.count == width * height else {
            throw PhotoObjectMeasurementError.invalidDepthMaskDimensions
        }
        self.width = width
        self.height = height
        self.selected = selected
    }

    var selectedPixelCount: Int {
        selected.reduce(into: 0) { count, isSelected in
            if isSelected { count += 1 }
        }
    }

    func contains(x: Int, y: Int) -> Bool {
        guard x >= 0, x < width, y >= 0, y < height else { return false }
        return selected[y * width + x]
    }

    var selectedIndices: [Int] {
        selected.indices.filter { selected[$0] }
    }
}

/// Refines Vision's appearance mask with the LiDAR surface connected to the
/// explicit target point, or to the center reticle when no prompt exists. This
/// prevents a visually merged but depth-separated neighbor from contributing
/// either outline pixels or measurement points.
struct PhotoReticleDepthMaskFilter: Sendable {
    private struct SurfaceComponent {
        let indices: [Int]
    }

    var segmenter = DepthRegionSegmenter()
    var minimumBroadSeamCoverage: Float = 0.6
    var maximumBroadSeamDepthJumpMeters: Float = 0.3

    func filter(
        mask: PhotoDepthSelectionMask,
        depthGrid: DepthGrid,
        normalizedImagePoint: SIMD2<Float>? = nil
    ) throws -> PhotoDepthSelectionMask {
        guard mask.width == depthGrid.width,
              mask.height == depthGrid.height else {
            throw PhotoObjectMeasurementError.depthGridResolutionMismatch
        }

        var constrainedGrid = depthGrid
        for index in constrainedGrid.depths.indices {
            let x = index % mask.width
            let y = index / mask.width
            guard mask.contains(x: x, y: y) else {
                constrainedGrid.depths[index] = .nan
                constrainedGrid.confidences[index] = 0
                continue
            }
        }

        let retainedSurface: [Int]?
        if let normalizedImagePoint {
            retainedSurface = targetSurfaceIndices(
                in: constrainedGrid,
                normalizedImagePoint: normalizedImagePoint
            )
        } else {
            retainedSurface = segmenter.segment(constrainedGrid)?.indices
        }
        guard let retainedSurface, !retainedSurface.isEmpty else {
            throw PhotoObjectMeasurementError.noReticleDepthSurface
        }
        var retained = Set(retainedSurface)
        var remaining = depthComponents(
            in: constrainedGrid,
            excluding: retained
        )

        // A hard box edge may split two legitimate faces even though the second
        // face belongs to the same foreground instance. Rejoin only components
        // that meet the retained surface across most of its width or height.
        // A shoe or other nearby object joined by a narrow visual bridge stays out.
        var didMerge = true
        while didMerge {
            didMerge = false
            for index in remaining.indices.reversed() where shouldMerge(
                remaining[index],
                into: retained,
                grid: constrainedGrid
            ) {
                retained.formUnion(remaining.remove(at: index).indices)
                didMerge = true
            }
        }

        var filteredSelection = Array(repeating: false, count: mask.width * mask.height)
        for index in retained {
            filteredSelection[index] = true
        }
        return try PhotoDepthSelectionMask(
            width: mask.width,
            height: mask.height,
            selected: filteredSelection
        )
    }

    private func targetSurfaceIndices(
        in grid: DepthGrid,
        normalizedImagePoint: SIMD2<Float>
    ) -> [Int]? {
        let targetX = min(
            grid.width - 1,
            Int(normalizedImagePoint.x * Float(grid.width))
        )
        let targetY = min(
            grid.height - 1,
            Int(normalizedImagePoint.y * Float(grid.height))
        )

        var seed: Int?
        for radius in 0...segmenter.seedSearchRadius {
            var candidates: [(index: Int, distanceSquared: Int, depth: Float)] = []
            let minX = max(0, targetX - radius)
            let maxX = min(grid.width - 1, targetX + radius)
            let minY = max(0, targetY - radius)
            let maxY = min(grid.height - 1, targetY + radius)

            for y in minY...maxY {
                for x in minX...maxX {
                    guard radius == 0 || x == minX || x == maxX || y == minY || y == maxY else {
                        continue
                    }
                    let index = y * grid.width + x
                    guard isUsable(index, in: grid) else { continue }
                    let deltaX = x - targetX
                    let deltaY = y - targetY
                    candidates.append((
                        index,
                        deltaX * deltaX + deltaY * deltaY,
                        grid.depths[index]
                    ))
                }
            }

            if let best = candidates.min(by: {
                if $0.distanceSquared == $1.distanceSquared { return $0.depth < $1.depth }
                return $0.distanceSquared < $1.distanceSquared
            }) {
                seed = best.index
                break
            }
        }
        guard let seed else { return nil }

        let seedDepth = grid.depths[seed]
        let maximumSeedDelta = max(
            segmenter.maximumSeedDeltaMeters,
            seedDepth * segmenter.maximumSeedDeltaFraction
        )
        var visited = Array(repeating: false, count: grid.depths.count)
        visited[seed] = true
        var accepted = [seed]
        var readIndex = 0
        while readIndex < accepted.count {
            let current = accepted[readIndex]
            readIndex += 1
            let currentDepth = grid.depths[current]
            for neighbor in neighbors(of: current, width: grid.width, height: grid.height) {
                guard !visited[neighbor] else { continue }
                visited[neighbor] = true
                guard isUsable(neighbor, in: grid) else { continue }
                let candidateDepth = grid.depths[neighbor]
                let localLimit = max(
                    segmenter.localJumpMeters,
                    currentDepth * segmenter.localJumpFraction
                )
                guard abs(candidateDepth - seedDepth) <= maximumSeedDelta,
                      abs(candidateDepth - currentDepth) <= localLimit else {
                    continue
                }
                accepted.append(neighbor)
            }
        }
        return accepted
    }

    private func depthComponents(
        in grid: DepthGrid,
        excluding excluded: Set<Int>
    ) -> [SurfaceComponent] {
        var visited = Array(repeating: false, count: grid.depths.count)
        for index in excluded where visited.indices.contains(index) {
            visited[index] = true
        }
        var components: [SurfaceComponent] = []

        for seed in grid.depths.indices where !visited[seed] && isUsable(seed, in: grid) {
            let seedDepth = grid.depths[seed]
            let maximumSeedDelta = max(
                segmenter.maximumSeedDeltaMeters,
                seedDepth * segmenter.maximumSeedDeltaFraction
            )
            visited[seed] = true
            var indices = [seed]
            var readIndex = 0
            while readIndex < indices.count {
                let current = indices[readIndex]
                readIndex += 1
                let currentDepth = grid.depths[current]
                for neighbor in neighbors(of: current, width: grid.width, height: grid.height) {
                    guard !visited[neighbor], isUsable(neighbor, in: grid) else { continue }
                    let candidateDepth = grid.depths[neighbor]
                    let localLimit = max(
                        segmenter.localJumpMeters,
                        currentDepth * segmenter.localJumpFraction
                    )
                    guard abs(candidateDepth - seedDepth) <= maximumSeedDelta,
                          abs(candidateDepth - currentDepth) <= localLimit else {
                        continue
                    }
                    visited[neighbor] = true
                    indices.append(neighbor)
                }
            }
            components.append(SurfaceComponent(indices: indices))
        }
        return components
    }

    private func shouldMerge(
        _ component: SurfaceComponent,
        into retained: Set<Int>,
        grid: DepthGrid
    ) -> Bool {
        guard !component.indices.isEmpty,
              let retainedBounds = bounds(of: retained, width: grid.width) else {
            return false
        }

        var horizontalSeamRows: Set<Int> = []
        var verticalSeamColumns: Set<Int> = []
        var depthJumps: [Float] = []
        for index in component.indices {
            let x = index % grid.width
            let y = index / grid.width
            for neighbor in neighbors(of: index, width: grid.width, height: grid.height)
                where retained.contains(neighbor) {
                let neighborX = neighbor % grid.width
                if neighborX != x {
                    horizontalSeamRows.insert(y)
                } else {
                    verticalSeamColumns.insert(x)
                }
                depthJumps.append(abs(grid.depths[index] - grid.depths[neighbor]))
            }
        }
        guard !depthJumps.isEmpty else { return false }

        let horizontalCoverage = Float(horizontalSeamRows.count)
            / Float(max(1, retainedBounds.height))
        let verticalCoverage = Float(verticalSeamColumns.count)
            / Float(max(1, retainedBounds.width))
        let sortedJumps = depthJumps.sorted()
        let medianJump = sortedJumps[sortedJumps.count / 2]
        return max(horizontalCoverage, verticalCoverage) >= minimumBroadSeamCoverage
            && medianJump <= maximumBroadSeamDepthJumpMeters
    }

    private func bounds(
        of indices: Set<Int>,
        width: Int
    ) -> (width: Int, height: Int)? {
        guard !indices.isEmpty else { return nil }
        let xs = indices.map { $0 % width }
        let ys = indices.map { $0 / width }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else {
            return nil
        }
        return (maxX - minX + 1, maxY - minY + 1)
    }

    private func isUsable(_ index: Int, in grid: DepthGrid) -> Bool {
        let depth = grid.depths[index]
        return depth.isFinite
            && depth >= segmenter.minimumDepthMeters
            && depth <= segmenter.maximumDepthMeters
            && grid.confidences[index] >= segmenter.minimumConfidence
    }

    private func neighbors(of index: Int, width: Int, height: Int) -> [Int] {
        let x = index % width
        let y = index / width
        var result: [Int] = []
        result.reserveCapacity(4)
        if x > 0 { result.append(index - 1) }
        if x + 1 < width { result.append(index + 1) }
        if y > 0 { result.append(index - width) }
        if y + 1 < height { result.append(index + width) }
        return result
    }
}

struct PhotoObjectMeasurementPolicy: Equatable, Sendable {
    var minimumMaskAreaFraction: Float = 0.03
    var maximumMaskAreaFraction: Float = 0.85
    var protectedEdgeMarginPixels: Int = 1
    var minimumDepthConfidence: UInt8 = 1
    var minimumDepthMeters: Float = 0.15
    var maximumDepthMeters: Float = 6
    var minimumDepthSamples: Int = 48
    var minimumDepthCoverage: Float = 0.6
    var minimumHorizontalDepthSupport: Float = 0.85
    var minimumVerticalDepthSupport: Float = 0.85
    /// Fraction of each end of the appearance-mask bounds that must contain
    /// meaningful depth. An extent check alone can be defeated by one isolated
    /// depth pixel at either edge while the actual object endpoint is missing.
    var depthEndpointBandFraction: Float = 0.15
    var minimumDepthEndpointCoverage: Float = 0.5

    init(
        minimumMaskAreaFraction: Float = 0.03,
        maximumMaskAreaFraction: Float = 0.85,
        protectedEdgeMarginPixels: Int = 1,
        minimumDepthConfidence: UInt8 = 1,
        minimumDepthMeters: Float = 0.15,
        maximumDepthMeters: Float = 6,
        minimumDepthSamples: Int = 48,
        minimumDepthCoverage: Float = 0.6,
        minimumHorizontalDepthSupport: Float = 0.85,
        minimumVerticalDepthSupport: Float = 0.85,
        depthEndpointBandFraction: Float = 0.15,
        minimumDepthEndpointCoverage: Float = 0.5
    ) {
        self.minimumMaskAreaFraction = minimumMaskAreaFraction
        self.maximumMaskAreaFraction = maximumMaskAreaFraction
        self.protectedEdgeMarginPixels = protectedEdgeMarginPixels
        self.minimumDepthConfidence = minimumDepthConfidence
        self.minimumDepthMeters = minimumDepthMeters
        self.maximumDepthMeters = maximumDepthMeters
        self.minimumDepthSamples = minimumDepthSamples
        self.minimumDepthCoverage = minimumDepthCoverage
        self.minimumHorizontalDepthSupport = minimumHorizontalDepthSupport
        self.minimumVerticalDepthSupport = minimumVerticalDepthSupport
        self.depthEndpointBandFraction = depthEndpointBandFraction
        self.minimumDepthEndpointCoverage = minimumDepthEndpointCoverage
    }

    func validate() throws {
        guard minimumMaskAreaFraction.isFinite,
              maximumMaskAreaFraction.isFinite,
              minimumMaskAreaFraction >= 0,
              minimumMaskAreaFraction < maximumMaskAreaFraction,
              maximumMaskAreaFraction <= 1,
              protectedEdgeMarginPixels >= 0,
              minimumDepthMeters.isFinite,
              maximumDepthMeters.isFinite,
              minimumDepthMeters > 0,
              minimumDepthMeters < maximumDepthMeters,
              minimumDepthSamples > 0,
              isUnitFraction(minimumDepthCoverage),
              isUnitFraction(minimumHorizontalDepthSupport),
              isUnitFraction(minimumVerticalDepthSupport),
              depthEndpointBandFraction.isFinite,
              depthEndpointBandFraction > 0,
              depthEndpointBandFraction <= 0.5,
              isUnitFraction(minimumDepthEndpointCoverage) else {
            throw PhotoObjectMeasurementError.invalidPolicy
        }
    }

    private func isUnitFraction(_ value: Float) -> Bool {
        value.isFinite && value >= 0 && value <= 1
    }
}

struct PhotoDepthSupport: Equatable, Sendable {
    let indices: [Int]
    let selectedMaskSampleCount: Int
    let supportedSampleCount: Int
    let coverage: Float
    let horizontalSupport: Float
    let verticalSupport: Float
    let horizontalEndpointCoverage: Float
    let verticalEndpointCoverage: Float
}

struct PhotoDepthSupportAnalyzer: Sendable {
    var policy = PhotoObjectMeasurementPolicy()

    func analyze(
        mask: PhotoDepthSelectionMask,
        constrainedTo constraintMask: PhotoDepthSelectionMask? = nil,
        depthGrid: DepthGrid
    ) throws
        -> PhotoDepthSupport {
        try policy.validate()
        let constraintMask = constraintMask ?? mask
        guard mask.width == depthGrid.width,
              mask.height == depthGrid.height,
              constraintMask.width == depthGrid.width,
              constraintMask.height == depthGrid.height else {
            throw PhotoObjectMeasurementError.depthGridResolutionMismatch
        }

        var maskIndices: [Int] = []
        var supportedIndices: [Int] = []
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.contains(x: x, y: y) {
                let index = y * mask.width + x
                maskIndices.append(index)
                guard constraintMask.contains(x: x, y: y) else { continue }
                let depth = depthGrid.depths[index]
                if depth.isFinite,
                   depth >= policy.minimumDepthMeters,
                   depth <= policy.maximumDepthMeters,
                   depthGrid.confidences[index] >= policy.minimumDepthConfidence {
                    supportedIndices.append(index)
                }
            }
        }

        guard supportedIndices.count >= policy.minimumDepthSamples else {
            throw PhotoObjectMeasurementError.insufficientDepthSamples(
                actual: supportedIndices.count,
                minimum: policy.minimumDepthSamples
            )
        }

        let coverage = Float(supportedIndices.count) / Float(max(1, maskIndices.count))
        guard coverage >= policy.minimumDepthCoverage else {
            throw PhotoObjectMeasurementError.insufficientDepthCoverage(
                actual: coverage,
                minimum: policy.minimumDepthCoverage
            )
        }

        let maskBounds = bounds(for: maskIndices, width: mask.width)
        let supportBounds = bounds(for: supportedIndices, width: mask.width)
        let horizontalSupport = Float(supportBounds.width) / Float(maskBounds.width)
        let verticalSupport = Float(supportBounds.height) / Float(maskBounds.height)
        guard horizontalSupport >= policy.minimumHorizontalDepthSupport else {
            throw PhotoObjectMeasurementError.insufficientHorizontalDepthSupport(
                actual: horizontalSupport,
                minimum: policy.minimumHorizontalDepthSupport
            )
        }
        guard verticalSupport >= policy.minimumVerticalDepthSupport else {
            throw PhotoObjectMeasurementError.insufficientVerticalDepthSupport(
                actual: verticalSupport,
                minimum: policy.minimumVerticalDepthSupport
            )
        }

        // Bounding-box span alone is not sufficient completeness evidence: a
        // handful of isolated depth pixels can make the span appear complete
        // even when the surface near an endpoint is almost entirely absent.
        // Require dense support in bands at both ends of both image axes so a
        // single photo cannot silently shorten the measured object.
        let supportedIndexSet = Set(supportedIndices)
        let horizontalEndpointCoverage = endpointCoverage(
            maskIndices: maskIndices,
            supportedIndices: supportedIndexSet,
            gridWidth: mask.width,
            lowerBound: maskBounds.minX,
            upperBound: maskBounds.maxX,
            horizontalAxis: true
        )
        guard horizontalEndpointCoverage >= policy.minimumDepthEndpointCoverage else {
            throw PhotoObjectMeasurementError.insufficientHorizontalDepthEndpointCoverage(
                actual: horizontalEndpointCoverage,
                minimum: policy.minimumDepthEndpointCoverage
            )
        }
        let verticalEndpointCoverage = endpointCoverage(
            maskIndices: maskIndices,
            supportedIndices: supportedIndexSet,
            gridWidth: mask.width,
            lowerBound: maskBounds.minY,
            upperBound: maskBounds.maxY,
            horizontalAxis: false
        )
        guard verticalEndpointCoverage >= policy.minimumDepthEndpointCoverage else {
            throw PhotoObjectMeasurementError.insufficientVerticalDepthEndpointCoverage(
                actual: verticalEndpointCoverage,
                minimum: policy.minimumDepthEndpointCoverage
            )
        }

        return PhotoDepthSupport(
            indices: supportedIndices,
            selectedMaskSampleCount: maskIndices.count,
            supportedSampleCount: supportedIndices.count,
            coverage: coverage,
            horizontalSupport: horizontalSupport,
            verticalSupport: verticalSupport,
            horizontalEndpointCoverage: horizontalEndpointCoverage,
            verticalEndpointCoverage: verticalEndpointCoverage
        )
    }

    private func bounds(for indices: [Int], width: Int) -> (
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int,
        width: Int,
        height: Int
    ) {
        var minX = Int.max
        var minY = Int.max
        var maxX = Int.min
        var maxY = Int.min
        for index in indices {
            let x = index % width
            let y = index / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
        return (minX, minY, maxX, maxY, maxX - minX + 1, maxY - minY + 1)
    }

    private func endpointCoverage(
        maskIndices: [Int],
        supportedIndices: Set<Int>,
        gridWidth: Int,
        lowerBound: Int,
        upperBound: Int,
        horizontalAxis: Bool
    ) -> Float {
        let axisLength = upperBound - lowerBound + 1
        let bandLength = max(
            1,
            Int(ceil(Float(axisLength) * policy.depthEndpointBandFraction))
        )
        let lowerBandEnd = lowerBound + bandLength - 1
        let upperBandStart = upperBound - bandLength + 1
        var lowerMaskCount = 0
        var lowerSupportedCount = 0
        var upperMaskCount = 0
        var upperSupportedCount = 0

        for index in maskIndices {
            let coordinate = horizontalAxis ? index % gridWidth : index / gridWidth
            if coordinate <= lowerBandEnd {
                lowerMaskCount += 1
                if supportedIndices.contains(index) { lowerSupportedCount += 1 }
            }
            if coordinate >= upperBandStart {
                upperMaskCount += 1
                if supportedIndices.contains(index) { upperSupportedCount += 1 }
            }
        }

        let lowerCoverage = Float(lowerSupportedCount) / Float(max(1, lowerMaskCount))
        let upperCoverage = Float(upperSupportedCount) / Float(max(1, upperMaskCount))
        return min(lowerCoverage, upperCoverage)
    }
}

struct PhotoCameraCalibration: Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
}

struct PhotoWorldPointProjector: Sendable {
    func project(
        support: PhotoDepthSupport,
        depthGrid: DepthGrid,
        calibration: PhotoCameraCalibration
    ) throws -> [SIMD3<Float>] {
        guard calibration.imageWidth > 0,
              calibration.imageHeight > 0,
              depthGrid.width > 0,
              depthGrid.height > 0,
              isFinite(calibration.intrinsics),
              isFinite(calibration.cameraTransform) else {
            throw PhotoObjectMeasurementError.invalidCameraCalibration
        }

        let scaleX = Float(depthGrid.width) / Float(calibration.imageWidth)
        let scaleY = Float(depthGrid.height) / Float(calibration.imageHeight)
        let focalX = calibration.intrinsics[0][0] * scaleX
        let focalY = calibration.intrinsics[1][1] * scaleY
        let principalX = calibration.intrinsics[2][0] * scaleX
        let principalY = calibration.intrinsics[2][1] * scaleY
        guard focalX.isFinite,
              focalY.isFinite,
              principalX.isFinite,
              principalY.isFinite,
              focalX > .ulpOfOne,
              focalY > .ulpOfOne else {
            throw PhotoObjectMeasurementError.invalidCameraCalibration
        }

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(support.indices.count)
        for index in support.indices {
            guard index >= 0, index < depthGrid.depths.count else {
                throw PhotoObjectMeasurementError.invalidWorldPoint
            }
            let x = index % depthGrid.width
            let y = index / depthGrid.width
            let depth = depthGrid.depths[index]
            let cameraPoint = SIMD4<Float>(
                (Float(x) + 0.5 - principalX) * depth / focalX,
                -((Float(y) + 0.5 - principalY) * depth / focalY),
                -depth,
                1
            )
            let world = calibration.cameraTransform * cameraPoint
            let point = SIMD3<Float>(world.x, world.y, world.z)
            guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
                throw PhotoObjectMeasurementError.invalidWorldPoint
            }
            points.append(point)
        }
        return points
    }

    private func isFinite(_ matrix: simd_float3x3) -> Bool {
        (0..<3).allSatisfy { column in
            (0..<3).allSatisfy { row in matrix[column][row].isFinite }
        }
    }

    private func isFinite(_ matrix: simd_float4x4) -> Bool {
        (0..<4).allSatisfy { column in
            (0..<4).allSatisfy { row in matrix[column][row].isFinite }
        }
    }
}

struct PhotoObjectPointCloud: Sendable {
    let selectedLabel: UInt32
    let worldPoints: [SIMD3<Float>]
    let maskQuality: PhotoMaskQuality
    let depthSupport: PhotoDepthSupport
    let objectOutline: MeasurementObjectOutline?
}

/// Deterministic core for the one-shutter path. Platform adapters only need to
/// supply an instance-label mask plus the aligned depth frame and calibration.
struct PhotoObjectMeasurement: Sendable {
    var policy = PhotoObjectMeasurementPolicy()
    var instanceSelector = PhotoForegroundInstanceSelector()
    var depthMaskFilter = PhotoReticleDepthMaskFilter()
    /// The public scanner is Box-first, so strong stacked-body rejection is on
    /// by default. General-item mode must explicitly inject `nil`; it must not
    /// apply rigid-body change-point assumptions to arbitrary furniture.
    var rigidItemMultiplicityGuard: PhotoRigidItemMultiplicityGuard? = .init()

    func makePointCloud(
        labelMask: PhotoInstanceLabelMask,
        depthGrid: DepthGrid,
        calibration: PhotoCameraCalibration,
        prompt: PhotoTargetSelectionPrompt? = nil
    ) throws -> PhotoObjectPointCloud {
        try policy.validate()
        guard hasMatchingAspectRatio(labelMask, calibration) else {
            throw PhotoObjectMeasurementError.maskCalibrationAspectRatioMismatch
        }

        let selected = try instanceSelector.select(in: labelMask, prompt: prompt)
        let quality = selected.quality(edgeMarginPixels: policy.protectedEdgeMarginPixels)
        guard quality.areaFraction >= policy.minimumMaskAreaFraction else {
            throw PhotoObjectMeasurementError.maskAreaTooSmall(
                actual: quality.areaFraction,
                minimum: policy.minimumMaskAreaFraction
            )
        }
        guard quality.areaFraction <= policy.maximumMaskAreaFraction else {
            throw PhotoObjectMeasurementError.maskAreaTooLarge(
                actual: quality.areaFraction,
                maximum: policy.maximumMaskAreaFraction
            )
        }
        guard !quality.touchesProtectedEdge else {
            throw PhotoObjectMeasurementError.maskTouchesImageEdge
        }

        let candidateDepthMask = try selected.resampled(
            toWidth: depthGrid.width,
            height: depthGrid.height
        )
        var configuredDepthMaskFilter = depthMaskFilter
        configuredDepthMaskFilter.segmenter.minimumConfidence = policy.minimumDepthConfidence
        configuredDepthMaskFilter.segmenter.minimumDepthMeters = policy.minimumDepthMeters
        configuredDepthMaskFilter.segmenter.maximumDepthMeters = policy.maximumDepthMeters
        let explicitTargetPoint: SIMD2<Float>?
        if case .target(let normalizedImagePoint) = prompt {
            explicitTargetPoint = normalizedImagePoint
        } else {
            explicitTargetPoint = nil
        }
        let depthMask = try configuredDepthMaskFilter.filter(
            mask: candidateDepthMask,
            depthGrid: depthGrid,
            normalizedImagePoint: explicitTargetPoint
        )
        let support = try PhotoDepthSupportAnalyzer(policy: policy).analyze(
            mask: candidateDepthMask,
            constrainedTo: depthMask,
            depthGrid: depthGrid
        )
        let points = try PhotoWorldPointProjector().project(
            support: support,
            depthGrid: depthGrid,
            calibration: calibration
        )
        if let rigidItemMultiplicityGuard,
           case .multipleRigidItems(let evidence) = rigidItemMultiplicityGuard.assess(
               worldPoints: points
           ) {
            throw PhotoObjectMeasurementError.multipleRigidItemsDetected(evidence)
        }

        return PhotoObjectPointCloud(
            selectedLabel: selected.label,
            worldPoints: points,
            maskQuality: quality,
            depthSupport: support,
            objectOutline: MeasurementObjectOutline(
                width: depthMask.width,
                height: depthMask.height,
                selectedIndices: support.indices
            )
        )
    }

    private func hasMatchingAspectRatio(
        _ mask: PhotoInstanceLabelMask,
        _ calibration: PhotoCameraCalibration
    ) -> Bool {
        guard calibration.imageWidth > 0, calibration.imageHeight > 0 else { return false }
        let maskAspect = Float(mask.width) / Float(mask.height)
        let calibrationAspect = Float(calibration.imageWidth) / Float(calibration.imageHeight)
        let relativeDifference = abs(maskAspect - calibrationAspect)
            / max(maskAspect, calibrationAspect)
        return relativeDifference <= 0.01
    }
}
