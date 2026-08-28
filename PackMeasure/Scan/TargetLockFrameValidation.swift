import Foundation
import simd

enum TargetLockSubject: Equatable, Sendable {
    case box
    case generalItem
}

enum TargetLockDepthConfidence: Int, Equatable, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct TargetLockObservedSurface: Equatable, Sendable {
    let worldPoint: SIMD3<Float>
    let confidence: TargetLockDepthConfidence
}

/// Current-frame evidence after the coordinator has mapped the saved anchor
/// into normalized preview coordinates and resolved LiDAR at that pixel.
struct TargetLockFrameEvidence: Equatable, Sendable {
    let identity: TargetLockIdentity
    let projectedPreviewPoint: SIMD2<Float>?
    let cameraWorldPosition: SIMD3<Float>?
    let observedSurface: TargetLockObservedSurface?
}

enum TargetLockFrameValidationFailure: CaseIterable, Equatable, Sendable {
    case staleIdentity
    case invalidTargetEvidence
    case projectionUnavailable
    case outsideVisiblePreview
    case cameraPoseUnavailable
    case surfaceUnavailable
    case insufficientDepthConfidence
    case surfaceOutsideBounds
    case boxNearFaceMismatch

    var diagnosticCode: String { "T03" }

    var actionMessage: String {
        switch self {
        case .staleIdentity, .invalidTargetEvidence:
            "Select the item again before taking another photo."
        case .projectionUnavailable:
            "Point the camera back at the selected item."
        case .outsideVisiblePreview:
            "Keep the selected item fully inside the camera preview."
        case .cameraPoseUnavailable:
            "Hold still while PackMeasure restores camera tracking."
        case .surfaceUnavailable, .insufficientDepthConfidence:
            "Hold still while LiDAR finds the selected item."
        case .surfaceOutsideBounds, .boxNearFaceMismatch:
            "Point back at the selected item; the current surface does not match it."
        }
    }
}

enum TargetLockFrameValidation: Equatable, Sendable {
    case valid
    case rejected(TargetLockFrameValidationFailure)
}

struct TargetLockFrameValidator: Equatable, Sendable {
    var protectedPreviewMarginFraction: Float = 0.08
    var boundsSlackMeters: Float = 0.03
    var boxNearFaceToleranceMeters: Float = 0.08

    func validate(
        lock: TargetLock,
        subject: TargetLockSubject,
        evidence: TargetLockFrameEvidence
    ) -> TargetLockFrameValidation {
        guard let context = lock.captureContext,
              configurationIsValid else {
            return .rejected(.invalidTargetEvidence)
        }
        guard evidence.identity == context.identity else {
            return .rejected(.staleIdentity)
        }
        guard let projectedPoint = evidence.projectedPreviewPoint,
              projectedPoint.targetLockAllFinite else {
            return .rejected(.projectionUnavailable)
        }

        let upperPreviewBoundary = 1 - protectedPreviewMarginFraction
        guard projectedPoint.x >= protectedPreviewMarginFraction,
              projectedPoint.x <= upperPreviewBoundary,
              projectedPoint.y >= protectedPreviewMarginFraction,
              projectedPoint.y <= upperPreviewBoundary else {
            return .rejected(.outsideVisiblePreview)
        }
        guard let cameraPosition = evidence.cameraWorldPosition,
              cameraPosition.targetLockAllFinite else {
            return .rejected(.cameraPoseUnavailable)
        }
        guard let surface = evidence.observedSurface,
              surface.worldPoint.targetLockAllFinite else {
            return .rejected(.surfaceUnavailable)
        }
        guard surface.confidence >= .medium else {
            return .rejected(.insufficientDepthConfidence)
        }
        guard context.bounds.contains(
            surface.worldPoint,
            slackMeters: boundsSlackMeters
        ) else {
            return .rejected(.surfaceOutsideBounds)
        }

        guard subject == .box else { return .valid }
        guard let nearFaceDistance = nearFaceDistance(
            from: cameraPosition,
            toward: surface.worldPoint,
            bounds: context.bounds
        ) else {
            return .rejected(.boxNearFaceMismatch)
        }

        let observedDistance = simd_distance(cameraPosition, surface.worldPoint)
        guard observedDistance.isFinite,
              abs(observedDistance - nearFaceDistance) <= boxNearFaceToleranceMeters else {
            return .rejected(.boxNearFaceMismatch)
        }
        return .valid
    }

    private var configurationIsValid: Bool {
        protectedPreviewMarginFraction.isFinite
            && protectedPreviewMarginFraction >= 0
            && protectedPreviewMarginFraction < 0.5
            && boundsSlackMeters.isFinite
            && boundsSlackMeters >= 0
            && boxNearFaceToleranceMeters.isFinite
            && boxNearFaceToleranceMeters >= 0
    }

    private func nearFaceDistance(
        from cameraWorldPosition: SIMD3<Float>,
        toward observedWorldPoint: SIMD3<Float>,
        bounds: TargetLockBounds
    ) -> Float? {
        let localOrigin = bounds.localCoordinates(of: cameraWorldPosition)
        let localObserved = bounds.localCoordinates(of: observedWorldPoint)
        let ray = localObserved - localOrigin
        let rayLength = simd_length(ray)
        guard rayLength.isFinite, rayLength > 0.000_1 else { return nil }
        let direction = ray / rayLength

        var minimumDistance = -Float.infinity
        var maximumDistance = Float.infinity
        for axis in 0..<3 {
            let origin = localOrigin[axis]
            let directionComponent = direction[axis]
            let extent = bounds.halfExtents[axis]

            if abs(directionComponent) < 0.000_001 {
                guard origin >= -extent, origin <= extent else { return nil }
                continue
            }

            let first = (-extent - origin) / directionComponent
            let second = (extent - origin) / directionComponent
            minimumDistance = max(minimumDistance, min(first, second))
            maximumDistance = min(maximumDistance, max(first, second))
            guard maximumDistance >= minimumDistance else { return nil }
        }

        guard minimumDistance.isFinite,
              minimumDistance >= 0,
              maximumDistance >= minimumDistance else {
            return nil
        }
        return minimumDistance
    }
}

enum TargetLockFrameReadinessUpdate: Equatable, Sendable {
    case waiting
    case ready
    case rejected(TargetLockFrameValidationFailure)
    case ignoredStaleIdentity
}

/// Debounces live readiness without allowing delayed observations from a
/// canceled target to advance or reset the replacement target's streak.
struct TargetLockFrameValidationGate: Equatable, Sendable {
    let identity: TargetLockIdentity
    let requiredConsecutivePasses: Int
    private(set) var consecutivePassCount = 0

    init(
        identity: TargetLockIdentity,
        requiredConsecutivePasses: Int = 2
    ) {
        self.identity = identity
        self.requiredConsecutivePasses = max(1, requiredConsecutivePasses)
    }

    var isReady: Bool {
        consecutivePassCount >= requiredConsecutivePasses
    }

    @discardableResult
    mutating func observe(
        _ validation: TargetLockFrameValidation,
        identity observedIdentity: TargetLockIdentity
    ) -> TargetLockFrameReadinessUpdate {
        guard observedIdentity == identity else {
            return .ignoredStaleIdentity
        }

        switch validation {
        case .valid:
            consecutivePassCount = min(
                requiredConsecutivePasses,
                consecutivePassCount + 1
            )
            return isReady ? .ready : .waiting
        case let .rejected(failure):
            consecutivePassCount = 0
            return .rejected(failure)
        }
    }
}

private extension SIMD2 where Scalar == Float {
    var targetLockAllFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension SIMD3 where Scalar == Float {
    var targetLockAllFinite: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
