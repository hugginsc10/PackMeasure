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
        #expect(lifecycle.currentSelectionContext == nil)
        #expect(lifecycle.current?.previewWorldAnchor == nil)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func validWorldEvidencePromotesSelectionToLockedCaptureContext() throws {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)
        let bounds = targetBounds()
        let selectionAnchor = SIMD3<Float>(0.1, 0.2, 0.3)
        let bound = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: selectionAnchor,
            cameraEvidenceReacquisitionID: 11
        )

        let promoted = lifecycle.promote(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: bounds
        )

        #expect(bound)
        #expect(promoted)
        #expect(lifecycle.current?.state == .locked)
        #expect(
            lifecycle.currentSelectionContext == TargetSelectionContext(
                identity: identity,
                worldAnchor: selectionAnchor,
                cameraEvidenceReacquisitionID: 11
            )
        )
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
        let bound = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            cameraEvidenceReacquisitionID: 11
        )

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

        #expect(bound)
        #expect(!nonFinitePromotion)
        #expect(!degeneratePromotion)
        #expect(lifecycle.current?.state == .provisional)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func promotionRequiresTapFrameSelectionEvidence() {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)

        let promoted = lifecycle.promote(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: targetBounds()
        )

        #expect(!promoted)
        #expect(lifecycle.current?.state == .provisional)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func selectionBindingCapturesIdentityAnchorAndCameraEpoch() throws {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)
        let selectionAnchor = SIMD3<Float>(0.15, -0.2, 0.7)

        let bound = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: selectionAnchor,
            cameraEvidenceReacquisitionID: 23
        )

        #expect(bound)
        #expect(
            lifecycle.currentSelectionContext == TargetSelectionContext(
                identity: identity,
                worldAnchor: selectionAnchor,
                cameraEvidenceReacquisitionID: 23
            )
        )
        #expect(lifecycle.current?.previewWorldAnchor == selectionAnchor)
        #expect(lifecycle.currentCaptureContext == nil)
    }

    @Test
    func selectionBindingIsOneShotAndImmutable() throws {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)
        let originalAnchor = SIMD3<Float>(0.1, 0.2, 0.3)
        let replacementAnchor = SIMD3<Float>(9, 8, 7)

        let firstBinding = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: originalAnchor,
            cameraEvidenceReacquisitionID: 3
        )
        let replacementBinding = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: replacementAnchor,
            cameraEvidenceReacquisitionID: 4
        )

        #expect(firstBinding)
        #expect(!replacementBinding)
        let retained = try #require(lifecycle.currentSelectionContext)
        #expect(retained.worldAnchor == originalAnchor)
        #expect(retained.cameraEvidenceReacquisitionID == 3)
    }

    @Test
    func invalidSelectionEvidenceFailsClosedWithoutPartialBinding() {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)

        let nonFiniteBinding = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: SIMD3<Float>(.nan, 0, 0.5),
            cameraEvidenceReacquisitionID: 1
        )
        let invalidEpochBinding = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            cameraEvidenceReacquisitionID: -1
        )

        #expect(!nonFiniteBinding)
        #expect(!invalidEpochBinding)
        #expect(lifecycle.currentSelectionContext == nil)
        #expect(lifecycle.current?.previewWorldAnchor == nil)
    }

    @Test
    func previewAnchorUsesTapSelectionUntilPromotionThenCapturedAnchor() {
        var lifecycle = TargetLockLifecycle()
        let identity = lifecycle.select(measurementSeriesID: 7, id: firstID)
        let selectionAnchor = SIMD3<Float>(0.1, 0.2, 0.3)
        let capturedAnchor = SIMD3<Float>(0.2, 0.3, 0.4)

        let bound = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: selectionAnchor,
            cameraEvidenceReacquisitionID: 8
        )
        #expect(bound)
        #expect(lifecycle.current?.previewWorldAnchor == selectionAnchor)

        let promoted = lifecycle.promote(
            identity: identity,
            worldAnchor: capturedAnchor,
            bounds: targetBounds()
        )
        #expect(promoted)
        #expect(lifecycle.current?.previewWorldAnchor == capturedAnchor)
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
        let bound = lifecycle.bindSelection(
            identity: replacement,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            cameraEvidenceReacquisitionID: 11
        )
        let promoted = lifecycle.promote(
            identity: replacement,
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: targetBounds()
        )
        let recordedDelayedContext = lifecycle.recordAcceptedAngle(using: delayedContext)

        #expect(bound)
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

    @Test
    func seriesSelectionAllowsNewlyVisibleSurfaceToRemainProvisional() {
        let identity = TargetLockIdentity(
            targetID: firstID,
            measurementSeriesID: 7
        )
        let reference = TargetSeriesReference(
            originIdentity: identity,
            subject: .box,
            bounds: targetBounds()
        )
        let validator = TargetSeriesOwnershipValidator()

        #expect(
            validator.validateSelection(
                TargetLockObservedSurface(
                    worldPoint: SIMD3<Float>(0.5, 0, 0),
                    confidence: .medium
                ),
                reference: reference,
                measurementSeriesID: 7,
                subject: .box
            ) == .valid
        )
        #expect(
            validator.validateSelection(
                TargetLockObservedSurface(
                    worldPoint: SIMD3<Float>(0.7, 0, 0),
                    confidence: .high
                ),
                reference: reference,
                measurementSeriesID: 7,
                subject: .box
            ) == .valid
        )
        #expect(
            validator.validateSelection(
                TargetLockObservedSurface(
                    worldPoint: SIMD3<Float>(0.85, 0, 0),
                    confidence: .high
                ),
                reference: reference,
                measurementSeriesID: 7,
                subject: .box
            ) == .valid
        )
        #expect(
            validator.validateSelection(
                TargetLockObservedSurface(
                    worldPoint: SIMD3<Float>(0.7, 0, 0),
                    confidence: .low
                ),
                reference: reference,
                measurementSeriesID: 7,
                subject: .box
            ) == .rejected(.invalidEvidence)
        )
    }

    @Test
    func seriesReferenceRejectsStaleSeriesAndSubject() {
        let identity = TargetLockIdentity(
            targetID: firstID,
            measurementSeriesID: 7
        )
        let reference = TargetSeriesReference(
            originIdentity: identity,
            subject: .box,
            bounds: targetBounds()
        )
        let surface = TargetLockObservedSurface(
            worldPoint: .zero,
            confidence: .high
        )
        let validator = TargetSeriesOwnershipValidator()

        #expect(
            validator.validateSelection(
                surface,
                reference: reference,
                measurementSeriesID: 8,
                subject: .box
            ) == .rejected(.staleSeries)
        )
        #expect(
            validator.validateSelection(
                surface,
                reference: reference,
                measurementSeriesID: 7,
                subject: .generalItem
            ) == .rejected(.staleSeries)
        )
    }

    @Test
    func captureMustOwnTapButDoesNotRequireFittedCentersToMatch() {
        let firstIdentity = TargetLockIdentity(
            targetID: firstID,
            measurementSeriesID: 7
        )
        let laterIdentity = TargetLockIdentity(
            targetID: secondID,
            measurementSeriesID: 7
        )
        let reference = TargetSeriesReference(
            originIdentity: firstIdentity,
            subject: .box,
            bounds: targetBounds()
        )
        let selection = TargetSelectionContext(
            identity: laterIdentity,
            worldAnchor: SIMD3<Float>(0.4, 0, 0),
            cameraEvidenceReacquisitionID: 12
        )
        let shiftedCandidate = TargetLockBounds(
            center: SIMD3<Float>(0.55, 0, 0),
            halfExtents: SIMD3<Float>(0.2, 0.2, 0.2),
            yawRadians: 0
        )
        let missedCandidate = TargetLockBounds(
            center: SIMD3<Float>(2, 0, 0),
            halfExtents: SIMD3<Float>(0.2, 0.2, 0.2),
            yawRadians: 0
        )
        let validator = TargetSeriesOwnershipValidator()

        #expect(
            validator.validateCapture(
                shiftedCandidate,
                selection: selection,
                reference: reference,
                subject: .box
            ) == .valid
        )
        #expect(
            validator.validateCapture(
                missedCandidate,
                selection: selection,
                reference: reference,
                subject: .box
            ) == .rejected(.captureMissesSelection)
        )
    }

    @Test
    func captureAcceptsNewlyVisibleTapWhenCandidateOverlapsReference() {
        let reference = seriesReference(bounds: targetBounds())
        let selection = selectionContext(worldAnchor: SIMD3<Float>(0.85, 0, 0))
        let overlappingCandidate = TargetLockBounds(
            center: SIMD3<Float>(0.65, 0, 0),
            halfExtents: SIMD3<Float>(0.25, 0.4, 0.4),
            yawRadians: 0
        )

        #expect(
            TargetSeriesOwnershipValidator().validateCapture(
                overlappingCandidate,
                selection: selection,
                reference: reference,
                subject: .box
            ) == .valid
        )
    }

    @Test
    func captureRejectsPositiveGapNeighborEvenWhenItOwnsFreshTap() {
        let reference = seriesReference(bounds: targetBounds())
        let selection = selectionContext(worldAnchor: SIMD3<Float>(1.05, 0, 0))
        let separatedCandidate = TargetLockBounds(
            center: SIMD3<Float>(1.05, 0, 0),
            halfExtents: SIMD3<Float>(0.45, 0.4, 0.4),
            yawRadians: 0
        )

        #expect(
            TargetSeriesOwnershipValidator().validateCapture(
                separatedCandidate,
                selection: selection,
                reference: reference,
                subject: .box
            ) == .rejected(.selectionOutsideReference)
        )
    }

    @Test
    func captureRejectsBoundaryOnlyContact() {
        let reference = seriesReference(bounds: targetBounds())
        let selection = selectionContext(worldAnchor: SIMD3<Float>(1, 0, 0))
        let touchingCandidate = TargetLockBounds(
            center: SIMD3<Float>(1, 0, 0),
            halfExtents: SIMD3<Float>(0.5, 0.4, 0.4),
            yawRadians: 0
        )

        #expect(
            TargetSeriesOwnershipValidator().validateCapture(
                touchingCandidate,
                selection: selection,
                reference: reference,
                subject: .box
            ) == .rejected(.selectionOutsideReference)
        )
    }

    @Test
    func captureRejectsYawedAABBOverlapWithoutOrientedInteriorOverlap() {
        let yaw = Float.pi / 4
        let referenceBounds = TargetLockBounds(
            center: .zero,
            halfExtents: SIMD3<Float>(0.7, 0.4, 0.1),
            yawRadians: yaw
        )
        let perpendicularOffset = SIMD3<Float>(
            -sin(yaw) * 0.3,
            0,
            cos(yaw) * 0.3
        )
        let candidate = TargetLockBounds(
            center: perpendicularOffset,
            halfExtents: SIMD3<Float>(0.7, 0.4, 0.1),
            yawRadians: yaw
        )

        #expect(
            TargetSeriesOwnershipValidator().validateCapture(
                candidate,
                selection: selectionContext(worldAnchor: perpendicularOffset),
                reference: seriesReference(bounds: referenceBounds),
                subject: .box
            ) == .rejected(.selectionOutsideReference)
        )
    }

    private func seriesReference(
        bounds: TargetLockBounds
    ) -> TargetSeriesReference {
        TargetSeriesReference(
            originIdentity: TargetLockIdentity(
                targetID: firstID,
                measurementSeriesID: 7
            ),
            subject: .box,
            bounds: bounds
        )
    }

    private func selectionContext(
        worldAnchor: SIMD3<Float>
    ) -> TargetSelectionContext {
        TargetSelectionContext(
            identity: TargetLockIdentity(
                targetID: secondID,
                measurementSeriesID: 7
            ),
            worldAnchor: worldAnchor,
            cameraEvidenceReacquisitionID: 12
        )
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
        _ = lifecycle.bindSelection(
            identity: identity,
            worldAnchor: SIMD3<Float>(0, 0, 0.49),
            cameraEvidenceReacquisitionID: 11
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
