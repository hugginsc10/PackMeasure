import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Target lock identity lifecycle")
struct TargetLockTests {
    private let firstID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let secondID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    @Test
    func selectingTargetCreatesProvisionalIdentityWithoutCaptureAuthority() throws {
        var lifecycle = TargetLockLifecycle()

        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)

        #expect(identity == TargetLockIdentity(targetID: firstID, measurementSeriesID: 7))
        #expect(lifecycle.current?.identity == identity)
        #expect(lifecycle.current?.state == .provisional)
        #expect(lifecycle.current?.acceptedAngleCount == 0)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func validWorldEvidencePromotesSelectionToLockedCaptureContext() throws {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)
        let bounds = targetBounds()

        let promoted = lifecycle.promote(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: bounds
        )

        #expect(promoted)
        #expect(lifecycle.current?.state == .locked)
        #expect(
            lifecycle.currentCaptureContext == TargetCaptureContext(
                identity: identity,
                worldAnchor: SIMD3<Float>(0, 0, 0.5),
                bounds: bounds
            )
        )
    }

    @Test
    func nonFiniteOrDegenerateWorldEvidenceFailsClosed() {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)

        let nonFinitePromotion = lifecycle.promote(
            identity: identity,
            worldAnchor: SIMD3<Float>(.nan, 0, 0),
            bounds: targetBounds()
        )
        let degeneratePromotion = lifecycle.promote(
            identity: identity,
            worldAnchor: .zero,
            bounds: TargetLockBounds(
                center: .zero,
                halfExtents: SIMD3<Float>(0.5, 0, 0.5),
                yawRadians: 0
            )
        )

        #expect(!nonFinitePromotion)
        #expect(!degeneratePromotion)
        #expect(lifecycle.current?.state == .provisional)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func provisionalSelectionCanBeCanceledBeforeAngleOne() {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)

        let canceled = lifecycle.cancelUnaccepted(identity: identity)

        #expect(canceled)
        #expect(lifecycle.current == nil)
    }

    @Test
    func lockedSelectionCanBeCanceledWhileItOwnsNoAcceptedAngles() throws {
        var lifecycle = lockedLifecycle()
        let identity = try #require(lifecycle.current?.identity)

        #expect(lifecycle.current?.state == .locked)
        let canceled = lifecycle.cancelUnaccepted(identity: identity)

        #expect(canceled)
        #expect(lifecycle.current == nil)
    }

    @Test
    func acceptedAngleMakesTargetIdentityNonCancelable() throws {
        var lifecycle = lockedLifecycle()
        let identity = try #require(lifecycle.current?.identity)
        let context = try #require(lifecycle.currentCaptureContext)

        let recorded = lifecycle.recordAcceptedAngle(using: context)
        let canceled = lifecycle.cancelUnaccepted(identity: identity)

        #expect(recorded)
        #expect(lifecycle.current?.acceptedAngleCount == 1)
        #expect(!canceled)
        #expect(lifecycle.current?.identity == identity)
    }

    @Test
    func replacingCanceledSelectionUsesFreshIdentity() throws {
        var lifecycle = TargetLockLifecycle()
        let first = lifecycle.select(measurementSeriesID: 7, id: firstID)
        let canceled = lifecycle.cancelUnaccepted(identity: first)

        #expect(canceled)

        let replacement = lifecycle.select(measurementSeriesID: 7, id: secondID)

        #expect(replacement.targetID == secondID)
        #expect(replacement != first)
        #expect(lifecycle.current?.identity == replacement)
    }

    @Test
    func secondTapCannotReplaceActiveTargetWithoutExplicitCancellation() {
        var lifecycle = TargetLockLifecycle()
        let first = lifecycle.select(measurementSeriesID: 7, id: firstID)

        let repeatedSelection = lifecycle.select(measurementSeriesID: 7, id: secondID)

        #expect(repeatedSelection == first)
        #expect(lifecycle.current?.identity == first)
        #expect(lifecycle.current?.state == .provisional)
    }

    @Test
    func delayedContextFromCanceledTargetCannotAdvanceReplacement() throws {
        var lifecycle = lockedLifecycle(id: firstID)
        let firstIdentity = try #require(lifecycle.current?.identity)
        let delayedContext = try #require(lifecycle.currentCaptureContext)
        let canceled = lifecycle.cancelUnaccepted(identity: firstIdentity)
        #expect(canceled)

        let replacement = lifecycle.select(measurementSeriesID: 7, id: secondID)
        let promoted = lifecycle.promote(
            identity: replacement,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: targetBounds()
        )
        let recordedDelayedContext = lifecycle.recordAcceptedAngle(using: delayedContext)

        #expect(promoted)
        #expect(!recordedDelayedContext)
        #expect(lifecycle.current?.identity == replacement)
        #expect(lifecycle.current?.acceptedAngleCount == 0)
    }

    @Test
    func callbackFromDifferentMeasurementSeriesIsIgnored() throws {
        var lifecycle = lockedLifecycle()
        let current = try #require(lifecycle.currentCaptureContext)
        let stale = TargetCaptureContext(
            identity: TargetLockIdentity(
                targetID: current.identity.targetID,
                measurementSeriesID: current.identity.measurementSeriesID + 1
            ),
            worldAnchor: current.worldAnchor,
            bounds: current.bounds
        )

        let recorded = lifecycle.recordAcceptedAngle(using: stale)

        #expect(!recorded)
        #expect(lifecycle.current?.acceptedAngleCount == 0)
    }

    @Test
    func ambiguousAndLostStatesPreserveAcceptedEvidenceButDisableCapture() throws {
        var lifecycle = lockedLifecycle()
        let identity = try #require(lifecycle.current?.identity)
        let context = try #require(lifecycle.currentCaptureContext)
        let recorded = lifecycle.recordAcceptedAngle(using: context)
        let markedAmbiguous = lifecycle.markAmbiguous(identity: identity)

        #expect(recorded)

        #expect(markedAmbiguous)
        #expect(lifecycle.current?.state == .ambiguous)
        #expect(lifecycle.current?.acceptedAngleCount == 1)
        #expect(lifecycle.currentCaptureContext == nil)

        let restored = lifecycle.restoreLocked(identity: identity)
        #expect(restored)
        #expect(lifecycle.currentCaptureContext != nil)
        let markedLost = lifecycle.markLost(identity: identity)
        #expect(markedLost)
        #expect(lifecycle.current?.state == .lost)
        #expect(lifecycle.current?.acceptedAngleCount == 1)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func movedTargetCannotBeSilentlyRestoredIntoExistingSeries() throws {
        var lifecycle = lockedLifecycle()
        let identity = try #require(lifecycle.current?.identity)

        let markedMoved = lifecycle.markMoved(identity: identity)
        let restored = lifecycle.restoreLocked(identity: identity)

        #expect(markedMoved)
        #expect(lifecycle.current?.state == .moved)
        #expect(!restored)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func yawOrientedBoundsContainOnlyPointsInsideTheirLocalAxes() {
        let bounds = TargetLockBounds(
            center: .zero,
            halfExtents: SIMD3<Float>(0.6, 0.5, 0.2),
            yawRadians: .pi / 2
        )

        #expect(bounds.contains(SIMD3<Float>(0, 0, 0.55)))
        #expect(!bounds.contains(SIMD3<Float>(0.30, 0, 0)))
        #expect(bounds.contains(SIMD3<Float>(0.21, 0, 0), slackMeters: 0.02))
    }

    private func lockedLifecycle(
        id: UUID? = nil,
        measurementSeriesID: Int = 7
    ) -> TargetLockLifecycle {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(
            measurementSeriesID: measurementSeriesID,
            id: id ?? firstID
        )
        _ = lifecycle.promote(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: targetBounds()
        )
        return lifecycle
    }

    private func targetBounds() -> TargetLockBounds {
        TargetLockBounds(
            center: .zero,
            halfExtents: SIMD3<Float>(0.5, 0.5, 0.5),
            yawRadians: 0
        )
    }
}
