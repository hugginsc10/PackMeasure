import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Measurement AR exact-frame adapters")
struct MeasurementARFrameIntegrationTests {
    @Test @MainActor
    func captureStartAbortClearsOnlyThePendingAutomaticAuthority() throws {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        _ = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.5, 0.5)
            )
        )
        state.startMeasurement()
        let authority = try #require(state.pendingAutomaticCaptureAuthority)

        #expect(
            ScannerAutomaticCaptureAuthorityTerminator().terminatePending(
                in: state
            )
        )
        #expect(state.pendingAutomaticCaptureAuthority == nil)
        #expect(state.phase == .ready)
        #expect(!state.automaticCaptureFailed(authority: authority))
    }

    @Test
    func immutablePromptDrivesBothForegroundSelectionAndPointCloud() throws {
        let width = 12
        let height = 12
        var labels = Array(repeating: UInt32.zero, count: width * height)
        for y in 3...8 {
            for x in 1...4 { labels[y * width + x] = 7 }
            for x in 6...9 { labels[y * width + x] = 5 }
        }
        let mask = try PhotoInstanceLabelMask(
            width: width,
            height: height,
            labels: labels
        )
        var measurement = PhotoObjectMeasurement(policy: permissivePolicy)
        measurement.rigidItemMultiplicityGuard = nil
        let processor = ScannerAutomaticPhotoFrameProcessor(
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.25, 0.5)),
            measurement: measurement
        )

        let lowResolutionSelection = try processor.selectForeground(in: mask)
        let pointCloud = try processor.makePointCloud(
            labelMask: mask,
            depthGrid: populatedDepthGrid(width: width, height: height),
            calibration: calibration(width: width, height: height)
        )

        #expect(lowResolutionSelection.label == 7)
        #expect(pointCloud.selectedLabel == 7)
        #expect(pointCloud.maskQuality.selectedPixelCount == 24)
    }

    @Test
    func staleExplicitPromptFailsBeforeEitherStageCanUseCenter() throws {
        let mask = try PhotoInstanceLabelMask(
            width: 3,
            height: 3,
            labels: [
                0, 0, 0,
                0, 9, 0,
                0, 0, 0,
            ]
        )
        let processor = ScannerAutomaticPhotoFrameProcessor(
            prompt: .stale,
            measurement: PhotoObjectMeasurement()
        )

        #expect(throws: PhotoTargetSelectionError.staleTargetSelectionPrompt) {
            try processor.selectForeground(in: mask)
        }
    }

    @Test
    func explicitProcessorPreservesSettledMaskEdgeMargin() throws {
        let width = 12
        let height = 12
        var labels = Array(repeating: UInt32.zero, count: width * height)
        for y in 3...8 {
            for x in 1...4 { labels[y * width + x] = 7 }
        }
        var measurement = PhotoObjectMeasurement(policy: permissivePolicy)
        measurement.rigidItemMultiplicityGuard = nil
        let processor = ScannerAutomaticPhotoFrameProcessor(
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.25, 0.5)),
            measurement: measurement
        )

        #expect(
            throws: PhotoObjectMeasurementError.maskTouchesImageEdge(stage: .sourceMask)
        ) {
            try processor.makePointCloud(
                labelMask: PhotoInstanceLabelMask(
                    width: width,
                    height: height,
                    labels: labels
                ),
                depthGrid: populatedDepthGrid(width: width, height: height),
                calibration: calibration(width: width, height: height),
                protectedEdgeMarginPixels: 1
            )
        }
    }

    @Test
    func explicitTargetNeverFallsBackToLegacyCenterDepth() {
        let otherwiseEligibleFailure = SingleShotCaptureFailure.foreground(
            .photo(stage: .instanceSelection, error: .noForegroundInstance)
        )
        let policy = ScannerSingleShotFrameRoutePolicy()

        #expect(otherwiseEligibleFailure.shouldAttemptReticleDepthFallback)
        #expect(
            !policy.shouldAttemptReticleDepthFallback(
                after: otherwiseEligibleFailure,
                hasExplicitTarget: true
            )
        )
        #expect(
            policy.shouldAttemptReticleDepthFallback(
                after: otherwiseEligibleFailure,
                hasExplicitTarget: false
            )
        )
    }

    @Test
    func depthSamplerUsesRequestedRawPixelAndMediumConfidence() throws {
        var depths = Array(repeating: Float(1), count: 16)
        var confidences = Array(repeating: UInt8.zero, count: 16)
        depths[11] = 2
        confidences[11] = 1
        let grid = DepthGrid(
            width: 4,
            height: 4,
            depths: depths,
            confidences: confidences
        )
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = 4
        intrinsics[1][1] = 4
        intrinsics[2][0] = 4
        intrinsics[2][1] = 4
        var cameraTransform = matrix_identity_float4x4
        cameraTransform.columns.3 = SIMD4<Float>(1, 2, 3, 1)

        let sample = try #require(
            ScannerFrameDepthSampler().sample(
                normalizedImagePoint: SIMD2<Float>(0.8, 0.6),
                grid: grid,
                cameraImageResolutionPixels: SIMD2<Int>(8, 8),
                cameraIntrinsics: intrinsics,
                cameraTransform: cameraTransform
            )
        )

        #expect(sample.depthGridPixel == SIMD2<Int>(3, 2))
        #expect(sample.confidence == .medium)
        #expect(distance(sample.worldPosition, SIMD3<Float>(2, 2, 1)) < 0.000_1)
    }

    @Test
    func targetEvidenceUsesProjectedPreviewAndExactDepthFrame() throws {
        let identity = TargetLockIdentity(
            targetID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            measurementSeriesID: 7
        )
        let grid = DepthGrid(
            width: 3,
            height: 3,
            depths: Array(repeating: 2, count: 9),
            confidences: Array(repeating: 1, count: 9)
        )
        var intrinsics = matrix_identity_float3x3
        intrinsics[2][0] = 1
        intrinsics[2][1] = 1

        let evidence = ScannerTargetFrameEvidenceAdapter().makeEvidence(
            identity: identity,
            projectedPreviewPointPixels: SIMD2<Float>(160, 240),
            viewportSizePixels: SIMD2<Float>(320, 480),
            rawImagePoint: SIMD2<Float>(0.5, 0.5),
            grid: grid,
            cameraImageResolutionPixels: SIMD2<Int>(3, 3),
            cameraIntrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4
        )

        #expect(evidence.identity == identity)
        #expect(evidence.projectedPreviewPoint == SIMD2<Float>(0.5, 0.5))
        #expect(evidence.cameraWorldPosition == .zero)
        #expect(evidence.observedSurface?.confidence == .medium)
        #expect(evidence.observedSurface?.worldPoint == SIMD3<Float>(0, 0, -2))
    }

    @Test
    func zoomEpochResetsLivePassesAndExactFrameAuthority() {
        let identity = TargetLockIdentity(
            targetID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            measurementSeriesID: 4
        )
        var tracker = ScannerTargetFrameAuthorityTracker()
        tracker.synchronize(identity: identity, cameraEvidenceReacquisitionID: 8)

        #expect(
            tracker.observe(
                .valid,
                identity: identity,
                cameraEvidenceReacquisitionID: 8
            ) == .waiting
        )
        #expect(
            tracker.observe(
                .valid,
                identity: identity,
                cameraEvidenceReacquisitionID: 8
            ) == .ready
        )
        #expect(
            tracker.exactFrameValidation(
                .valid,
                identity: identity,
                cameraEvidenceReacquisitionID: 8
            ) == .valid
        )

        tracker.synchronize(identity: identity, cameraEvidenceReacquisitionID: 9)

        #expect(!tracker.isReady)
        #expect(
            tracker.exactFrameValidation(
                .valid,
                identity: identity,
                cameraEvidenceReacquisitionID: 9
            ) == .rejected(.invalidTargetEvidence)
        )
        #expect(
            tracker.observe(
                .valid,
                identity: identity,
                cameraEvidenceReacquisitionID: 8
            ) == .ignoredStaleIdentity
        )

        tracker.synchronize(identity: identity, cameraEvidenceReacquisitionID: 9)
        _ = tracker.observe(
            .valid,
            identity: identity,
            cameraEvidenceReacquisitionID: 9
        )
        _ = tracker.observe(
            .valid,
            identity: identity,
            cameraEvidenceReacquisitionID: 9
        )
        tracker.invalidate()
        #expect(!tracker.isReady)
    }

    @Test
    func exactTargetRejectionUsesHumanReadableCopy() {
        let failure = TargetLockFrameValidationFailure.surfaceOutsideBounds
        let message = ScannerPhotoFailureCopy.message(for: .targetLock(failure))

        #expect(message == failure.actionMessage)
    }

    @Test
    func guidedSamplerCompletesExactRequestWithPoseAndProvenance() throws {
        let requestedPose = GuidedBoxCapturePose(
            position: .zero,
            orientation: SIMD4<Float>(0, 0, 0, 1)
        )
        let request = GuidedBoxCaptureRequest(
            requestID: 3,
            context: GuidedBoxCaptureContext(
                measurementSeriesID: 9,
                targetID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            ),
            point: .widthEndpoint,
            requestedPose: requestedPose
        )
        let grid = DepthGrid(
            width: 3,
            height: 3,
            depths: Array(repeating: 1.5, count: 9),
            confidences: Array(repeating: 2, count: 9)
        )
        var intrinsics = matrix_identity_float3x3
        intrinsics[2][0] = 1
        intrinsics[2][1] = 1

        let result = ScannerGuidedFrameSampler().sample(
            request: request,
            normalizedImagePoint: SIMD2<Float>(0.5, 0.5),
            grid: grid,
            cameraImageResolutionPixels: SIMD2<Int>(3, 3),
            cameraIntrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4,
            gravity: SIMD3<Float>(0, -1, 0)
        )
        let sample = try #require(result.sample)

        #expect(sample.provenance.requestID == request.requestID)
        #expect(sample.provenance.context == request.context)
        #expect(sample.provenance.point == request.point)
        #expect(sample.provenance.source == .guidedLidarCorners)
        #expect(sample.worldPosition == SIMD3<Float>(0, 0, -1.5))
        #expect(sample.capturedPose == requestedPose)
    }

    @Test
    func staleGuidedCompletionCannotConsumeReplacementRequest() {
        let context = GuidedBoxCaptureContext(
            measurementSeriesID: 12,
            targetID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        )
        let pose = GuidedBoxCapturePose(
            position: .zero,
            orientation: SIMD4<Float>(0, 0, 0, 1)
        )
        let first = GuidedBoxCaptureRequest(
            requestID: 1,
            context: context,
            point: .referenceCorner,
            requestedPose: pose
        )
        let replacement = GuidedBoxCaptureRequest(
            requestID: 2,
            context: context,
            point: .referenceCorner,
            requestedPose: pose
        )
        var tracker = ScannerGuidedFrameRequestTracker()
        tracker.synchronize(first)
        tracker.synchronize(replacement)

        let staleWasConsumed = tracker.consumeCompletion(for: first)
        #expect(!staleWasConsumed)
        #expect(tracker.pendingRequest == replacement)
        let replacementWasConsumed = tracker.consumeCompletion(for: replacement)
        #expect(replacementWasConsumed)
        #expect(tracker.pendingRequest == nil)
    }

    @Test
    func guidedSamplingAttemptsTerminateByCountOrDeadline() {
        var attempts = ScannerGuidedFrameAttemptGate(
            startedAt: 10,
            maximumWait: 2.5,
            maximumFailedSamples: 3
        )

        #expect(attempts.recordFailure(at: 10.5) == .retry)
        #expect(attempts.recordFailure(at: 11) == .retry)
        #expect(attempts.recordFailure(at: 11.5) == .terminate)

        var timedOut = ScannerGuidedFrameAttemptGate(
            startedAt: 20,
            maximumWait: 2.5,
            maximumFailedSamples: 3
        )
        #expect(!timedOut.hasExpired(at: 22.49))
        #expect(timedOut.hasExpired(at: 22.5))
        #expect(timedOut.recordFailure(at: 22.5) == .terminate)
    }

    @Test
    func guidedSamplingFailureMapsToTypedStateTermination() {
        #expect(
            ScannerGuidedFrameSamplingFailure.depthUnavailable.captureFailure
                == .depthTimeout
        )
        #expect(
            ScannerGuidedFrameSamplingFailure.insufficientDepthConfidence
                .captureFailure == .depthTimeout
        )
        #expect(
            ScannerGuidedFrameSamplingFailure.invalidCameraPose.captureFailure
                == .trackingTimeout
        )
        #expect(
            ScannerGuidedFrameSamplingFailure.invalidGravity.captureFailure
                == .trackingTimeout
        )
        #expect(
            ScannerGuidedFrameSamplingFailure.projectionUnavailable.captureFailure
                == .trackingTimeout
        )
    }

    private var permissivePolicy: PhotoObjectMeasurementPolicy {
        PhotoObjectMeasurementPolicy(
            minimumMaskAreaFraction: 0.01,
            maximumMaskAreaFraction: 0.95,
            protectedEdgeMarginPixels: 0,
            minimumDepthConfidence: 1,
            minimumDepthSamples: 4,
            minimumDepthCoverage: 0.5,
            minimumHorizontalDepthSupport: 0.6,
            minimumVerticalDepthSupport: 0.6,
            minimumDepthEndpointCoverage: 0
        )
    }

    private func populatedDepthGrid(width: Int, height: Int) -> DepthGrid {
        DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: 1, count: width * height),
            confidences: Array(repeating: 2, count: width * height)
        )
    }

    private func calibration(width: Int, height: Int) -> PhotoCameraCalibration {
        var intrinsics = matrix_identity_float3x3
        intrinsics[0][0] = Float(width)
        intrinsics[1][1] = Float(height)
        intrinsics[2][0] = Float(width) / 2
        intrinsics[2][1] = Float(height) / 2
        return PhotoCameraCalibration(
            imageWidth: width,
            imageHeight: height,
            intrinsics: intrinsics,
            cameraTransform: matrix_identity_float4x4
        )
    }

    private func distance(_ lhs: SIMD3<Float>, _ rhs: SIMD3<Float>) -> Float {
        simd_distance(lhs, rhs)
    }
}
