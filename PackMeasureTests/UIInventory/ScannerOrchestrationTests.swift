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
    private let thirdTargetID = UUID(
        uuidString: "33333333-3333-3333-3333-333333333333"
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
        #expect(state.automaticPhotoMeasurement.targetOwnershipGuard != nil)
        #expect(state.automaticPhotoMeasurement.rigidItemMultiplicityGuard != nil)
        #expect(state.automaticPhotoMeasurement.requiredDepthSampleCount == 160)

        #expect(state.setMeasurementSubject(.generalItem))
        #expect(state.measurementSubject == .generalItem)
        #expect(state.automaticPhotoMeasurement.targetOwnershipGuard != nil)
        #expect(state.automaticPhotoMeasurement.rigidItemMultiplicityGuard == nil)
        #expect(state.automaticPhotoMeasurement.requiredDepthSampleCount == 48)
        #expect(!state.enterGuidedCorners(targetID: firstTargetID))
        #expect(state.measurementMode == .automaticPhotos)
    }

    @Test @MainActor
    func boxAndGeneralItemBothRejectGradualBridgeOwnership() throws {
        let width = 40
        let height = 48
        var labels = Array(repeating: UInt32.zero, count: width * height)
        var depths = Array(repeating: Float(1), count: width * height)

        for y in 4...37 {
            for x in 6...22 {
                labels[y * width + x] = 5
            }
        }
        for y in 35...44 {
            for x in 25...36 {
                let index = y * width + x
                labels[index] = 5
                depths[index] = 1.12
            }
        }
        for (x, depth) in [(23, Float(1.04)), (24, 1.08), (25, 1.12)] {
            let index = 37 * width + x
            labels[index] = 5
            depths[index] = depth
        }

        let mask = try PhotoInstanceLabelMask(
            width: width,
            height: height,
            labels: labels
        )
        let depthGrid = DepthGrid(
            width: width,
            height: height,
            depths: depths,
            confidences: Array(repeating: 2, count: width * height)
        )
        let calibration = PhotoCameraCalibration(
            imageWidth: width,
            imageHeight: height,
            intrinsics: simd_float3x3(
                SIMD3<Float>(Float(width), 0, 0),
                SIMD3<Float>(0, Float(height), 0),
                SIMD3<Float>(Float(width) / 2, Float(height) / 2, 1)
            ),
            cameraTransform: matrix_identity_float4x4
        )

        for subject in [TargetLockSubject.box, .generalItem] {
            let state = ScannerSheetView.ScannerStateModel()
            if subject == .generalItem {
                #expect(state.setMeasurementSubject(.generalItem))
            }

            do {
                _ = try state.automaticPhotoMeasurement.makePointCloud(
                    labelMask: mask,
                    depthGrid: depthGrid,
                    calibration: calibration,
                    prompt: .target(
                        normalizedImagePoint: SIMD2<Float>(14.5 / Float(width), 12.5 / Float(height))
                    )
                )
                Issue.record("\(subject) accepted a macroscopic secondary lobe")
            } catch let error as PhotoObjectMeasurementError {
                guard case .targetOwnershipAmbiguous = error else {
                    Issue.record("\(subject) failed for the wrong reason: \(error)")
                    continue
                }
            } catch {
                Issue.record("\(subject) failed with an unexpected error: \(error)")
            }
        }
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
    func nextAngleRetiresPriorWorldAnchorAndRequiresAFreshTap() throws {
        let state = try selectedReadyState()
        let firstAuthority = try #require(state.beginAutomaticCapture())
        let firstIdentity = firstAuthority.identity
        _ = try #require(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: SIMD3<Float>(0.2, 0.4, -1.1)),
                authority: firstAuthority
            )
        )
        let acceptedRecords = state.capturedAngleRecords
        let seriesID = state.measurementSeriesID

        state.prepareForAiming()

        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.activeTargetIdentity == nil)
        #expect(state.activeTargetLock == nil)
        #expect(state.automaticTargetPrompt == nil)
        #expect(state.automaticTargetValidationLockSnapshot == nil)
        #expect(state.targetFrameValidationGate == nil)
        #expect(state.pendingAutomaticCaptureAuthority == nil)
        #expect(state.previewBecameReady())
        #expect(!state.canStartAutomaticCapture)
        #expect(
            state.observeAutomaticTargetValidation(.valid, identity: firstIdentity)
                == .ignoredStaleIdentity
        )

        let secondPoint = SIMD2<Float>(0.72, 0.41)
        let secondIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: secondPoint,
                id: secondTargetID
            )
        )
        #expect(secondIdentity != firstIdentity)
        #expect(secondIdentity.targetID == secondTargetID)
        #expect(secondIdentity.measurementSeriesID == seriesID)
        #expect(
            state.automaticTargetPrompt
                == .target(normalizedImagePoint: secondPoint)
        )
        #expect(state.canStartAutomaticCapture)

        let secondAuthority = try #require(state.beginAutomaticCapture())
        #expect(secondAuthority.identity == secondIdentity)
        #expect(secondAuthority.lockedContext == nil)
        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: SIMD3<Float>(8, 0, -3)),
                authority: firstAuthority
            ) == nil
        )
        #expect(state.pendingAutomaticCaptureAuthority == secondAuthority)
        #expect(state.capturedAngleRecords == acceptedRecords)
    }

    @Test @MainActor
    func finalAngleAutoZoomRequiresFreshPostZoomTargetAuthority() throws {
        let state = readyState()
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )

        let firstIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.31, 0.57),
                id: firstTargetID
            )
        )
        let firstAuthority = try #require(state.beginAutomaticCapture())
        _ = try #require(
            state.receiveAutomaticMeasurement(
                automaticCapture(
                    center: SIMD3<Float>(0.2, 0.4, -1.1),
                    viewpointPosition: SIMD3<Float>(0, 0, 2),
                    horizontalForward: SIMD2<Float>(0, -1)
                ),
                authority: firstAuthority
            )
        )

        state.prepareForAiming()
        #expect(state.previewBecameReady())
        let secondIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.68, 0.44),
                id: secondTargetID
            )
        )
        let secondAuthority = try #require(state.beginAutomaticCapture())
        _ = try #require(
            state.receiveAutomaticMeasurement(
                automaticCapture(
                    center: SIMD3<Float>(0.2, 0.4, -1.1),
                    viewpointPosition: SIMD3<Float>(2, 0, 0),
                    horizontalForward: SIMD2<Float>(-1, 0)
                ),
                authority: secondAuthority
            )
        )
        let acceptedRecords = state.capturedAngleRecords
        let seriesID = state.measurementSeriesID
        let reacquisitionID = state.cameraEvidenceReacquisitionID
        #expect(acceptedRecords.count == 2)

        state.prepareForAiming()
        state.beginCameraZoomApplication()
        #expect(state.previewBecameReady())
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )

        #expect(state.cameraZoom == .half)
        #expect(
            state.cameraEvidenceReacquisitionID == reacquisitionID + 1
        )
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.activeTargetIdentity == nil)
        #expect(
            state.observeAutomaticTargetValidation(
                .valid,
                identity: secondIdentity
            ) == .ignoredStaleIdentity
        )

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )
        #expect(state.previewBecameReady())

        let thirdIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.49, 0.52),
                id: thirdTargetID
            )
        )
        #expect(thirdIdentity != firstIdentity)
        #expect(thirdIdentity != secondIdentity)
        let thirdAuthority = try #require(state.beginAutomaticCapture())
        #expect(
            thirdAuthority.cameraEvidenceReacquisitionID
                == reacquisitionID + 1
        )
        #expect(thirdAuthority.identity == thirdIdentity)
        #expect(
            state.receiveAutomaticMeasurement(
                automaticCapture(center: SIMD3<Float>(8, 0, -3)),
                authority: secondAuthority
            ) == nil
        )
        #expect(state.pendingAutomaticCaptureAuthority == thirdAuthority)
        #expect(state.capturedAngleRecords == acceptedRecords)

        let finalProgress = try #require(
            state.receiveAutomaticMeasurement(
                automaticCapture(
                    center: SIMD3<Float>(0.2, 0.4, -1.1),
                    viewpointPosition: SIMD3<Float>(0, 0.21, -1),
                    horizontalForward: SIMD2<Float>(0, 1),
                    cameraZoom: .half
                ),
                authority: thirdAuthority
            )
        )
        guard case .accepted = finalProgress else {
            Issue.record("expected the elevated third angle to resolve consensus")
            return
        }
        #expect(state.capturedAngleRecords.count == 3)
        #expect(
            state.capturedAngleRecords.map(\.cameraProvenance.cameraZoom)
                == [.standard, .standard, .half]
        )
    }

    @Test @MainActor
    func reopeningCameraForNextAngleIsIdempotent() throws {
        let state = try acceptedFirstAngleState()
        let acceptedRecords = state.capturedAngleRecords
        let previewRequestID = state.previewRequestID

        state.prepareForAiming()
        state.prepareForAiming()

        #expect(state.previewRequestID == previewRequestID + 1)
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.activeTargetLock == nil)
        #expect(state.automaticTargetPrompt == nil)
        #expect(state.isPreparingForAiming)
    }

    @Test @MainActor
    func failedSecondAngleRetryPreservesFirstAngleAndMeasurementSeries() throws {
        let state = try acceptedFirstAngleState()
        let acceptedRecords = state.capturedAngleRecords
        let seriesID = state.measurementSeriesID

        state.prepareForAiming()
        #expect(state.previewBecameReady())
        _ = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.69, 0.38),
                id: secondTargetID
            )
        )
        let failedAuthority = try #require(state.beginAutomaticCapture())

        #expect(state.automaticCaptureFailed(authority: failedAuthority))
        state.phase = .failed("Diagnostic D03")
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.measurementSeriesID == seriesID)

        state.prepareForAiming()

        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.activeTargetIdentity == nil)
        #expect(state.pendingAutomaticCaptureAuthority == nil)
        #expect(state.isPreparingForAiming)
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

        // Exercise the stored-lock validator directly. The shipping next-angle
        // path retires this lock before reopening the camera.
        state.phase = .ready
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
    func betweenAngleZoomPreservesAcceptedAnglesButStillRequiresFreshTap() throws {
        let state = try acceptedFirstAngleState()
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
        #expect(state.targetFrameValidationGate == nil)
        #expect(state.targetFrameValidationMessage == nil)
        #expect(state.pendingAutomaticCaptureAuthority == nil)
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.activeTargetIdentity == nil)

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )
        #expect(state.previewBecameReady())
        #expect(!state.requiresFreshCameraEvidence)
        #expect(!state.canStartAutomaticCapture)

        let nextIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.59, 0.36),
                id: secondTargetID
            )
        )
        #expect(nextIdentity.targetID == secondTargetID)
        #expect(state.canStartAutomaticCapture)

        let authority = try #require(state.beginAutomaticCapture())
        #expect(authority.lockedContext == nil)
        #expect(authority.cameraEvidenceReacquisitionID == 1)
    }

    @Test @MainActor
    func frameEvidenceAdapterUsesValidatorAndIgnoresStaleIdentity() throws {
        let state = try acceptedFirstAngleState(center: .zero)
        let identity = try #require(state.activeTargetIdentity)
        state.phase = .ready

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
    func nextAngleTargetCanBeChangedWithoutLosingAcceptedEvidence() throws {
        let state = try acceptedFirstAngleState(center: .zero)
        let acceptedRecords = state.capturedAngleRecords
        state.prepareForAiming()
        #expect(state.previewBecameReady())

        let initialIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.31, 0.57),
                id: firstTargetID
            )
        )
        #expect(initialIdentity.targetID == firstTargetID)
        #expect(state.canChangeAutomaticTarget)
        #expect(state.changeAutomaticTarget())
        #expect(state.activeTargetIdentity == nil)

        let replacementIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.68, 0.44),
                id: secondTargetID
            )
        )
        #expect(replacementIdentity.targetID == secondTargetID)
        #expect(state.activeTargetIdentity == replacementIdentity)
        #expect(state.capturedAngleRecords == acceptedRecords)
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

    @Test @MainActor
    func guidedPointIntentRequiresReadyActiveStepWithoutPendingRequest() throws {
        let state = ScannerSheetView.ScannerStateModel()

        #expect(!state.canRequestGuidedPointCapture)
        #expect(!state.requestGuidedPointCapture())
        #expect(state.guidedPointCaptureIntentID == 0)

        #expect(state.enterGuidedCorners(targetID: firstTargetID))
        #expect(!state.canRequestGuidedPointCapture)
        #expect(!state.requestGuidedPointCapture())
        #expect(state.guidedPointCaptureIntentID == 0)

        #expect(state.previewBecameReady())
        #expect(state.canRequestGuidedPointCapture)
        #expect(state.requestGuidedPointCapture())
        let firstIntentID = state.guidedPointCaptureIntentID
        #expect(firstIntentID == 1)

        let request = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        #expect(!state.canRequestGuidedPointCapture)
        #expect(!state.requestGuidedPointCapture())
        #expect(state.guidedPointCaptureIntentID == firstIntentID)

        #expect(
            state.consumeGuidedCapture(
                guidedSample(for: request, worldPosition: .zero)
            ) == .workflow(.advanced(to: .lengthEndpoint))
        )
        #expect(state.canRequestGuidedPointCapture)
        #expect(state.requestGuidedPointCapture())
        #expect(state.guidedPointCaptureIntentID == firstIntentID + 1)

        state.clearGuidedCapture(for: .restart)
        #expect(!state.canRequestGuidedPointCapture)
        #expect(!state.requestGuidedPointCapture())
        #expect(state.guidedPointCaptureIntentID == firstIntentID + 1)

        #expect(state.enterGuidedCorners(targetID: secondTargetID))
        #expect(state.previewBecameReady())
        #expect(state.requestGuidedPointCapture())
        #expect(state.guidedPointCaptureIntentID == firstIntentID + 2)
    }

    @Test @MainActor
    func exactGuidedTimeoutConsumesOnlyMatchingRequestAndSurfacesRetryFeedback() throws {
        let state = ScannerSheetView.ScannerStateModel()
        #expect(state.enterGuidedCorners(targetID: firstTargetID))
        #expect(state.previewBecameReady())
        #expect(state.requestGuidedPointCapture())
        let request = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        let staleRequest = GuidedBoxCaptureRequest(
            requestID: request.requestID,
            context: GuidedBoxCaptureContext(
                measurementSeriesID: request.context.measurementSeriesID + 1,
                targetID: secondTargetID
            ),
            point: request.point,
            requestedPose: request.requestedPose
        )

        #expect(
            !state.guidedCaptureFailed(
                request: staleRequest,
                failure: .depthTimeout
            )
        )
        #expect(state.guidedCaptureSession?.pendingRequest == request)
        #expect(state.guidedCaptureFeedback == nil)

        #expect(
            state.guidedCaptureFailed(
                request: request,
                failure: .depthTimeout
            )
        )
        #expect(state.guidedCaptureSession?.pendingRequest == nil)
        #expect(
            state.guidedCaptureFeedback
                == .error(GuidedBoxCaptureFailure.depthTimeout.actionMessage)
        )
        #expect(state.canRequestGuidedPointCapture)

        #expect(state.requestGuidedPointCapture())
        let retry = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        #expect(
            state.consumeGuidedCapture(
                guidedSample(for: retry, worldPosition: .zero)
            ) == .workflow(.advanced(to: .lengthEndpoint))
        )
        #expect(state.guidedCaptureFeedback == nil)

        #expect(state.requestGuidedPointCapture())
        let trackingRequest = try #require(
            state.beginGuidedCapture(requestedPose: stablePose)
        )
        #expect(
            state.guidedCaptureFailed(
                request: trackingRequest,
                failure: .trackingTimeout
            )
        )
        #expect(
            state.guidedCaptureFeedback
                == .error(GuidedBoxCaptureFailure.trackingTimeout.actionMessage)
        )
        #expect(state.guidedBack())
        #expect(state.guidedCaptureFeedback == nil)

        state.clearGuidedCapture(for: .sessionReset)
        #expect(state.guidedCaptureFeedback == nil)
    }

    @Test @MainActor
    func guidedGeometryFailureSurfacesReplacementFeedback() throws {
        let state = ScannerSheetView.ScannerStateModel()
        #expect(state.enterGuidedCorners(targetID: firstTargetID))
        #expect(state.previewBecameReady())

        let positions = [
            SIMD3<Float>.zero,
            SIMD3<Float>(0.6, 0, 0),
            SIMD3<Float>(0.3, 0, 0.4),
            SIMD3<Float>(0, 0.5, 0),
        ]
        var finalUpdate: GuidedBoxCaptureSessionUpdate?
        for position in positions {
            #expect(state.requestGuidedPointCapture())
            let request = try #require(
                state.beginGuidedCapture(requestedPose: stablePose)
            )
            finalUpdate = state.consumeGuidedCapture(
                guidedSample(for: request, worldPosition: position)
            )
        }

        guard case let .workflow(.needsReplacement(point, error)) = finalUpdate else {
            Issue.record("expected guided geometry to request a replacement point")
            return
        }
        #expect(point == .widthEndpoint)
        #expect(
            state.guidedCaptureFeedback
                == .replacement(
                    point: .widthEndpoint,
                    message: error.localizedDescription
                )
        )

        #expect(state.guidedBack())
        #expect(state.guidedCaptureFeedback == nil)
    }

    @Test @MainActor
    func betweenAngleRetargetingDoesNotUseLockedFrameValidation() throws {
        let state = try acceptedFirstAngleState(center: .zero)
        state.prepareForAiming()
        #expect(state.previewBecameReady())
        let freshIdentity = try #require(
            state.selectAutomaticTarget(
                rawCameraNormalizedPoint: SIMD2<Float>(0.42, 0.63),
                id: secondTargetID
            )
        )
        #expect(
            state.receiveAutomaticTargetFrameEvidence(
                validTargetFrameEvidence(identity: freshIdentity)
            ) == .ignoredStaleIdentity
        )
        #expect(state.targetFrameValidationGate?.isReady != true)
        #expect(state.canStartAutomaticCapture)
    }

    @Test @MainActor
    func exactAutomaticT03AmbiguatesThenRevalidatesStoredLockAfterTwoPasses() throws {
        let state = try acceptedFirstAngleState(center: .zero)
        let identity = try #require(state.activeTargetIdentity)
        let acceptedRecords = state.capturedAngleRecords
        let evidence = validTargetFrameEvidence(identity: identity)

        // This directly exercises the defensive stored-lock recovery seam. The
        // shipping next-angle path retires the lock and asks for a fresh tap.
        state.phase = .ready
        #expect(state.receiveAutomaticTargetFrameEvidence(evidence) == .waiting)
        #expect(state.receiveAutomaticTargetFrameEvidence(evidence) == .ready)
        let authority = try #require(state.beginAutomaticCapture())
        let lockedContext = try #require(authority.lockedContext)
        let failure = TargetLockFrameValidationFailure.surfaceOutsideBounds

        #expect(
            state.rejectAutomaticCapture(
                authority: authority,
                failure: failure
            )
        )
        #expect(state.pendingAutomaticCaptureAuthority == nil)
        #expect(state.phase == .ready)
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.activeTargetLock?.state == .ambiguous)
        #expect(state.activeTargetLock?.captureContext == nil)
        #expect(state.targetFrameValidationGate?.consecutivePassCount == 0)
        #expect(state.targetFrameValidationMessage == failure.actionMessage)
        #expect(state.lastAutomaticCaptureRejection == failure)
        #expect(!state.canStartAutomaticCapture)

        let validationSnapshot = try #require(
            state.automaticTargetValidationLockSnapshot
        )
        #expect(validationSnapshot.state == .locked)
        #expect(validationSnapshot.captureContext == lockedContext)

        #expect(state.receiveAutomaticTargetFrameEvidence(evidence) == .waiting)
        #expect(state.activeTargetLock?.state == .ambiguous)
        #expect(!state.canStartAutomaticCapture)
        #expect(state.receiveAutomaticTargetFrameEvidence(evidence) == .ready)
        #expect(state.activeTargetLock?.state == .locked)
        #expect(state.activeTargetLock?.captureContext == lockedContext)
        #expect(state.canStartAutomaticCapture)
        #expect(state.lastAutomaticCaptureRejection == failure)

        let nextAuthority = try #require(state.beginAutomaticCapture())
        #expect(
            !state.rejectAutomaticCapture(
                authority: authority,
                failure: .boxNearFaceMismatch
            )
        )
        #expect(state.pendingAutomaticCaptureAuthority == nextAuthority)
        #expect(state.activeTargetLock?.state == .locked)
        #expect(
            state.rejectAutomaticCapture(
                authority: nextAuthority,
                failure: .boxNearFaceMismatch
            )
        )
        #expect(state.capturedAngleRecords == acceptedRecords)
        #expect(state.activeTargetLock?.state == .ambiguous)
        #expect(state.lastAutomaticCaptureRejection == .boxNearFaceMismatch)
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
        includesBounds: Bool = true,
        viewpointPosition: SIMD3<Float> = SIMD3<Float>(0, 0, 2),
        horizontalForward: SIMD2<Float> = SIMD2<Float>(0, -1),
        cameraZoom: ScannerCameraZoom = .standard
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
                    position: viewpointPosition,
                    horizontalForward: horizontalForward
                )
            ),
            cameraProvenance: ScannerCameraCaptureProvenance(
                cameraZoom: cameraZoom,
                appliedDisplayZoomFactor: cameraZoom.rawValue,
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

    private func validTargetFrameEvidence(
        identity: TargetLockIdentity
    ) -> TargetLockFrameEvidence {
        TargetLockFrameEvidence(
            identity: identity,
            projectedPreviewPoint: SIMD2<Float>(0.5, 0.5),
            cameraWorldPosition: SIMD3<Float>(0, 0, 2),
            observedSurface: TargetLockObservedSurface(
                worldPoint: SIMD3<Float>(0, 0, 0.5),
                confidence: .medium
            )
        )
    }
}
