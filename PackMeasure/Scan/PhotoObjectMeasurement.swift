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

        return PhotoSelectedInstanceMask(
            width: mask.width,
            height: mask.height,
            label: selectedLabel,
            selected: mask.labels.map { $0 == selectedLabel }
        )
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

    func analyze(mask: PhotoDepthSelectionMask, depthGrid: DepthGrid) throws
        -> PhotoDepthSupport {
        try policy.validate()
        guard mask.width == depthGrid.width,
              mask.height == depthGrid.height else {
            throw PhotoObjectMeasurementError.depthGridResolutionMismatch
        }

        var maskIndices: [Int] = []
        var supportedIndices: [Int] = []
        for y in 0..<mask.height {
            for x in 0..<mask.width where mask.contains(x: x, y: y) {
                let index = y * mask.width + x
                maskIndices.append(index)
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
}

/// Deterministic core for the one-shutter path. Platform adapters only need to
/// supply an instance-label mask plus the aligned depth frame and calibration.
struct PhotoObjectMeasurement: Sendable {
    var policy = PhotoObjectMeasurementPolicy()
    var instanceSelector = PhotoForegroundInstanceSelector()

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

        let depthMask = try selected.resampled(
            toWidth: depthGrid.width,
            height: depthGrid.height
        )
        let support = try PhotoDepthSupportAnalyzer(policy: policy).analyze(
            mask: depthMask,
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
            depthSupport: support
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
