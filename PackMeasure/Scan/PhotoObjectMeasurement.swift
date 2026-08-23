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
    case invalidCameraCalibration
    case invalidWorldPoint
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

    var isRenderable: Bool {
        displayOrientedImageSize.x.isFinite
            && displayOrientedImageSize.y.isFinite
            && displayOrientedImageSize.x > 0
            && displayOrientedImageSize.y > 0
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

    func select(in mask: PhotoInstanceLabelMask) throws -> PhotoSelectedInstanceMask {
        let centerLabel = mask.labelAt(x: mask.width / 2, y: mask.height / 2)
        let foregroundLabels = Set(mask.labels.filter { $0 != backgroundLabel }).sorted()

        let selectedLabel: UInt32
        if centerLabel != backgroundLabel {
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
        let selectedComponent = componentNearestImageCenter(
            in: matchingSelection,
            width: mask.width,
            height: mask.height
        )
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
/// center reticle. This prevents a visually merged but depth-separated neighbor
/// from contributing either outline pixels or measurement points.
struct PhotoReticleDepthMaskFilter: Sendable {
    private struct SurfaceComponent {
        let indices: [Int]
    }

    var segmenter = DepthRegionSegmenter()
    var minimumBroadSeamCoverage: Float = 0.6
    var maximumBroadSeamDepthJumpMeters: Float = 0.3

    func filter(
        mask: PhotoDepthSelectionMask,
        depthGrid: DepthGrid
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

        guard let region = segmenter.segment(constrainedGrid) else {
            throw PhotoObjectMeasurementError.noReticleDepthSurface
        }
        var retained = Set(region.indices)
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
    var minimumHorizontalDepthSupport: Float = 0.65
    var minimumVerticalDepthSupport: Float = 0.65

    init(
        minimumMaskAreaFraction: Float = 0.03,
        maximumMaskAreaFraction: Float = 0.85,
        protectedEdgeMarginPixels: Int = 1,
        minimumDepthConfidence: UInt8 = 1,
        minimumDepthMeters: Float = 0.15,
        maximumDepthMeters: Float = 6,
        minimumDepthSamples: Int = 48,
        minimumDepthCoverage: Float = 0.6,
        minimumHorizontalDepthSupport: Float = 0.65,
        minimumVerticalDepthSupport: Float = 0.65
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
              isUnitFraction(minimumVerticalDepthSupport) else {
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

        return PhotoDepthSupport(
            indices: supportedIndices,
            selectedMaskSampleCount: maskIndices.count,
            supportedSampleCount: supportedIndices.count,
            coverage: coverage,
            horizontalSupport: horizontalSupport,
            verticalSupport: verticalSupport
        )
    }

    private func bounds(for indices: [Int], width: Int) -> (width: Int, height: Int) {
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
        return (maxX - minX + 1, maxY - minY + 1)
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

    func makePointCloud(
        labelMask: PhotoInstanceLabelMask,
        depthGrid: DepthGrid,
        calibration: PhotoCameraCalibration
    ) throws -> PhotoObjectPointCloud {
        try policy.validate()
        guard hasMatchingAspectRatio(labelMask, calibration) else {
            throw PhotoObjectMeasurementError.maskCalibrationAspectRatioMismatch
        }

        let selected = try instanceSelector.select(in: labelMask)
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
        let depthMask = try configuredDepthMaskFilter.filter(
            mask: candidateDepthMask,
            depthGrid: depthGrid
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
