import Foundation
import simd

struct TargetLockIdentity: Equatable, Hashable, Sendable {
    let targetID: UUID
    let measurementSeriesID: Int
}

/// Tap-frame LiDAR evidence that binds a fresh per-angle selection to one
/// physical world point. The capture frame must reproject and revalidate this
/// point before it can become a Vision prompt.
struct TargetSelectionContext: Equatable, Sendable {
    let identity: TargetLockIdentity
    let worldAnchor: SIMD3<Float>
    let cameraEvidenceReacquisitionID: Int
}

enum TargetLockState: Equatable, Sendable {
    case provisional
    case locked
    case ambiguous
    case lost
    case moved
}

/// Gravity-aligned target volume whose horizontal axes may rotate around Y.
struct TargetLockBounds: Equatable, Sendable {
    let center: SIMD3<Float>
    let halfExtents: SIMD3<Float>
    let yawRadians: Float

    var hasValidEvidence: Bool {
        center.targetLockAllFinite
            && halfExtents.targetLockAllFinite
            && yawRadians.isFinite
            && halfExtents.x > 0
            && halfExtents.y > 0
            && halfExtents.z > 0
    }

    func contains(
        _ worldPoint: SIMD3<Float>,
        slackMeters: Float = 0
    ) -> Bool {
        guard hasValidEvidence,
              worldPoint.targetLockAllFinite,
              slackMeters.isFinite,
              slackMeters >= 0 else {
            return false
        }

        let local = localCoordinates(of: worldPoint)
        return abs(local.x) <= halfExtents.x + slackMeters
            && abs(local.y) <= halfExtents.y + slackMeters
            && abs(local.z) <= halfExtents.z + slackMeters
    }

    func localCoordinates(of worldPoint: SIMD3<Float>) -> SIMD3<Float> {
        let delta = worldPoint - center
        let cosine = cos(yawRadians)
        let sine = sin(yawRadians)
        return SIMD3<Float>(
            cosine * delta.x + sine * delta.z,
            delta.y,
            -sine * delta.x + cosine * delta.z
        )
    }

    /// Returns true only when two gravity-aligned, yaw-oriented volumes share
    /// positive 3D interior. Face/edge contact is not ownership evidence, and
    /// testing the four rectangle axes avoids accepting disjoint yawed boxes
    /// whose world-axis-aligned bounding boxes happen to overlap.
    func overlapsInterior(
        with other: TargetLockBounds,
        minimumOverlapMeters: Float = 0
    ) -> Bool {
        guard hasValidEvidence,
              other.hasValidEvidence,
              minimumOverlapMeters.isFinite,
              minimumOverlapMeters >= 0 else {
            return false
        }

        let verticalOverlap = halfExtents.y
            + other.halfExtents.y
            - abs(other.center.y - center.y)
        guard verticalOverlap > minimumOverlapMeters else { return false }

        let centerDelta = SIMD2<Float>(
            other.center.x - center.x,
            other.center.z - center.z
        )
        let separatingAxes = [
            horizontalXAxis,
            horizontalZAxis,
            other.horizontalXAxis,
            other.horizontalZAxis,
        ]
        return separatingAxes.allSatisfy { axis in
            let projectedOverlap = projectedHorizontalRadius(on: axis)
                + other.projectedHorizontalRadius(on: axis)
                - abs(simd_dot(centerDelta, axis))
            return projectedOverlap.isFinite
                && projectedOverlap > minimumOverlapMeters
        }
    }

    private var horizontalXAxis: SIMD2<Float> {
        SIMD2<Float>(cos(yawRadians), sin(yawRadians))
    }

    private var horizontalZAxis: SIMD2<Float> {
        SIMD2<Float>(-sin(yawRadians), cos(yawRadians))
    }

    private func projectedHorizontalRadius(on axis: SIMD2<Float>) -> Float {
        abs(simd_dot(axis, horizontalXAxis)) * halfExtents.x
            + abs(simd_dot(axis, horizontalZAxis)) * halfExtents.z
    }
}

/// Immutable first-angle world reference retained after the per-angle target
/// lock is retired. Fresh taps are still required, but they must resolve back
/// to this same stationary volume before another angle can join the series.
struct TargetSeriesReference: Equatable, Sendable {
    let originIdentity: TargetLockIdentity
    let subject: TargetLockSubject
    let bounds: TargetLockBounds

    var measurementSeriesID: Int {
        originIdentity.measurementSeriesID
    }
}

enum TargetSeriesOwnershipFailure: Equatable, Sendable {
    case invalidEvidence
    case staleSeries
    case selectionOutsideReference
    case captureMissesSelection

    var actionMessage: String {
        switch self {
        case .invalidEvidence, .staleSeries:
            "Retap the same item before taking the photo."
        case .selectionOutsideReference:
            "That tap appears to be on a different item. Retap the same item you used for angle 1."
        case .captureMissesSelection:
            "PackMeasure lost the item you tapped. Retap the same item and take the photo again."
        }
    }
}

enum TargetSeriesOwnershipValidation: Equatable, Sendable {
    case valid
    case rejected(TargetSeriesOwnershipFailure)
}

/// Uses ARKit's stable world coordinate system to prevent a similarly sized
/// neighboring object from joining an existing multi-angle measurement.
struct TargetSeriesOwnershipValidator: Equatable, Sendable {
    var relativeBoundsSlack: Float = 0.10
    var minimumBoundsSlackMeters: Float = 0.03
    var maximumBoundsSlackMeters: Float = 0.08
    var minimumInteriorOverlapMeters: Float = 0.03

    func validateSelection(
        _ surface: TargetLockObservedSurface,
        reference: TargetSeriesReference,
        measurementSeriesID: Int,
        subject: TargetLockSubject
    ) -> TargetSeriesOwnershipValidation {
        guard configurationIsValid,
              reference.measurementSeriesID == measurementSeriesID,
              reference.subject == subject else {
            return .rejected(.staleSeries)
        }
        guard reference.bounds.hasValidEvidence,
              surface.worldPoint.targetLockAllFinite,
              surface.confidence >= .medium else {
            return .rejected(.invalidEvidence)
        }
        // The first photo sees only part of a 3D object. A later tap may land
        // on a newly visible surface outside that partial fit, so selection
        // remains provisional until the settled capture supplies a candidate
        // volume that both owns this fresh tap and overlaps angle 1.
        return .valid
    }

    func validateCapture(
        _ candidateBounds: TargetLockBounds,
        selection: TargetSelectionContext,
        reference: TargetSeriesReference?,
        subject: TargetLockSubject
    ) -> TargetSeriesOwnershipValidation {
        guard configurationIsValid,
              candidateBounds.hasValidEvidence,
              selection.worldAnchor.targetLockAllFinite,
              let candidateTolerance = boundsSlack(for: candidateBounds),
              candidateBounds.contains(
                selection.worldAnchor,
                slackMeters: candidateTolerance
              ) else {
            return .rejected(.captureMissesSelection)
        }

        guard let reference else { return .valid }
        guard reference.measurementSeriesID
                == selection.identity.measurementSeriesID,
              reference.subject == subject else {
            return .rejected(.staleSeries)
        }
        guard reference.bounds.hasValidEvidence else {
            return .rejected(.invalidEvidence)
        }
        // Treat sub-noise-floor intersections as contact, not shared ownership.
        // Adjacent fitted volumes can bleed into each other by a few millimeters
        // even when Vision correctly isolates two different physical items.
        guard candidateBounds.overlapsInterior(
            with: reference.bounds,
            minimumOverlapMeters: minimumInteriorOverlapMeters
        ) else {
            return .rejected(.selectionOutsideReference)
        }
        return .valid
    }

    private var configurationIsValid: Bool {
        relativeBoundsSlack.isFinite
            && relativeBoundsSlack >= 0
            && minimumBoundsSlackMeters.isFinite
            && minimumBoundsSlackMeters >= 0
            && maximumBoundsSlackMeters.isFinite
            && maximumBoundsSlackMeters >= minimumBoundsSlackMeters
            && minimumInteriorOverlapMeters.isFinite
            && minimumInteriorOverlapMeters >= 0
    }

    private func boundsSlack(for bounds: TargetLockBounds) -> Float? {
        guard bounds.hasValidEvidence else { return nil }
        let fullExtents = bounds.halfExtents * 2
        let diagonal = simd_length(fullExtents)
        guard diagonal.isFinite, diagonal > 0 else { return nil }
        return min(
            maximumBoundsSlackMeters,
            max(minimumBoundsSlackMeters, diagonal * relativeBoundsSlack)
        )
    }
}

/// Immutable authority attached to an exact capture request. A delayed
/// callback must still match the active target and measurement series.
struct TargetCaptureContext: Equatable, Sendable {
    let identity: TargetLockIdentity
    let worldAnchor: SIMD3<Float>
    let bounds: TargetLockBounds
}

struct TargetLock: Equatable, Sendable {
    let identity: TargetLockIdentity
    private(set) var state = TargetLockState.provisional
    private(set) var selectionContext: TargetSelectionContext?
    private(set) var worldAnchor: SIMD3<Float>?
    private(set) var bounds: TargetLockBounds?
    private(set) var acceptedAngleCount = 0

    init(identity: TargetLockIdentity) {
        self.identity = identity
    }

    var ownsAcceptedEvidence: Bool {
        acceptedAngleCount > 0
    }

    var canCancelBeforeAcceptedEvidence: Bool {
        !ownsAcceptedEvidence
    }

    var previewWorldAnchor: SIMD3<Float>? {
        worldAnchor ?? selectionContext?.worldAnchor
    }

    var captureContext: TargetCaptureContext? {
        guard state == .locked,
              let worldAnchor,
              worldAnchor.targetLockAllFinite,
              let bounds,
              bounds.hasValidEvidence else {
            return nil
        }
        return TargetCaptureContext(
            identity: identity,
            worldAnchor: worldAnchor,
            bounds: bounds
        )
    }

    @discardableResult
    mutating func bindSelection(
        worldAnchor: SIMD3<Float>,
        cameraEvidenceReacquisitionID: Int
    ) -> Bool {
        guard state == .provisional,
              selectionContext == nil,
              worldAnchor.targetLockAllFinite,
              cameraEvidenceReacquisitionID >= 0 else {
            return false
        }
        selectionContext = TargetSelectionContext(
            identity: identity,
            worldAnchor: worldAnchor,
            cameraEvidenceReacquisitionID: cameraEvidenceReacquisitionID
        )
        return true
    }

    @discardableResult
    mutating func promote(
        worldAnchor: SIMD3<Float>,
        bounds: TargetLockBounds
    ) -> Bool {
        guard state != .moved,
              selectionContext != nil,
              worldAnchor.targetLockAllFinite,
              bounds.hasValidEvidence else {
            return false
        }
        self.worldAnchor = worldAnchor
        self.bounds = bounds
        state = .locked
        return true
    }

    @discardableResult
    mutating func recordAcceptedAngle(using context: TargetCaptureContext) -> Bool {
        guard captureContext == context else { return false }
        acceptedAngleCount += 1
        return true
    }

    mutating func markAmbiguous() {
        state = .ambiguous
    }

    mutating func markLost() {
        state = .lost
    }

    mutating func markMoved() {
        state = .moved
    }

    @discardableResult
    mutating func restoreLocked() -> Bool {
        guard state == .ambiguous || state == .lost,
              worldAnchor?.targetLockAllFinite == true,
              bounds?.hasValidEvidence == true else {
            return false
        }
        state = .locked
        return true
    }
}

/// Owns the optional active lock so cancellation and replacement cannot leave
/// stale capture callbacks with authority over a new selection.
struct TargetLockLifecycle: Equatable, Sendable {
    private(set) var current: TargetLock?

    var currentCaptureContext: TargetCaptureContext? {
        current?.captureContext
    }

    var currentSelectionContext: TargetSelectionContext? {
        current?.selectionContext
    }

    @discardableResult
    mutating func select(
        measurementSeriesID: Int,
        id: UUID = UUID()
    ) -> TargetLockIdentity {
        if let current {
            return current.identity
        }

        let identity = TargetLockIdentity(
            targetID: id,
            measurementSeriesID: measurementSeriesID
        )
        current = TargetLock(identity: identity)
        return identity
    }

    @discardableResult
    mutating func bindSelection(
        identity: TargetLockIdentity,
        worldAnchor: SIMD3<Float>,
        cameraEvidenceReacquisitionID: Int
    ) -> Bool {
        guard current?.identity == identity else { return false }
        return current?.bindSelection(
            worldAnchor: worldAnchor,
            cameraEvidenceReacquisitionID: cameraEvidenceReacquisitionID
        ) == true
    }

    @discardableResult
    mutating func promote(
        identity: TargetLockIdentity,
        worldAnchor: SIMD3<Float>,
        bounds: TargetLockBounds
    ) -> Bool {
        guard current?.identity == identity else { return false }
        return current?.promote(worldAnchor: worldAnchor, bounds: bounds) == true
    }

    @discardableResult
    mutating func recordAcceptedAngle(using context: TargetCaptureContext) -> Bool {
        guard current?.identity == context.identity else { return false }
        return current?.recordAcceptedAngle(using: context) == true
    }

    @discardableResult
    mutating func cancelUnaccepted(identity: TargetLockIdentity) -> Bool {
        guard current?.identity == identity,
              current?.canCancelBeforeAcceptedEvidence == true else {
            return false
        }
        current = nil
        return true
    }

    @discardableResult
    mutating func markAmbiguous(identity: TargetLockIdentity) -> Bool {
        guard current?.identity == identity else { return false }
        current?.markAmbiguous()
        return true
    }

    @discardableResult
    mutating func markLost(identity: TargetLockIdentity) -> Bool {
        guard current?.identity == identity else { return false }
        current?.markLost()
        return true
    }

    @discardableResult
    mutating func markMoved(identity: TargetLockIdentity) -> Bool {
        guard current?.identity == identity else { return false }
        current?.markMoved()
        return true
    }

    @discardableResult
    mutating func restoreLocked(identity: TargetLockIdentity) -> Bool {
        guard current?.identity == identity else { return false }
        return current?.restoreLocked() == true
    }

    mutating func reset() {
        current = nil
    }
}

extension SIMD3 where Scalar == Float {
    var targetLockAllFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
