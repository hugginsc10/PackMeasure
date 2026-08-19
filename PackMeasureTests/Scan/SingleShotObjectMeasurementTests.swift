import CoreVideo
import Testing
import simd
@testable import PackMeasure

@Suite("Single-shot object measurement")
struct SingleShotObjectMeasurementTests {
    @Test
    func decodesInstanceLabelMaskFromOneComponent8PixelBuffer() throws {
        let pixelBuffer = try labelMaskPixelBuffer(
            width: 4,
            height: 3,
            labels: [
                0, 0, 0, 0,
                0, 5, 5, 0,
                0, 5, 9, 0,
            ]
        )

        let mask = try PhotoInstanceLabelMask(pixelBuffer: pixelBuffer)

        #expect(mask.width == 4)
        #expect(mask.height == 3)
        #expect(mask.labelAt(x: 1, y: 1) == 5)
        #expect(mask.labelAt(x: 2, y: 2) == 9)
    }

    @Test
    func singleShotOutcomeRejectsAmbiguousForegroundWhenCenterIsBackground() throws {
        let outcome = SingleShotObjectMeasurement.outcome(
            labelMask: try labelMask(
                [
                    [1, 1, 0, 2, 2],
                    [1, 1, 0, 2, 2],
                    [0, 0, 0, 0, 0],
                    [0, 0, 0, 0, 0],
                    [0, 0, 0, 0, 0],
                ]
            ),
            depthGrid: DepthGrid(
                width: 5,
                height: 5,
                depths: Array(repeating: 1, count: 25),
                confidences: Array(repeating: 2, count: 25)
            ),
            calibration: calibration(imageWidth: 5, imageHeight: 5)
        )

        #expect(outcome == .failure(.targetRejected(.insufficientSurfaceEvidence)))
    }

    @Test
    func singleShotOutcomeEstimatesBoxFromOnePhoto() throws {
        let outcome = SingleShotObjectMeasurement.outcome(
            labelMask: try labelMask(
                [
                    [0, 0, 0, 0, 0, 0],
                    [0, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 0],
                    [0, 0, 0, 0, 0, 0],
                ]
            ),
            depthGrid: populatedDepthGrid(width: 6, height: 6),
            calibration: calibration(imageWidth: 6, imageHeight: 6)
        )

        guard case .success(let estimate) = outcome else {
            Issue.record("expected one-photo single-shot estimate to succeed")
            return
        }
        #expect(estimate.frameCount == 1)
        #expect(estimate.sampleCount >= 16)
        #expect(estimate.lengthMeters > 0)
        #expect(estimate.widthMeters > 0)
        #expect(estimate.heightMeters > 0)
    }

    private func calibration(imageWidth: Int, imageHeight: Int) -> PhotoCameraCalibration {
        PhotoCameraCalibration(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            intrinsics: intrinsics(),
            cameraTransform: matrix_identity_float4x4
        )
    }

    private func intrinsics() -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(6, 0, 0),
            SIMD3<Float>(0, 6, 0),
            SIMD3<Float>(3, 3, 1)
        )
    }

    private func labelMask(_ rows: [[UInt32]]) throws -> PhotoInstanceLabelMask {
        try PhotoInstanceLabelMask(
            width: rows[0].count,
            height: rows.count,
            labels: rows.flatMap { $0 }
        )
    }

    private func populatedDepthGrid(width: Int, height: Int) -> DepthGrid {
        DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: 1.25, count: width * height),
            confidences: Array(repeating: 2, count: width * height)
        )
    }

    private func labelMaskPixelBuffer(
        width: Int,
        height: Int,
        labels: [UInt8]
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent8,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestSupportError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw TestSupportError.pixelBufferBaseAddressMissing
        }
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x] = labels[y * width + x]
            }
        }
        return pixelBuffer
    }

    private enum TestSupportError: Error {
        case pixelBufferCreationFailed(CVReturn)
        case pixelBufferBaseAddressMissing
    }
}
