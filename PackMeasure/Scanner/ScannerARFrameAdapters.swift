import Foundation
import simd

/// Carries one immutable explicit target prompt through both Vision's
/// low-resolution instance selection and the exact RGB/depth point-cloud pass.
/// Keeping the configured measurement beside the prompt also makes the Box vs.
/// General Item multiplicity policy part of the same settled-frame authority.
struct ScannerAutomaticPhotoFrameProcessor: Sendable {
    let prompt: PhotoTargetSelectionPrompt
    let measurement: PhotoObjectMeasurement

    func selectForeground(
        in mask: PhotoInstanceLabelMask
    ) throws -> PhotoSelectedInstanceMask {
        try measurement.instanceSelector.select(in: mask, prompt: prompt)
    }

    func makePointCloud(
        labelMask: PhotoInstanceLabelMask,
        depthGrid: DepthGrid,
        calibration: PhotoCameraCalibration,
        protectedEdgeMarginPixels: Int? = nil
    ) throws -> PhotoObjectPointCloud {
        var configuredMeasurement = measurement
        if let protectedEdgeMarginPixels {
            configuredMeasurement.policy.protectedEdgeMarginPixels =
                max(0, protectedEdgeMarginPixels)
        }
        return try configuredMeasurement.makePointCloud(
            labelMask: labelMask,
            depthGrid: depthGrid,
            calibration: calibration,
            prompt: prompt
        )
    }
}

/// Production seam between Vision's label-wide scaled mask and the exact
/// connected-component authority selected from its low-resolution mask.
struct ScannerForegroundScaledMaskOwnershipAdapter: Sendable {
    func validate(
        scaledMask: PhotoInstanceLabelMask,
        against selection: PhotoSelectedInstanceMask
    ) throws -> PhotoInstanceLabelMask {
        try selection.validatingOwnership(of: scaledMask)
    }
}

/// Terminates only the state model's exact pending automatic authority when
/// the AR coordinator cannot proceed from the capture-start command.
@MainActor
struct ScannerAutomaticCaptureAuthorityTerminator {
    @discardableResult
    func terminatePending(
        in state: ScannerSheetView.ScannerStateModel
    ) -> Bool {
        guard let authority = state.pendingAutomaticCaptureAuthority else {
            return false
        }
        return state.automaticCaptureFailed(authority: authority)
    }
}

/// Keeps an explicit selection fail-closed. The reticle route has no authority
/// to replace a target chosen by the user or projected from a saved lock.
struct ScannerSingleShotFrameRoutePolicy: Sendable {
    func shouldAttemptReticleDepthFallback(
        after failure: SingleShotCaptureFailure,
        hasExplicitTarget: Bool
    ) -> Bool {
        !hasExplicitTarget && failure.shouldAttemptReticleDepthFallback
    }
}

struct ScannerFrameDepthSample: Equatable, Sendable {
    let depthGridPixel: SIMD2<Int>
    let worldPosition: SIMD3<Float>
    let confidence: TargetLockDepthConfidence
}

/// Pure exact-frame adapter shared by locked-target validation and guided
/// corner capture. The normalized point is in the raw camera-image coordinate
/// space, not the aspect-filled preview space.
struct ScannerFrameDepthSampler: Sendable {
    var minimumDepthMeters: Float = 0.15
    var maximumDepthMeters: Float = 6

    func sample(
        normalizedImagePoint: SIMD2<Float>,
        grid: DepthGrid,
        cameraImageResolutionPixels: SIMD2<Int>,
        cameraIntrinsics: simd_float3x3,
        cameraTransform: simd_float4x4
    ) -> ScannerFrameDepthSample? {
        guard configurationIsValid,
              normalizedImagePoint.x.isFinite,
              normalizedImagePoint.y.isFinite,
              (0...1).contains(normalizedImagePoint.x),
              (0...1).contains(normalizedImagePoint.y),
              cameraImageResolutionPixels.x > 0,
              cameraImageResolutionPixels.y > 0,
              matricesAreFinite(cameraIntrinsics, cameraTransform),
              let scaledIntrinsics = scaledIntrinsics(
                  cameraImageResolutionPixels: cameraImageResolutionPixels,
                  depthGrid: grid,
                  cameraIntrinsics: cameraIntrinsics
              ) else {
            return nil
        }

        let x = min(
            grid.width - 1,
            Int(normalizedImagePoint.x * Float(grid.width))
        )
        let y = min(
            grid.height - 1,
            Int(normalizedImagePoint.y * Float(grid.height))
        )
        guard x >= 0, y >= 0 else { return nil }
        let index = y * grid.width + x
        let depth = grid.depths[index]
        guard depth.isFinite,
              depth >= minimumDepthMeters,
              depth <= maximumDepthMeters else {
            return nil
        }

        let localPoint = SIMD3<Float>(
            (Float(x) - scaledIntrinsics[2][0]) * depth
                / scaledIntrinsics[0][0],
            -(Float(y) - scaledIntrinsics[2][1]) * depth
                / scaledIntrinsics[1][1],
            -depth
        )
        let world = cameraTransform * SIMD4<Float>(
            localPoint.x,
            localPoint.y,
            localPoint.z,
            1
        )
        let worldPosition = SIMD3<Float>(world.x, world.y, world.z)
        guard worldPosition.x.isFinite,
              worldPosition.y.isFinite,
              worldPosition.z.isFinite else {
            return nil
        }

        return ScannerFrameDepthSample(
            depthGridPixel: SIMD2<Int>(x, y),
            worldPosition: worldPosition,
            confidence: confidence(from: grid.confidences[index])
        )
    }

    private var configurationIsValid: Bool {
        minimumDepthMeters.isFinite
            && maximumDepthMeters.isFinite
            && minimumDepthMeters > 0
            && maximumDepthMeters > minimumDepthMeters
    }

    private func scaledIntrinsics(
        cameraImageResolutionPixels: SIMD2<Int>,
        depthGrid: DepthGrid,
        cameraIntrinsics: simd_float3x3
    ) -> simd_float3x3? {
        let scaleX = Float(cameraImageResolutionPixels.x) / Float(depthGrid.width)
        let scaleY = Float(cameraImageResolutionPixels.y) / Float(depthGrid.height)
        guard scaleX.isFinite,
              scaleY.isFinite,
              scaleX > 0,
              scaleY > 0 else {
            return nil
        }

        var intrinsics = cameraIntrinsics
        intrinsics[0][0] /= scaleX
        intrinsics[1][1] /= scaleY
        intrinsics[2][0] /= scaleX
        intrinsics[2][1] /= scaleY
        guard intrinsics[0][0].isFinite,
              intrinsics[1][1].isFinite,
              intrinsics[2][0].isFinite,
              intrinsics[2][1].isFinite,
              intrinsics[0][0] > 0,
              intrinsics[1][1] > 0 else {
            return nil
        }
        return intrinsics
    }

    private func confidence(from rawValue: UInt8) -> TargetLockDepthConfidence {
        if rawValue >= 2 { return .high }
        if rawValue == 1 { return .medium }
        return .low
    }

    private func matricesAreFinite(
        _ intrinsics: simd_float3x3,
        _ transform: simd_float4x4
    ) -> Bool {
        (0..<3).allSatisfy { column in
            (0..<3).allSatisfy { row in intrinsics[column][row].isFinite }
        } && (0..<4).allSatisfy { column in
            (0..<4).allSatisfy { row in transform[column][row].isFinite }
        }
    }
}

struct ScannerTargetFrameEvidenceAdapter: Sendable {
    var depthSampler = ScannerFrameDepthSampler()

    func makeEvidence(
        identity: TargetLockIdentity,
        projectedPreviewPointPixels: SIMD2<Float>?,
        viewportSizePixels: SIMD2<Float>,
        rawImagePoint: SIMD2<Float>?,
        grid: DepthGrid?,
        cameraImageResolutionPixels: SIMD2<Int>,
        cameraIntrinsics: simd_float3x3,
        cameraTransform: simd_float4x4
    ) -> TargetLockFrameEvidence {
        let normalizedPreviewPoint = projectedPreviewPointPixels.flatMap {
            normalizedPreviewPoint(
                projectedPointPixels: $0,
                viewportSizePixels: viewportSizePixels
            )
        }
        let depthSample: ScannerFrameDepthSample? = if let rawImagePoint, let grid {
            depthSampler.sample(
                normalizedImagePoint: rawImagePoint,
                grid: grid,
                cameraImageResolutionPixels: cameraImageResolutionPixels,
                cameraIntrinsics: cameraIntrinsics,
                cameraTransform: cameraTransform
            )
        } else {
            nil
        }
        let cameraPosition = SIMD3<Float>(
            cameraTransform.columns.3.x,
            cameraTransform.columns.3.y,
            cameraTransform.columns.3.z
        )
        let finiteCameraPosition = cameraPosition.x.isFinite
            && cameraPosition.y.isFinite
            && cameraPosition.z.isFinite
            ? cameraPosition
            : nil

        return TargetLockFrameEvidence(
            identity: identity,
            projectedPreviewPoint: normalizedPreviewPoint,
            cameraWorldPosition: finiteCameraPosition,
            observedSurface: depthSample.map {
                TargetLockObservedSurface(
                    worldPoint: $0.worldPosition,
                    confidence: $0.confidence
                )
            }
        )
    }

    private func normalizedPreviewPoint(
        projectedPointPixels: SIMD2<Float>,
        viewportSizePixels: SIMD2<Float>
    ) -> SIMD2<Float>? {
        guard projectedPointPixels.x.isFinite,
              projectedPointPixels.y.isFinite,
              viewportSizePixels.x.isFinite,
              viewportSizePixels.y.isFinite,
              viewportSizePixels.x > 0,
              viewportSizePixels.y > 0 else {
            return nil
        }
        return projectedPointPixels / viewportSizePixels
    }
}

/// Processing-queue mirror of the state model's two-pass gate. The camera
/// evidence epoch is part of its authority, so a zoom change resets readiness
/// even when the selected target identity stays unchanged.
struct ScannerTargetFrameAuthorityTracker: Equatable, Sendable {
    private(set) var identity: TargetLockIdentity?
    private(set) var cameraEvidenceReacquisitionID: Int?
    private var validationGate: TargetLockFrameValidationGate?

    var isReady: Bool { validationGate?.isReady == true }

    mutating func synchronize(
        identity: TargetLockIdentity,
        cameraEvidenceReacquisitionID: Int
    ) {
        guard self.identity != identity
                || self.cameraEvidenceReacquisitionID
                    != cameraEvidenceReacquisitionID else {
            return
        }
        self.identity = identity
        self.cameraEvidenceReacquisitionID = cameraEvidenceReacquisitionID
        validationGate = TargetLockFrameValidationGate(identity: identity)
    }

    mutating func reset() {
        identity = nil
        cameraEvidenceReacquisitionID = nil
        validationGate = nil
    }

    mutating func invalidate() {
        guard let identity else { return }
        validationGate = TargetLockFrameValidationGate(identity: identity)
    }

    @discardableResult
    mutating func observe(
        _ validation: TargetLockFrameValidation,
        identity: TargetLockIdentity,
        cameraEvidenceReacquisitionID: Int
    ) -> TargetLockFrameReadinessUpdate {
        guard self.identity == identity,
              self.cameraEvidenceReacquisitionID
                == cameraEvidenceReacquisitionID,
              var validationGate else {
            return .ignoredStaleIdentity
        }
        let update = validationGate.observe(validation, identity: identity)
        self.validationGate = validationGate
        return update
    }

    func exactFrameValidation(
        _ validation: TargetLockFrameValidation,
        identity: TargetLockIdentity,
        cameraEvidenceReacquisitionID: Int
    ) -> TargetLockFrameValidation {
        guard self.identity == identity,
              self.cameraEvidenceReacquisitionID
                == cameraEvidenceReacquisitionID,
              isReady else {
            return .rejected(.invalidTargetEvidence)
        }
        return validation
    }
}

enum ScannerGuidedFrameSamplingFailure: Equatable, Sendable {
    case invalidGravity
    case projectionUnavailable
    case depthUnavailable
    case insufficientDepthConfidence
    case invalidCameraPose

    var actionMessage: String {
        switch self {
        case .invalidGravity, .invalidCameraPose:
            "Hold the phone steady, keep the reticle on the corner, and try again."
        case .projectionUnavailable:
            "Keep the reticle inside the camera preview and try that point again."
        case .depthUnavailable, .insufficientDepthConfidence:
            "LiDAR could not confirm that corner. Hold steady on the box and try again."
        }
    }

    var captureFailure: GuidedBoxCaptureFailure {
        switch self {
        case .depthUnavailable, .insufficientDepthConfidence:
            .depthTimeout
        case .invalidGravity, .projectionUnavailable, .invalidCameraPose:
            .trackingTimeout
        }
    }
}

enum ScannerGuidedFrameSampleResult: Equatable, Sendable {
    case success(GuidedBoxPointSample)
    case failure(ScannerGuidedFrameSamplingFailure)

    var sample: GuidedBoxPointSample? {
        guard case .success(let sample) = self else { return nil }
        return sample
    }
}

enum ScannerGuidedFrameAttemptDecision: Equatable, Sendable {
    case retry
    case terminate
}

/// Bounds repeated settled-frame sampling so missing or low-confidence depth
/// cannot leave the exact guided request pending indefinitely.
struct ScannerGuidedFrameAttemptGate: Equatable, Sendable {
    let startedAt: TimeInterval
    let maximumWait: TimeInterval
    let maximumFailedSamples: Int
    private(set) var failedSampleCount = 0

    init(
        startedAt: TimeInterval,
        maximumWait: TimeInterval,
        maximumFailedSamples: Int
    ) {
        self.startedAt = startedAt
        self.maximumWait = maximumWait
        self.maximumFailedSamples = maximumFailedSamples
    }

    func hasExpired(at time: TimeInterval) -> Bool {
        guard startedAt.isFinite,
              time.isFinite,
              maximumWait.isFinite,
              maximumWait > 0,
              maximumFailedSamples > 0 else {
            return true
        }
        return time - startedAt >= maximumWait
    }

    mutating func recordFailure(
        at time: TimeInterval
    ) -> ScannerGuidedFrameAttemptDecision {
        failedSampleCount += 1
        guard failedSampleCount < maximumFailedSamples,
              !hasExpired(at: time) else {
            return .terminate
        }
        return .retry
    }
}

struct ScannerGuidedFrameSampler: Sendable {
    var depthSampler = ScannerFrameDepthSampler()

    func sample(
        request: GuidedBoxCaptureRequest,
        normalizedImagePoint: SIMD2<Float>,
        grid: DepthGrid?,
        cameraImageResolutionPixels: SIMD2<Int>,
        cameraIntrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        gravity: SIMD3<Float>
    ) -> ScannerGuidedFrameSampleResult {
        guard gravity.x.isFinite,
              gravity.y.isFinite,
              gravity.z.isFinite,
              simd_length_squared(gravity) > 0.000_1 else {
            return .failure(.invalidGravity)
        }
        guard let grid,
              let depthSample = depthSampler.sample(
                  normalizedImagePoint: normalizedImagePoint,
                  grid: grid,
                  cameraImageResolutionPixels: cameraImageResolutionPixels,
                  cameraIntrinsics: cameraIntrinsics,
                  cameraTransform: cameraTransform
              ) else {
            return .failure(.depthUnavailable)
        }
        guard depthSample.confidence >= .medium else {
            return .failure(.insufficientDepthConfidence)
        }
        guard let capturedPose = capturePose(from: cameraTransform) else {
            return .failure(.invalidCameraPose)
        }

        return .success(
            GuidedBoxPointSample(
                provenance: GuidedBoxPointProvenance(
                    requestID: request.requestID,
                    context: request.context,
                    point: request.point,
                    source: .guidedLidarCorners
                ),
                worldPosition: depthSample.worldPosition,
                gravity: gravity,
                capturedPose: capturedPose
            )
        )
    }

    func capturePose(
        from transform: simd_float4x4
    ) -> GuidedBoxCapturePose? {
        guard (0..<4).allSatisfy({ column in
            (0..<4).allSatisfy { row in transform[column][row].isFinite }
        }) else {
            return nil
        }
        let orientation = simd_quatf(transform).vector
        let position = SIMD3<Float>(
            transform.columns.3.x,
            transform.columns.3.y,
            transform.columns.3.z
        )
        guard orientation.x.isFinite,
              orientation.y.isFinite,
              orientation.z.isFinite,
              orientation.w.isFinite else {
            return nil
        }
        return GuidedBoxCapturePose(
            position: position,
            orientation: orientation
        )
    }
}

/// Ensures an exact-frame callback can only complete the request that is still
/// pending after UI back/retry/mode transitions.
struct ScannerGuidedFrameRequestTracker: Equatable, Sendable {
    private(set) var pendingRequest: GuidedBoxCaptureRequest?

    mutating func synchronize(_ request: GuidedBoxCaptureRequest?) {
        guard pendingRequest != request else { return }
        pendingRequest = request
    }

    @discardableResult
    mutating func consumeCompletion(
        for request: GuidedBoxCaptureRequest
    ) -> Bool {
        guard pendingRequest == request else { return false }
        pendingRequest = nil
        return true
    }
}

struct ScannerProjectedGuidedMarker: Equatable, Sendable {
    let number: Int
    let point: GuidedBoxPoint
    let normalizedPreviewPoint: SIMD2<Float>
}

struct ScannerProjectedGuidedLine: Equatable, Sendable {
    let reference: GuidedBoxPoint
    let endpoint: GuidedBoxPoint
    let normalizedReferencePoint: SIMD2<Float>
    let normalizedEndpointPoint: SIMD2<Float>
}

struct ScannerProjectedGuidedOverlay: Equatable, Sendable {
    let markers: [ScannerProjectedGuidedMarker]
    let lines: [ScannerProjectedGuidedLine]

    static let empty = ScannerProjectedGuidedOverlay(markers: [], lines: [])
}
