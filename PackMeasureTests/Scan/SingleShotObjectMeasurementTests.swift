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
    func decodesVisionStyleFloatInstanceLabels() throws {
        let pixelBuffer = try floatLabelMaskPixelBuffer(
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
    func diagnosticPreservesExactDepthCoverageFailure() {
        let error = PhotoObjectMeasurementError.insufficientDepthCoverage(
            actual: 0.42,
            minimum: 0.60
        )
        let failure = SingleShotCaptureFailure.photo(error)

        #expect(
            failure
                == .photo(.insufficientDepthCoverage(actual: 0.42, minimum: 0.60))
        )
        #expect(failure.retryCategory == .depth)
        #expect(failure.diagnosticCode == "D02")
        #expect(
            failure.diagnosticDescription
                == "insufficient_depth_coverage,actual=0.420000,minimum=0.600000"
        )
    }

    @Test
    func everyPhotoMeasurementErrorHasAStableDiagnosticCategoryAndCode() {
        let cases: [(PhotoObjectMeasurementError, ScannerPhotoRetryCategory, String)] = [
            (.noForegroundInstance, .isolation, "F01"),
            (.ambiguousForegroundInstances(labels: [1, 2]), .isolation, "F02"),
            (.maskAreaTooSmall(actual: 0.01, minimum: 0.03), .isolation, "F03"),
            (.maskAreaTooLarge(actual: 0.9, maximum: 0.85), .framing, "F04"),
            (.maskTouchesImageEdge, .framing, "F05"),
            (.noReticleDepthSurface, .isolation, "F06"),
            (.insufficientDepthSamples(actual: 31, minimum: 48), .depth, "D01"),
            (.insufficientDepthCoverage(actual: 0.42, minimum: 0.6), .depth, "D02"),
            (.insufficientHorizontalDepthSupport(actual: 0.51, minimum: 0.65), .depth, "D03"),
            (.insufficientVerticalDepthSupport(actual: 0.49, minimum: 0.65), .depth, "D04"),
            (.invalidLabelMaskDimensions, .processing, "P01"),
            (.invalidDepthMaskDimensions, .processing, "P02"),
            (.invalidPolicy, .processing, "P03"),
            (.unsupportedLabelMaskPixelFormat(0), .processing, "P04"),
            (.invalidLabelMaskPixelValue, .processing, "P05"),
            (.maskCalibrationAspectRatioMismatch, .processing, "P06"),
            (.depthGridResolutionMismatch, .processing, "P07"),
            (.invalidCameraCalibration, .processing, "P08"),
            (.invalidWorldPoint, .processing, "P09"),
        ]

        for (error, category, code) in cases {
            #expect(error.retryCategory == category)
            #expect(error.diagnosticCode == code)
            #expect(!error.diagnosticDescription.isEmpty)
        }
    }

    @Test
    func adapterFailuresRetainTheirExactStageAndSystemError() {
        let requestFailure = SingleShotCaptureFailure.foreground(
            .requestFailed(domain: "VisionErrorDomain", code: 17)
        )
        let noObservation = SingleShotCaptureFailure.foreground(.noObservation)

        #expect(requestFailure.retryCategory == .processing)
        #expect(requestFailure.diagnosticCode == "V01")
        #expect(
            requestFailure.diagnosticDescription
                == "vision_request_failed,domain=VisionErrorDomain,code=17"
        )
        #expect(noObservation.retryCategory == .isolation)
        #expect(noObservation.diagnosticCode == "V02")
        #expect(noObservation.disposition == .targetRejected)
        #expect(requestFailure.disposition == .unavailable)
    }

    @Test
    func foregroundMaskDecodeDiagnosticsDistinguishSourceStage() {
        let lowResolution = SingleShotCaptureFailure.foreground(
            .photo(stage: .lowResolutionDecode, error: .invalidLabelMaskDimensions)
        )
        let scaled = SingleShotCaptureFailure.foreground(
            .photo(stage: .scaledMaskDecode, error: .invalidLabelMaskDimensions)
        )

        #expect(lowResolution != scaled)
        #expect(lowResolution.diagnosticDescription.contains("stage=low_resolution_decode"))
        #expect(scaled.diagnosticDescription.contains("stage=scaled_mask_decode"))
        #expect(lowResolution.disposition == .unavailable)
        #expect(scaled.disposition == .unavailable)
    }

    @Test
    func onlyExactNoForegroundFailuresAllowReticleDepthFallback() {
        let eligible: [SingleShotCaptureFailure] = [
            .foreground(
                .photo(stage: .instanceSelection, error: .noForegroundInstance)
            ),
            .photo(.noForegroundInstance),
        ]
        let ineligible: [SingleShotCaptureFailure] = [
            .sceneDepthUnavailable,
            .depthGridUnreadable,
            .unexpectedProcessingFailure(domain: "PackMeasure", code: 1),
            .foreground(.requestFailed(domain: "Vision", code: 2)),
            .foreground(.noObservation),
            .foreground(.observationBridgeFailed),
            .foreground(.scaledMaskFailed(domain: "Vision", code: 3)),
            .foreground(
                .maskProcessingFailed(
                    stage: "instance_selection",
                    domain: "PackMeasure",
                    code: 4
                )
            ),
            .foreground(
                .photo(stage: .lowResolutionDecode, error: .noForegroundInstance)
            ),
            .foreground(
                .photo(stage: .scaledMaskDecode, error: .noForegroundInstance)
            ),
            .foreground(
                .photo(
                    stage: .instanceSelection,
                    error: .ambiguousForegroundInstances(labels: [1, 2])
                )
            ),
            .photo(.ambiguousForegroundInstances(labels: [1, 2])),
            .photo(.maskAreaTooSmall(actual: 0.01, minimum: 0.03)),
            .photo(.maskAreaTooLarge(actual: 0.90, maximum: 0.85)),
            .photo(.maskTouchesImageEdge),
            .photo(.noReticleDepthSurface),
            .photo(.insufficientDepthSamples(actual: 24, minimum: 48)),
            .photo(.insufficientDepthCoverage(actual: 0.40, minimum: 0.60)),
            .photo(.insufficientHorizontalDepthSupport(actual: 0.50, minimum: 0.65)),
            .photo(.insufficientVerticalDepthSupport(actual: 0.50, minimum: 0.65)),
            .photo(.invalidLabelMaskDimensions),
        ]

        #expect(eligible.allSatisfy { $0.shouldAttemptReticleDepthFallback })
        #expect(ineligible.allSatisfy { !$0.shouldAttemptReticleDepthFallback })
    }

    @Test
    func capturePathAndFallbackResultHaveStableDiagnosticValues() {
        #expect(SingleShotCapturePath.visionMask.rawValue == "vision_mask")
        #expect(
            SingleShotCapturePath.reticleDepthFallback.rawValue
                == "reticle_depth_fallback"
        )

        let cases: [(SingleShotFallbackResult, String)] = [
            (.notAttempted, "not_attempted"),
            (.accepted, "accepted"),
            (.targetRejected(.floorSurface), "target_rejected,reason=floor_surface"),
            (
                .targetRejected(.insufficientSurfaceEvidence),
                "target_rejected,reason=insufficient_surface_evidence"
            ),
            (.unavailable, "unavailable"),
        ]

        for (result, description) in cases {
            #expect(result.diagnosticDescription == description)
        }
    }

    @Test
    func singleShotOutcomeEstimatesBoxFromOnePhoto() throws {
        let outcome = SingleShotObjectMeasurement.outcome(
            labelMask: try labelMask(
                [
                    [0, 0, 0, 0, 0, 0, 0, 0],
                    [0, 5, 5, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 5, 5, 0],
                    [0, 5, 5, 5, 5, 5, 5, 0],
                    [0, 0, 0, 0, 0, 0, 0, 0],
                ]
            ),
            depthGrid: populatedBoxDepthGrid(width: 8, height: 8),
            calibration: calibration(imageWidth: 8, imageHeight: 8),
            policy: testPolicy
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

    private var testPolicy: PhotoObjectMeasurementPolicy {
        PhotoObjectMeasurementPolicy(
            minimumMaskAreaFraction: 0.01,
            maximumMaskAreaFraction: 0.95,
            protectedEdgeMarginPixels: 0,
            minimumDepthSamples: 8,
            minimumDepthCoverage: 0.5,
            minimumHorizontalDepthSupport: 0.6,
            minimumVerticalDepthSupport: 0.6
        )
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

    private func populatedBoxDepthGrid(width: Int, height: Int) -> DepthGrid {
        var depths = Array(repeating: Float(1.25), count: width * height)
        for y in 0..<height {
            for x in 0..<width where x >= width / 2 {
                depths[y * width + x] = 1.45
            }
        }
        return DepthGrid(
            width: width,
            height: height,
            depths: depths,
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

    private func floatLabelMaskPixelBuffer(
        width: Int,
        height: Int,
        labels: [Float32]
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_OneComponent32Float,
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
        let rowStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            / MemoryLayout<Float32>.stride
        let pointer = baseAddress.assumingMemoryBound(to: Float32.self)
        for y in 0..<height {
            let row = pointer.advanced(by: y * rowStride)
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
