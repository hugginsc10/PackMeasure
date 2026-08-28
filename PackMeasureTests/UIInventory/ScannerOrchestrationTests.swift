import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Build 33 scanner orchestration")
struct ScannerOrchestrationTests {
    private let firstTargetID = UUID(
        uuidString: "11111111-1111-1111-1111-111111111111"
    )!
    private let secondTargetID = UUID(
        uuidString: "22222222-2222-2222-2222-222222222222"
    )!
    private let stablePose = GuidedBoxCapturePose(
        position: SIMD3<Float>(0.1, 1.2, -0.4),
        orientation: SIMD4<Float>(0, 0, 0, 1)
    )

    @Test @MainActor
    func defaultsToBoxAutomaticPhotosAndGeneralItemDisablesRigidGuard() {
        let state = ScannerSheetView.ScannerStateModel()

        #expect(state.measurementSubject == .box)
        #expect(state.measurementMode == .automaticPhotos)
        #expect(state.automaticPhotoMeasurement.rigidItemMultiplicityGuard != nil)

        #expect(state.setMeasurementSubject(.generalItem))
        #expect(state.measurementSubject == .generalItem)
        #expect(state.automaticPhotoMeasurement.rigidItemMultiplicityGuard == nil)
        #expect(!state.enterGuidedCorners(targetID: firstTargetID))
        #expect(state.measurementMode == .automaticPhotos)
    }

    @Test @MainActor
    func targetSelectionKeepsOneImmutableRawCameraPromptAndIdentity() throws {
        let state = readyState()
        let firstPoint = SIMD2<Float>(0.24, 0.61)
        let secondPoint = SIMD2<Float>(0.73, 0.28)

        let firstIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: firstPoint,
                id: firstTargetID
            )
        )
        let secondIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: secondPoint,
                id: secondTargetID
            )
        )

        #expect(firstIdentity == secondIdentity)
        #expect(firstIdentity.targetID == firstTargetID)
        #expect(firstIdentity.measurementSeriesID == state.measurementSeriesID)
        #expect(state.activeTargetIdentity == firstIdentity)
        #expect(state.automaticTargetPrompt == .target(normalizedImagePoint: firstPoint))
        #expect(state.canChangeAutomaticTarget)
    }

    @Test @MainActor
    func changeItemGuardRequiresACompletelyIdlePreAngleOneState() throws {
        let baseline = try selectedReadyState()
        #expect(baseline.canChangeAutomaticTarget)

        let overlayState = try selectedReadyState()
        overlayState.objectOverlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(4, 4),
            outline: try #require(
                MeasurementObjectOutline(width: 4, height: 4, selectedIndices: [5])
            )
        )
        #expect(!overlayState.canChangeAutomaticTarget)

        let capturingState = try selectedReadyState()
        _ = capturingState.beginAutomaticCapture()
        #expect(!capturingState.canChangeAutomaticTarget)

        let zoomState = try selectedReadyState()
        zoomState.beginCameraZoomApplication()
        #expect(!zoomState.canChangeAutomaticTarget)

        let preparingState = try selectedReadyState()
        preparingState.phase = .measured
        preparingState.prepareForAiming()
        #expect(!preparingState.canChangeAutomaticTarget)

        let freshCameraState = try selectedReadyState()
        freshCameraState.cameraZoomApplicationFailed()
        #expect(!freshCameraState.canChangeAutomaticTarget)
    }

    @Test @MainActor
    func changeItemCancelsOnlyUnacceptedTargetAndStalesOldAuthority() throws {
        let state = try selectedReadyState()
        let oldAuthority = try #require(state.beginAutomaticCapture())

        #expect(!state.canChangeAutomaticTarget)
        #expect(state.automaticCaptureFailed(authority: oldAuthority))
        #expect(state.canChangeAutomaticTarget)
        #expect(state.changeAutomaticTarget())
        #expect(state.activeTargetIdentity == nil)
        #expect(state.automaticTargetPrompt == nil)

        let newIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.68, 0.44),
                id: secondTargetID
            )
        )
        #expect(newIdentity.targetID == secondTargetID)

        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: SIMD3<Float>(0.2, 0.4, -1.1)),
                authority: oldAuthority
            ) == nil
        )
        #expect(state.capturedAngleRecords.isEmpty)
        #expect(state.activeTargetIdentity == newIdentity)
    }

    @Test @MainActor
    func exactAuthorityPromotesTargetAndOwnsAcceptedAngle() throws {
        let state = try selectedReadyState()
        let center = SIMD3<Float>(0.2, 0.4, -1.1)
        let authority = try #require(state.beginAutomaticCapture())

        #expect(authority.identity == state.activeTargetIdentity)
        #expect(authority.prompt == state.automaticTargetPrompt)
        #expect(authority.lockedContext == nil)
        #expect(authority.cameraEvidenceReacquisitionID == 0)

        let progress = try #require(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: center),
                authority: authority
            )
        )

        #expect(
            progress == .needsAnotherAngle(
                reason: .firstAngleCaptured,
                acceptedCount: 1
            )
        )
        #expect(state.capturedAngleRecords.count == 1)
        #expect(state.activeTargetLock?.state == .locked)
        #expect(state.activeTargetLock?.acceptedAngleCount == 1)
        #expect(state.activeTargetLock?.worldAnchor == center)
        #expect(state.activeTargetLock?.bounds == targetBounds(center: center))
        #expect(state.automaticTargetPrompt == authority.prompt)
        #expect(!state.canChangeAutomaticTarget)
    }

    @Test @MainActor
    func missingBoundsNoTargetAndStaleRequestFailClosed() throws {
        let noTarget = readyState()
        let fakeIdentity = TargetLockIdentity(
            targetID: firstTargetID,
            measurementSeriesID: noTarget.measurementSeriesID
        )
        let fakeAuthority = ScannerSheetView.ScannerStateModel.AutomaticPhotoCaptureAuthority(
            captureRequestID: 1,
            identity: fakeIdentity,
            prompt: .target(normalizedImagePoint: SIMD2<Float>(0.5, 0.5)),
            lockedContext: nil,
            cameraEvidenceReacquisitionID: 0
        )

        #expect(
            noTarget.receiveAutomaticMeasurement(
                automaticCapture(center: .zero),
                authority: fakeAuthority
            ) == nil
        )
        #expect(noTarget.capturedAngleRecords.isEmpty)

        let state = try selectedReadyState()
        let firstAuthority = try #require(state.beginAutomaticCapture())
        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: .zero, includesBounds: false),
                authority: firstAuthority
            ) == nil
        )
        #expect(state.capturedAngleRecords.isEmpty)
        #expect(state.activeTargetLock?.state == .provisional)

        state.phase = .ready
        let currentAuthority = try #require(state.beginAutomaticCapture())
        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: .zero),
                authority: firstAuthority
            ) == nil
        )
        #expect(state.pendingAutomaticCaptureAuthority == currentAuthority)
        #expect(state.capturedAngleRecords.isEmpty)

        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: .zero),
                authority: currentAuthority
            ) != nil
        )
        #expect(state.capturedAngleRecords.count == 1)
    }

    @Test @MainActor
    func targetValidationNeedsTwoCurrentPassesAndOneFailureClearsReadiness() throws {
        let state = try acceptedFirstAngleState()
        let identity = try #require(state.activeTargetIdentity)

        state.prepareForAiming()
        #expect(state.previewBecameReady())
        #expect(!state.canStartAutomaticCapture)

        let stale = TargetLockIdentity(
            targetID: secondTargetID,
            measurementSeriesID: identity.measurementSeriesID
        )
        #expect(
            state.observeAutomaticTargetValidation(.valid, identity: stale)
                == .ignoredStaleIdentity
        )
        #expect(state.targetFrameValidationGate?.consecutivePassCount == 0)

        #expect(
            state.observeAutomaticTargetValidation(.valid, identity: identity)
                == .waiting
        )
        #expect(!state.canStartAutomaticCapture)
        #expect(
            state.observeAutomaticTargetValidation(.valid, identity: identity)
                == .ready
        )
        #expect(state.canStartAutomaticCapture)

        let failure = TargetLockFrameValidationFailure.surfaceOutsideBounds
        #expect(
            state.observeAutomaticTargetValidation(
                .rejected(failure),
                identity: identity
            ) == .rejected(failure)
        )
        #expect(!state.canStartAutomaticCapture)
        #expect(state.targetFrameValidationGate?.consecutivePassCount == 0)
        #expect(state.targetFrameValidationMessage == failure.actionMessage)
    }

    @Test @MainActor
    func zoomReacquisitionPreservesAngleButGenericPreviewCannotUnlockShutter() throws {
        let state = try acceptedFirstAngleState()
        let identity = try #require(state.activeTargetIdentity)
        let acceptedRecords = state.capturedAngleRecords
        let seriesID = state.measurementSeriesID

        state.prepareForAiming()
        #expect(state.previewBecameReady())
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )
        #expect(state.selectCameraZoom(.half))

        #expect(state.cameraEvidenceReacquisitionID == 1)
        #expect(state.targetFrameValidationGate?.consecutivePassCount == 0)
        #expect(state.targetFrameValidationMessage == nil)
        #expect(state.pendingAutomaticCaptureAuthority == nil)
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.activeTargetIdentity == identity)

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )
        #expect(state.previewBecameReady())
        #expect(!state.requiresFreshCameraEvidence)
        #expect(!state.canStartMeasurement)
        #expect(!state.canStartAutomaticCapture)

        #expect(
            state.observeAutomaticTargetValidation(.valid, identity: identity)
                == .waiting
        )
        #expect(
            state.observeAutomaticTargetValidation(.valid, identity: identity)
                == .ready
        )
        #expect(state.canStartMeasurement)

        let nextAuthority = try #require(state.beginAutomaticCapture())
        #expect(nextAuthority.lockedContext == state.activeTargetLock?.captureContext)
        #expect(nextAuthority.cameraEvidenceReacquisitionID == 1)
    }

    @Test @MainActor
    func frameEvidenceAdapterUsesValidatorAndIgnoresStaleIdentity() throws {
        let state = try acceptedFirstAngleState(center: .zero)
        let identity = try #require(state.activeTargetIdentity)
        state.prepareForAiming()
        #expect(state.previewBecameReady())

        let validEvidence = TargetLockFrameEvidence(
            identity: identity,
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            cameraWorldPosition: SIMD3<Float>(0, 0, 2),
            observedSurface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0, 0, 0.5),
                confidence: .medium
            )
        )

        #expect(state.receiveAutomaticTargetFrameEvidence(validEvidence) == .waiting)
        #expect(state.receiveAutomaticTargetFrameEvidence(validEvidence) == .ready)

        let staleEvidence = TargetLockFrameEvidence(
            identity: TargetLockIdentity(
                targetID: secondTargetID,
                measurementSeriesID: identity.measurementSeriesID
            ),
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            cameraWorldPosition: SIMD3<Float>(0, 0, 2),
            observedSurface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0, 0, 0.5),
                confidence: .medium
            )
        )
        #expect(
            state.receiveAutomaticTargetFrameEvidence(staleEvidence)
                == .ignoredStaleIdentity
        )
        #expect(state.targetFrameValidationGate?.isReady == true)
    }

    @Test @MainActor
    func guidedModeOwnsRequestsAndOnlyConfirmationAdmitsEstimate() throws {
        let state = try selectedReadyState()
        let oldAuthority = try #require(state.beginAutomaticCapture())
        #expect(state.automaticCaptureFailed(authority: oldAuthority))
        let priorSeriesID = state.measurementSeriesID

        #expect(state.enterGuidedCorners(targetID: secondTargetID))
        #expect(state.measurementMode == .guidedCorners)
        #expect(state.measurementSeriesID == priorSeriesID + 1)
        #expect(state.capturedAngleRecords.isEmpty)
        #expect(state.activeTargetIdentity == nil)
        #expect(state.automaticTargetPrompt == nil)
        #expect(state.guidedCaptureSession?.context?.measurementSeriesID == priorSeriesID + 1)
        #expect(state.guidedCaptureSession?.context?.targetID == secondTargetID)

        state.phase = .ready
        state.receiveMeasurement(automaticCapture(center: .zero))
        #expect(state.capturedAngleRecords.isEmpty)
        #expect(state.estimate == nil)
        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: .zero),
                authority: oldAuthority
            ) == nil
        )

        let canceledRequest = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        #expect(state.guidedBack())
        let firstRequest = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        #expect(firstRequest.requestID > canceledRequest.requestID)

        #expect(
            state.consumeGuidedCapture(
                guidedSample(for: firstRequest, worldPosition: .zero)
            ) == .workflow(.advanced(to: .lengthEndpoint))
        )
        let lengthRequest = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        _ = state.consumeGuidedCapture(
            guidedSample(
                for: lengthRequest,
                worldPosition: SIMD3<Float>(0.6096, 0, 0)
            )
        )
        let widthRequest = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        _ = state.consumeGuidedCapture(
            guidedSample(
                for: widthRequest,
                worldPosition: SIMD3<Float>(0, 0, 0.508)
            )
        )
        let heightRequest = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        let heightUpdate = state.consumeGuidedCapture(
            guidedSample(
                for: heightRequest,
                worldPosition: SIMD3<Float>(0, 0.508, 0)
            )
        )
        guard case .workflow(.ready) = heightUpdate else {
            Issue.record("expected four guided points to produce a reviewable measurement")
            return
        }

        #expect(state.estimate == nil)
        let result = try #require(state.confirmGuidedCapture())
        #expect(result.source == .guidedLidarCorners)
        #expect(state.estimate == result.estimate)
        #expect(state.phase == .measured)

        state.clearGuidedCapture(for: .interruption)
        #expect(state.guidedCaptureSession == nil)
        #expect(state.estimate == nil)
        #expect(state.objectOverlay == nil)
    }

    @Test @MainActor
    func guidedEntryFromPausedReviewRequestsFreshPreviewReadiness() throws {
        for pausedPhase in [ScannerPhase.measured, .failed("Retake the photo")] {
            let state = ScannerSheetView.ScannerStateModel()
            state.phase = pausedPhase
            state.previewRequestID = 7
            state.objectOverlay = MeasurementObjectOverlay(
                displayOrientedImageSize: SIMD2<Float>(4, 4),
                outline: try #require(
                    MeasurementObjectOutline(
                        width: 4,
                        height: 4,
                        selectedIndices: [5]
                    )
                )
            )

            #expect(state.enterGuidedCorners(targetID: firstTargetID))
            #expect(state.measurementMode == .guidedCorners)
            #expect(state.previewRequestID == 8)
            #expect(state.phase == .checkingSupport)
            #expect(state.requiresFreshCameraEvidence)
            #expect(state.objectOverlay == nil)

            #expect(state.previewBecameReady())
            #expect(state.phase == .ready)
            #expect(!state.requiresFreshCameraEvidence)
        }
    }

    @Test @MainActor
    func guidedInterruptionAndSessionResetReturnToFreshAutomaticSeries() {
        for boundary in [
            GuidedBoxLifecycleBoundary.interruption,
            .sessionReset,
        ] {
            let state = ScannerSheetView.ScannerStateModel()
            state.phase = .measured
            state.previewRequestID = 11
            #expect(state.enterGuidedCorners(targetID: firstTargetID))
            let guidedSeriesID = state.measurementSeriesID
            let guidedPreviewRequestID = state.previewRequestID

            state.clearGuidedCapture(for: boundary)

            #expect(state.measurementMode == .automaticPhotos)
            #expect(state.guidedCaptureSession == nil)
            #expect(state.measurementSeriesID == guidedSeriesID + 1)
            #expect(state.capturedAngleRecords.isEmpty)
            #expect(state.activeTargetIdentity == nil)
            #expect(state.phase == .checkingSupport)
            #expect(state.requiresFreshCameraEvidence)
            #expect(state.previewRequestID == guidedPreviewRequestID + 1)
            #expect(!state.canStartMeasurement)

            #expect(state.previewBecameReady())
            #expect(state.measurementMode == .automaticPhotos)
            #expect(state.phase == .ready)
            #expect(!state.requiresFreshCameraEvidence)
            #expect(state.canStartMeasurement)
        }
    }

    @MainActor
    private func readyState() -> ScannerSheetView.ScannerStateModel {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        return state
    }

    @MainActor
    private func selectedReadyState() throws -> ScannerSheetView.ScannerStateModel {
        let state = readyState()
        _ = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.31, 0.57),
                id: firstTargetID
            )
        )
        return state
    }

    @MainActor
    private func acceptedFirstAngleState(
        center: SIMD3<Float> = SIMD3<Float>(0.2, 0.4, -1.1)
    ) throws -> ScannerSheetView.ScannerStateModel {
        let state = try selectedReadyState()
        let authority = try #require(state.beginAutomaticCapture())
        _ = try #require(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: center),
                authority: authority
            )
        )
        return state
    }

    private func automaticCapture(
        center: SIMD3<Float>,
        includesBounds: Bool = true
    ) -> ScannerRecordedAngleCapture {
        ScannerRecordedAngleCapture(
            measurement: MeasurementAngleCapture(
                evidence: MeasurementCaptureEvidence(
                    estimate: MeasurementEstimate(
                        lengthMeters: 1,
                        widthMeters: 0.8,
                        heightMeters: 1,
                        confidence: .medium,
                        sampleCount: 900,
                        frameCount: 1
                    ),
                    pointCloudConfidence: .high,
                    geometryCenter: center,
                    targetLockBounds: includesBounds
                        ? targetBounds(center: center)
                        : nil
                ),
                viewpoint: MeasurementCameraViewpoint(
                    position: SIMD3<Float>(0, 0, 2),
                    horizontalForward: SIMD2<Float>(0, -1)
                )
            ),
            cameraProvenance: ScannerCameraCaptureProvenance(
                cameraZoom: .standard,
                appliedDisplayZoomFactor: 1,
                intrinsics: simd_float3x3(columns: (
                    SIMD3<Float>(1_000, 0, 0),
                    SIMD3<Float>(0, 1_000, 0),
                    SIMD3<Float>(1_000, 500, 1)
                )),
                imageResolutionPixels: SIMD2<Int>(2_000, 1_000)
            )!
        )
    }

    private func targetBounds(center: SIMD3<Float>) -> TargetLockBounds {
        TargetLockBounds(
            center: center,
            halfExtents: SIMD3<Float>(0.5, 0.5, 0.5),
            yawRadians: 0
        )
    }

    private func guidedSample(
        for request: GuidedBoxCaptureRequest,
        worldPosition: SIMD3<Float>
    ) -> GuidedBoxPointSample {
        GuidedBoxPointSample(
            provenance: GuidedBoxPointProvenance(
                requestID: request.requestID,
                context: request.context,
                point: request.point,
                source: .guidedLidarCorners
            ),
            worldPosition: worldPosition,
            gravity: SIMD3<Float>(0, -1, 0),
            capturedPose: stablePose
        )
    }
}
