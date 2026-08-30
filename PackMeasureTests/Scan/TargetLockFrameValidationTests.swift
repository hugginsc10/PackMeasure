import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Target lock exact-frame validation")
struct TargetLockFrameValidationTests {
    private let targetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let staleID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!

    @Test
    func provisionalSelectionExactCaptureFrameMatchIsAccepted() {
        let selection = selectionContext()

        let result = TargetSelectionFrameValidator().validate(
            selection: selection,
            currentIdentity: selection.identity,
            currentCameraEvidenceReacquisitionID: 17,
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            observedSurface: TargetLockObservedSurface(
                worldPoint: selection.worldAnchor,
                confidence: .medium
            )
        )

        #expect(result == .valid)
    }

    @Test
    func provisionalSelectionAcceptsExactSurfaceDistanceToleranceBoundary() {
        let selection = selectionContext(worldAnchor: .zero)

        let result = TargetSelectionFrameValidator().validate(
            selection: selection,
            currentIdentity: selection.identity,
            currentCameraEvidenceReacquisitionID: 17,
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            observedSurface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0.08, 0, 0),
                confidence: .high
            )
        )

        #expect(result == .valid)
    }

    @Test
    func provisionalSelectionRejectsSurfaceImmediatelyOutsideTolerance() {
        let selection = selectionContext(worldAnchor: .zero)

        let result = TargetSelectionFrameValidator().validate(
            selection: selection,
            currentIdentity: selection.identity,
            currentCameraEvidenceReacquisitionID: 17,
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            observedSurface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0.080_1, 0, 0),
                confidence: .high
            )
        )

        #expect(result == .rejected(.selectionSurfaceMismatch))
        #expect(
            TargetLockFrameValidationFailure.selectionSurfaceMismatch.actionMessage
                == "The item moved after you selected it. Retap the item and take the photo again."
        )
    }

    @Test
    func provisionalSelectionRequiresCurrentMediumConfidenceSurface() {
        let selection = selectionContext()
        let validator = TargetSelectionFrameValidator()

        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: selection.identity,
                currentCameraEvidenceReacquisitionID: 17,
                projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
                observedSurface: nil
            ) == .rejected(.surfaceUnavailable)
        )
        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: selection.identity,
                currentCameraEvidenceReacquisitionID: 17,
                projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
                observedSurface: TargetLockObservedSurface(
                    worldPoint: selection.worldAnchor,
                    confidence: .low
                )
            ) == .rejected(.insufficientDepthConfidence)
        )
    }

    @Test
    func provisionalSelectionRejectsStaleIdentityAndCameraEpoch() {
        let selection = selectionContext()
        let surface = TargetLockObservedSurface(
            worldPoint: selection.worldAnchor,
            confidence: .high
        )
        let validator = TargetSelectionFrameValidator()

        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: TargetLockIdentity(
                    targetID: staleID,
                    measurementSeriesID: selection.identity.measurementSeriesID
                ),
                currentCameraEvidenceReacquisitionID: 17,
                projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
                observedSurface: surface
            ) == .rejected(.staleIdentity)
        )
        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: selection.identity,
                currentCameraEvidenceReacquisitionID: 18,
                projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
                observedSurface: surface
            ) == .rejected(.invalidTargetEvidence)
        )
    }

    @Test
    func provisionalSelectionEnforcesProtectedPreviewMargin() {
        let selection = selectionContext()
        let surface = TargetLockObservedSurface(
            worldPoint: selection.worldAnchor,
            confidence: .high
        )
        let validator = TargetSelectionFrameValidator()

        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: selection.identity,
                currentCameraEvidenceReacquisitionID: 17,
                projectedPreviewPoint: SIMD2<Float>(0.08, 0.92),
                observedSurface: surface
            ) == .valid
        )
        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: selection.identity,
                currentCameraEvidenceReacquisitionID: 17,
                projectedPreviewPoint: SIMD2<Float>(0.079_9, 0.5),
                observedSurface: surface
            ) == .rejected(.outsideVisiblePreview)
        )
        #expect(
            validator.validate(
                selection: selection,
                currentIdentity: selection.identity,
                currentCameraEvidenceReacquisitionID: 17,
                projectedPreviewPoint: nil,
                observedSurface: surface
            ) == .rejected(.projectionUnavailable)
        )
    }

    @Test
    func exactEightPercentPreviewBoundaryIsAccepted() throws {
        let lock = try lockedTarget()
        let validator = TargetLockFrameValidator()

        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(
                    identity: lock.identity,
                    projectedPoint: SIMD2<Float>(0.08, 0.92)
                )
            ) == .valid
        )
    }

    @Test
    func pointImmediatelyOutsidePreviewBoundaryIsRejected() throws {
        let lock = try lockedTarget()

        let result = TargetLockFrameValidator().validate(
            lock: lock,
            subject: .box,
            evidence: frameEvidence(
                identity: lock.identity,
                projectedPoint: SIMD2<Float>(0.0799, 0.5)
            )
        )

        #expect(result == .rejected(.outsideVisiblePreview))
    }

    @Test
    func projectionAloneNeverProducesFalseGreenReadiness() throws {
        let lock = try lockedTarget()
        let evidence = TargetLockFrameEvidence(
            identity: lock.identity,
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            cameraWorldPosition: SIMD3<Float>(0, 0, 2),
            observedSurface: nil
        )

        #expect(
            TargetLockFrameValidator().validate(
                lock: lock,
                subject: .box,
                evidence: evidence
            ) == .rejected(.surfaceUnavailable)
        )
    }

    @Test
    func staleTargetOrMeasurementSeriesIsRejected() throws {
        let lock = try lockedTarget()
        let evidence = frameEvidence(
            identity: TargetLockIdentity(targetID: staleID, measurementSeriesID: 9)
        )

        #expect(
            TargetLockFrameValidator().validate(
                lock: lock,
                subject: .box,
                evidence: evidence
            ) == .rejected(.staleIdentity)
        )
    }

    @Test
    func missingAndNonFiniteProjectionEvidenceFailClosed() throws {
        let lock = try lockedTarget()
        let validator = TargetLockFrameValidator()

        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(identity: lock.identity, projectedPoint: nil)
            ) == .rejected(.projectionUnavailable)
        )
        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(
                    identity: lock.identity,
                    projectedPoint: SIMD2<Float>(.nan, 0.5)
                )
            ) == .rejected(.projectionUnavailable)
        )
    }

    @Test
    func missingAndNonFiniteCameraPoseFailClosed() throws {
        let lock = try lockedTarget()
        let validator = TargetLockFrameValidator()

        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(identity: lock.identity, cameraPosition: nil)
            ) == .rejected(.cameraPoseUnavailable)
        )
        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(
                    identity: lock.identity,
                    cameraPosition: SIMD3<Float>(0, .infinity, 2)
                )
            ) == .rejected(.cameraPoseUnavailable)
        )
    }

    @Test
    func lowConfidenceAndNonFiniteSurfacesFailClosed() throws {
        let lock = try lockedTarget()
        let validator = TargetLockFrameValidator()

        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(
                    identity: lock.identity,
                    surface: TargetLockObservedSurface(
                        worldPoint: SIMD3<Float>(0, 0, 0.49),
                        confidence: .low
                    )
                )
            ) == .rejected(.insufficientDepthConfidence)
        )
        #expect(
            validator.validate(
                lock: lock,
                subject: .box,
                evidence: frameEvidence(
                    identity: lock.identity,
                    surface: TargetLockObservedSurface(
                        worldPoint: SIMD3<Float>(0, .nan, 0.49),
                        confidence: .high
                    )
                )
            ) == .rejected(.surfaceUnavailable)
        )
    }

    @Test
    func yawOrientedContainmentRejectsSurfaceOutsideSavedTarget() throws {
        let bounds = TargetLockBounds(
            center: .zero,
            halfExtents: SIMD3<Float>(0.6, 0.5, 0.2),
            yawRadians: .pi / 2
        )
        let lock = try lockedTarget(bounds: bounds)
        let evidence = frameEvidence(
            identity: lock.identity,
            cameraPosition: SIMD3<Float>(2, 0, 0),
            surface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0.30, 0, 0),
                confidence: .high
            )
        )

        #expect(
            TargetLockFrameValidator().validate(
                lock: lock,
                subject: .generalItem,
                evidence: evidence
            ) == .rejected(.surfaceOutsideBounds)
        )
    }

    @Test
    func boxNearFaceValidationWorksAfterNinetyDegreeCameraOrbit() throws {
        let lock = try lockedTarget()
        let evidence = frameEvidence(
            identity: lock.identity,
            cameraPosition: SIMD3<Float>(2, 0, 0),
            surface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0.49, 0, 0),
                confidence: .high
            )
        )

        #expect(
            TargetLockFrameValidator().validate(
                lock: lock,
                subject: .box,
                evidence: evidence
            ) == .valid
        )
    }

    @Test
    func boxRejectsSurfaceDeepInsideOldVolume() throws {
        let lock = try lockedTarget()
        let evidence = frameEvidence(
            identity: lock.identity,
            surface: TargetLockObservedSurface(worldPoint: .zero, confidence: .high)
        )

        #expect(
            TargetLockFrameValidator().validate(
                lock: lock,
                subject: .box,
                evidence: evidence
            ) == .rejected(.boxNearFaceMismatch)
        )
    }

    @Test
    func generalItemAllowsConcaveSurfaceInsideSavedBounds() throws {
        let lock = try lockedTarget()
        let evidence = frameEvidence(
            identity: lock.identity,
            surface: TargetLockObservedSurface(worldPoint: .zero, confidence: .medium)
        )

        #expect(
            TargetLockFrameValidator().validate(
                lock: lock,
                subject: .generalItem,
                evidence: evidence
            ) == .valid
        )
    }

    @Test
    func provisionalOrAmbiguousTargetHasNoExactFrameAuthority() throws {
        let identity = TargetLockIdentity(targetID: targetID, measurementSeriesID: 9)
        let provisional = TargetLock(identity: identity)
        var ambiguous = try lockedTarget()
        ambiguous.markAmbiguous()

        #expect(
            TargetLockFrameValidator().validate(
                lock: provisional,
                subject: .box,
                evidence: frameEvidence(identity: identity)
            ) == .rejected(.invalidTargetEvidence)
        )
        #expect(
            TargetLockFrameValidator().validate(
                lock: ambiguous,
                subject: .box,
                evidence: frameEvidence(identity: ambiguous.identity)
            ) == .rejected(.invalidTargetEvidence)
        )
    }

    @Test
    func liveGateRequiresTwoConsecutiveCurrentIdentityPasses() throws {
        let identity = try lockedTarget().identity
        var gate = TargetLockFrameValidationGate(identity: identity)

        let first = gate.observe(.valid, identity: identity)
        #expect(first == .waiting)
        #expect(gate.consecutivePassCount == 1)
        #expect(!gate.isReady)
        let second = gate.observe(.valid, identity: identity)
        #expect(second == .ready)
        #expect(gate.consecutivePassCount == 2)
        #expect(gate.isReady)
    }

    @Test
    func oneCurrentIdentityFailureImmediatelyResetsLiveGate() throws {
        let identity = try lockedTarget().identity
        var gate = TargetLockFrameValidationGate(identity: identity)
        _ = gate.observe(.valid, identity: identity)
        _ = gate.observe(.valid, identity: identity)

        let rejected = gate.observe(
            .rejected(.surfaceOutsideBounds),
            identity: identity
        )
        #expect(rejected == .rejected(.surfaceOutsideBounds))
        #expect(gate.consecutivePassCount == 0)
        #expect(!gate.isReady)
        let firstAfterFailure = gate.observe(.valid, identity: identity)
        #expect(firstAfterFailure == .waiting)
    }

    @Test
    func delayedEvidenceForOldIdentityCannotAdvanceOrResetNewGate() throws {
        let identity = try lockedTarget().identity
        let stale = TargetLockIdentity(targetID: staleID, measurementSeriesID: 9)
        var gate = TargetLockFrameValidationGate(identity: identity)

        let first = gate.observe(.valid, identity: identity)
        let stalePass = gate.observe(.valid, identity: stale)
        #expect(first == .waiting)
        #expect(stalePass == .ignoredStaleIdentity)
        #expect(gate.consecutivePassCount == 1)
        let staleFailure = gate.observe(
            .rejected(.surfaceOutsideBounds),
            identity: stale
        )
        #expect(staleFailure == .ignoredStaleIdentity)
        #expect(gate.consecutivePassCount == 1)
        let second = gate.observe(.valid, identity: identity)
        #expect(second == .ready)
    }

    @Test
    func everyExactFrameRejectionUsesStableT03DiagnosticCategory() {
        for failure in TargetLockFrameValidationFailure.allCases {
            #expect(failure.diagnosticCode == "T03")
            #expect(!failure.actionMessage.isEmpty)
        }
    }

    private func lockedTarget(
        bounds: TargetLockBounds? = nil
    ) throws -> TargetLock {
        let identity = TargetLockIdentity(targetID: targetID, measurementSeriesID: 9)
        var lock = TargetLock(identity: identity)
        let bound = lock.bindSelection(
            worldAnchor: SIMD3<Float>(0, 0, 0.49),
            cameraEvidenceReacquisitionID: 17
        )
        let promoted = lock.promote(
            worldAnchor: SIMD3<Float>(0, 0, 0.5),
            bounds: bounds ?? TargetLockBounds(
                center: .zero,
                halfExtents: SIMD3<Float>(0.5, 0.5, 0.5),
                yawRadians: 0
            )
        )
        #expect(bound)
        #expect(promoted)
        return lock
    }

    private func selectionContext(
        worldAnchor: SIMD3<Float> = SIMD3<Float>(0.1, 0.2, 0.3)
    ) -> TargetSelectionContext {
        TargetSelectionContext(
            identity: TargetLockIdentity(targetID: targetID, measurementSeriesID: 9),
            worldAnchor: worldAnchor,
            cameraEvidenceReacquisitionID: 17
        )
    }

    private func frameEvidence(
        identity: TargetLockIdentity,
        projectedPoint: SIMD2<Float>? = SIMD2<Float>(0.5, 0.5),
        cameraPosition: SIMD3<Float>? = SIMD3<Float>(0, 0, 2),
        surface: TargetLockObservedSurface? = TargetLockObservedSurface(
            worldPoint: SIMD3<Float>(0, 0, 0.49),
            confidence: .medium
        )
    ) -> TargetLockFrameEvidence {
        TargetLockFrameEvidence(
            identity: identity,
            projectedPreviewPoint: projectedPoint,
            cameraWorldPosition: cameraPosition,
            observedSurface: surface
        )
    }
}
