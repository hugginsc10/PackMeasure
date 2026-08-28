import Foundation
import simd

struct TargetLockIdentity: Equatable, Hashable, Sendable {
    let targetID: UUID
    let measurementSeriesID: Int
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
    mutating func promote(
        worldAnchor: SIMD3<Float>,
        bounds: TargetLockBounds
    ) -> Bool {
        guard state != .moved,
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

private extension SIMD3 where Scalar == Float {
    var targetLockAllFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
