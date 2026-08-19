import CoreGraphics
import CoreVideo
import Foundation
import simd

enum ImageMaskDecodingError: Error, Equatable, Sendable {
    case unsupportedPixelFormat(OSType)
}

struct ImageMask: Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        precondition(width > 0 && height > 0)
        precondition(values.count == width * height)
        self.width = width
        self.height = height
        self.values = values
    }

    init(pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        precondition(width > 0 && height > 0)

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            throw ImageMaskDecodingError.unsupportedPixelFormat(format)
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ImageMaskDecodingError.unsupportedPixelFormat(format)
        }

        switch format {
        case kCVPixelFormatType_OneComponent32Float:
            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                / MemoryLayout<Float32>.stride
            let pointer = baseAddress.assumingMemoryBound(to: Float32.self)
            var values = Array(repeating: Float.zero, count: width * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowStride)
                for x in 0..<width {
                    values[y * width + x] = row[x]
                }
            }
            self.init(width: width, height: height, values: values)
        case kCVPixelFormatType_OneComponent8:
            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                / MemoryLayout<UInt8>.stride
            let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
            var values = Array(repeating: Float.zero, count: width * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowStride)
                for x in 0..<width {
                    values[y * width + x] = Float(row[x]) / 255
                }
            }
            self.init(width: width, height: height, values: values)
        case kCVPixelFormatType_OneComponent16Half:
            let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
                / MemoryLayout<UInt16>.stride
            let pointer = baseAddress.assumingMemoryBound(to: UInt16.self)
            var values = Array(repeating: Float.zero, count: width * height)
            for y in 0..<height {
                let row = pointer.advanced(by: y * rowStride)
                for x in 0..<width {
                    values[y * width + x] = Float(Float16(bitPattern: row[x]))
                }
            }
            self.init(width: width, height: height, values: values)
        default:
            throw ImageMaskDecodingError.unsupportedPixelFormat(format)
        }
    }

    func valueAt(x: Int, y: Int) -> Float {
        values[y * width + x]
    }
}

struct MaskedObjectPointCloud: Sendable {
    let points: [SIMD3<Float>]
    let selectedDepthSampleCount: Int
    let coverage: Float
    let touchesImageEdge: Bool
}

struct MaskedDepthPointProjector: Sendable {
    var minimumConfidence: UInt8 = 1
    var minimumMaskValue: Float = 0.5

    func project(
        mask: ImageMask,
        depthGrid: DepthGrid,
        imageResolution: CGSize,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        maximumCount: Int
    ) -> MaskedObjectPointCloud? {
        guard maximumCount > 0, imageResolution.width > 0, imageResolution.height > 0 else {
            return nil
        }

        let totalDepthPixels = depthGrid.width * depthGrid.height

        var selectedIndices: [Int] = []
        selectedIndices.reserveCapacity(totalDepthPixels / 4)
        var touchesImageEdge = false

        for index in 0..<totalDepthPixels {
            let depth = depthGrid.depths[index]
            guard depth.isFinite,
                  depth >= 0.15,
                  depth <= 6,
                  depthGrid.confidences[index] >= minimumConfidence else {
                continue
            }

            let x = index % depthGrid.width
            let y = index / depthGrid.width
            let imageBounds = imageBoundsForDepthPixel(
                x: x,
                y: y,
                maskWidth: mask.width,
                maskHeight: mask.height,
                depthWidth: depthGrid.width,
                depthHeight: depthGrid.height
            )
            guard peakMaskValue(in: imageBounds, mask: mask) >= minimumMaskValue else {
                continue
            }

            selectedIndices.append(index)
            if maskTouchesImageEdge(in: imageBounds, mask: mask) {
                touchesImageEdge = true
            }
        }

        guard !selectedIndices.isEmpty else { return nil }

        let stride = max(1, Int(ceil(Double(selectedIndices.count) / Double(maximumCount))))
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(maximumCount, selectedIndices.count))
        for (offset, index) in selectedIndices.enumerated() {
            guard offset.isMultiple(of: stride) else { continue }
            if let point = worldPoint(
                at: index,
                in: depthGrid,
                intrinsics: intrinsics,
                cameraTransform: cameraTransform
            ) {
                points.append(point)
            }
            if points.count == maximumCount { break }
        }

        guard !points.isEmpty else { return nil }
        return MaskedObjectPointCloud(
            points: points,
            selectedDepthSampleCount: selectedIndices.count,
            coverage: Float(selectedIndices.count) / Float(totalDepthPixels),
            touchesImageEdge: touchesImageEdge
        )
    }

    private func imageBoundsForDepthPixel(
        x: Int,
        y: Int,
        maskWidth: Int,
        maskHeight: Int,
        depthWidth: Int,
        depthHeight: Int
    ) -> CGRect {
        let minX = Int(floor(Double(x * maskWidth) / Double(depthWidth)))
        let maxX = Int(ceil(Double((x + 1) * maskWidth) / Double(depthWidth)))
        let minY = Int(floor(Double(y * maskHeight) / Double(depthHeight)))
        let maxY = Int(ceil(Double((y + 1) * maskHeight) / Double(depthHeight)))

        return CGRect(
            x: max(0, minX),
            y: max(0, minY),
            width: min(maskWidth, maxX) - max(0, minX),
            height: min(maskHeight, maxY) - max(0, minY)
        )
    }

    private func peakMaskValue(in bounds: CGRect, mask: ImageMask) -> Float {
        let minX = Int(bounds.minX)
        let maxX = Int(bounds.maxX)
        let minY = Int(bounds.minY)
        let maxY = Int(bounds.maxY)

        guard minX < maxX, minY < maxY else { return 0 }

        var peak: Float = 0
        for y in minY..<maxY {
            for x in minX..<maxX {
                peak = max(peak, mask.valueAt(x: x, y: y))
            }
        }
        return peak
    }

    private func maskTouchesImageEdge(in bounds: CGRect, mask: ImageMask) -> Bool {
        let minX = Int(bounds.minX)
        let maxX = Int(bounds.maxX)
        let minY = Int(bounds.minY)
        let maxY = Int(bounds.maxY)

        guard minX < maxX, minY < maxY else { return false }

        for y in minY..<maxY {
            for x in minX..<maxX {
                guard mask.valueAt(x: x, y: y) >= minimumMaskValue else { continue }
                if x == 0 || y == 0 || x == mask.width - 1 || y == mask.height - 1 {
                    return true
                }
            }
        }
        return false
    }

    private func worldPoint(
        at index: Int,
        in grid: DepthGrid,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4
    ) -> SIMD3<Float>? {
        let x = index % grid.width
        let y = index / grid.width
        let depth = grid.depths[index]
        let cameraPoint = SIMD3<Float>(
            (Float(x) - intrinsics[2][0]) * depth / intrinsics[0][0],
            -((Float(y) - intrinsics[2][1]) * depth / intrinsics[1][1]),
            -depth
        )
        let world = cameraTransform * SIMD4<Float>(cameraPoint.x, cameraPoint.y, cameraPoint.z, 1)
        let point = SIMD3<Float>(world.x, world.y, world.z)
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { return nil }
        return point
    }
}

enum SingleShotObjectMeasurement {
    static func validation(
        for pointCloud: MaskedObjectPointCloud,
        minimumProjectedPointCount: Int = 48,
        maximumCoverage: Float = 0.94
    ) -> CenteredTargetValidation {
        guard pointCloud.selectedDepthSampleCount >= minimumProjectedPointCount,
              pointCloud.coverage <= maximumCoverage,
              !pointCloud.touchesImageEdge else {
            return .rejected(.insufficientSurfaceEvidence)
        }
        return .valid
    }

    static func outcome(
        mask: ImageMask,
        depthGrid: DepthGrid,
        imageResolution: CGSize,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4
    ) -> MeasurementEstimationOutcome {
        guard let pointCloud = MaskedDepthPointProjector(
            minimumConfidence: 1,
            minimumMaskValue: 0.5
        ).project(
            mask: mask,
            depthGrid: depthGrid,
            imageResolution: imageResolution,
            intrinsics: intrinsics,
            cameraTransform: cameraTransform,
            maximumCount: 42_000
        ) else {
            return .failure(.targetRejected(.insufficientSurfaceEvidence))
        }

        return MeasurementEstimator.outcome(
            from: pointCloud.points,
            frameCount: 1,
            targetValidation: validation(for: pointCloud)
        )
    }
}
