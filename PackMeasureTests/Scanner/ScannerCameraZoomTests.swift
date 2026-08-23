import Foundation
import Testing
import simd
@testable import PackMeasure

@Suite("Scanner camera zoom")
struct ScannerCameraZoomTests {
    @Test
    func displayZoomMapsToTheCaptureDevicesNativeFactor() throws {
        let half = try #require(
            ScannerCameraZoomPolicy.deviceFactor(
                for: .half,
                displayMultiplier: 0.5
            )
        )
        let standard = try #require(
            ScannerCameraZoomPolicy.deviceFactor(
                for: .standard,
                displayMultiplier: 0.5
            )
        )

        #expect(half == 1.0)
        #expect(standard == 2.0)
    }

    @Test
    func capabilityMappingOffersHalfAndStandardWhenBothNativeFactorsAreSupported() {
        let zooms = ScannerCameraZoomPolicy.supportedZooms(
            displayMultiplier: 0.5,
            minDeviceFactor: 1.0,
            maxDeviceFactor: 2.0
        )

        #expect(zooms == [.half, .standard])
    }

    @Test
    func capabilityMappingOmitsHalfWhenItsNativeFactorIsUnavailable() {
        let zooms = ScannerCameraZoomPolicy.supportedZooms(
            displayMultiplier: 0.5,
            minDeviceFactor: 1.5,
            maxDeviceFactor: 4.0
        )

        #expect(zooms == [.standard, .double])
    }

    @Test
    func capabilityMappingDoesNotRequireAVDepthDeliverySupport() {
        let zooms = ScannerCameraZoomPolicy.supportedZooms(
            displayMultiplier: 0.5,
            minDeviceFactor: 1.0,
            maxDeviceFactor: 4.0
        )

        #expect(zooms == [.half, .standard, .double])
    }

    @Test
    func wideOnlyARCameraOffersRealOneAndTwoTimesZoom() {
        let zooms = ScannerCameraZoomPolicy.supportedZooms(
            displayMultiplier: 1,
            minDeviceFactor: 1,
            maxDeviceFactor: 8
        )

        #expect(zooms == [.standard, .double])
    }

    @Test
    func currentNativeFactorMapsBackToTheDisplayedSelection() {
        let supported: [ScannerCameraZoom] = [.half, .standard]

        #expect(
            ScannerCameraZoomPolicy.selectedZoom(
                deviceFactor: 1,
                displayMultiplier: 0.5,
                supportedZooms: supported
            ) == .half
        )
        #expect(
            ScannerCameraZoomPolicy.selectedZoom(
                deviceFactor: 1.5,
                displayMultiplier: 0.5,
                supportedZooms: supported
            ) == nil
        )
        #expect(
            ScannerCameraZoomPolicy.selectedZoom(
                deviceFactor: 2,
                displayMultiplier: 0.5,
                supportedZooms: supported
            ) == .standard
        )
    }

    @Test
    func invalidDeviceCapabilityProducesNoMutatingZoomOptions() {
        #expect(
            ScannerCameraZoomPolicy.supportedZooms(
                displayMultiplier: 0,
                minDeviceFactor: 1,
                maxDeviceFactor: 5
            ).isEmpty
        )
        #expect(
            ScannerCameraZoomPolicy.supportedZooms(
                displayMultiplier: 0.5,
                minDeviceFactor: 4,
                maxDeviceFactor: 1
            ).isEmpty
        )
    }

    @Test
    func confirmationRequiresTwoPostMutationNormalDepthFrames() {
        var gate = ScannerCameraZoomConfirmationGate(
            minimumFrameSequence: 10
        )

        let staleFrameAccepted = gate.observe(
            frameSequence: 10,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let firstNewFrameAccepted = gate.observe(
            frameSequence: 11,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let secondNewFrameAccepted = gate.observe(
            frameSequence: 12,
            hasNormalDepth: true,
            zoomMatches: true
        )

        // ARFrame timestamps can be lower than, or unrelated to, host uptime
        // after a session transition. Confirmation intentionally depends only
        // on the serial delegate's post-mutation frame sequence.
        #expect(!staleFrameAccepted)
        #expect(!firstNewFrameAccepted)
        #expect(secondNewFrameAccepted)
        #expect(gate.matchingFrameCount == 2)
        #expect(gate.lastMatchingFrameSequence == 12)
    }

    @Test
    func confirmationResetsWhenDepthOrReadbackStopsMatching() {
        var gate = ScannerCameraZoomConfirmationGate(
            minimumFrameSequence: 20
        )

        let firstMatch = gate.observe(
            frameSequence: 21,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let missingDepth = gate.observe(
            frameSequence: 22,
            hasNormalDepth: false,
            zoomMatches: true
        )
        let firstMatchAfterDepth = gate.observe(
            frameSequence: 23,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let mismatchedReadback = gate.observe(
            frameSequence: 24,
            hasNormalDepth: true,
            zoomMatches: false
        )
        let firstMatchAfterMismatch = gate.observe(
            frameSequence: 25,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let secondMatchAfterMismatch = gate.observe(
            frameSequence: 26,
            hasNormalDepth: true,
            zoomMatches: true
        )

        #expect(!firstMatch)
        #expect(!missingDepth)
        #expect(!firstMatchAfterDepth)
        #expect(!mismatchedReadback)
        #expect(!firstMatchAfterMismatch)
        #expect(secondMatchAfterMismatch)
    }

    @Test
    func frameEvidenceRejectsDeviceReadbackWhenFieldOfViewDidNotChange() {
        #expect(
            !ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .standard,
                baselineNormalizedFocalLength: 0.75,
                to: .double,
                currentNormalizedFocalLength: 0.75
            )
        )
    }

    @Test
    func frameEvidenceAcceptsMaterialZoomInAndZoomOut() {
        #expect(
            ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .standard,
                baselineNormalizedFocalLength: 0.75,
                to: .double,
                currentNormalizedFocalLength: 1.5
            )
        )
        #expect(
            ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .double,
                baselineNormalizedFocalLength: 1.5,
                to: .standard,
                currentNormalizedFocalLength: 0.75
            )
        )
    }

    @Test
    func frameEvidenceRejectsPartialCropForTwoTimesRequest() {
        #expect(
            !ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .standard,
                baselineNormalizedFocalLength: 0.75,
                to: .double,
                currentNormalizedFocalLength: 0.90
            )
        )
    }

    @Test
    func frameEvidenceUsesConfirmedReferenceWhenSessionReappliesSameZoom() {
        #expect(
            ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .double,
                baselineNormalizedFocalLength: 1.49,
                to: .double,
                currentNormalizedFocalLength: 1.51,
                confirmedReferenceNormalizedFocalLength: 1.5
            )
        )
        #expect(
            !ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .double,
                baselineNormalizedFocalLength: 0.75,
                to: .double,
                currentNormalizedFocalLength: 0.75,
                confirmedReferenceNormalizedFocalLength: 1.5
            )
        )
    }

    @Test
    func frameEvidenceUsesTargetReferenceAfterSessionResetsDeviceZoom() {
        #expect(
            ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .standard,
                baselineNormalizedFocalLength: 1.5,
                to: .double,
                currentNormalizedFocalLength: 1.51,
                confirmedReferenceNormalizedFocalLength: 1.5
            )
        )
        #expect(
            !ScannerCameraFrameZoomPolicy.confirmsVisibleTransition(
                from: .standard,
                baselineNormalizedFocalLength: 1.5,
                to: .double,
                currentNormalizedFocalLength: 0.75,
                confirmedReferenceNormalizedFocalLength: 1.5
            )
        )
    }

    @Test
    func normalizedFocalLengthRejectsInvalidCalibrationInputs() {
        #expect(
            ScannerCameraFrameZoomPolicy.normalizedFocalLength(
                focalLengthPixels: 1_500,
                imageWidthPixels: 2_000
            ) == 0.75
        )
        #expect(
            ScannerCameraFrameZoomPolicy.normalizedFocalLength(
                focalLengthPixels: 1_500,
                imageWidthPixels: 0
            ) == nil
        )
    }

    @Test @MainActor
    func baselineConfigurableDeviceDiscoveryDoesNotOwnSessionReapply() {
        let state = ScannerSheetView.ScannerStateModel()

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )

        #expect(state.cameraZoomUsesConfigurableDevice)
        #expect(!state.hasConfirmedExplicitCameraZoom)
        #expect(!state.shouldReapplyCameraZoomAfterSessionRun)
    }

    @Test @MainActor
    func confirmedExplicitSelectionOwnsSessionReapply() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )

        #expect(state.selectCameraZoom(.half))
        #expect(!state.shouldReapplyCameraZoomAfterSessionRun)

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )

        #expect(state.cameraZoom == .half)
        #expect(state.hasConfirmedExplicitCameraZoom)
        #expect(state.shouldReapplyCameraZoomAfterSessionRun)
        #expect(!state.isApplyingCameraZoom)
    }

    @Test @MainActor
    func failedExplicitSelectionClearsSessionReapplyOwnership() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )
        #expect(state.selectCameraZoom(.half))
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half,
            usesConfigurableDevice: true,
            confirmsExplicitSelection: true
        )
        #expect(state.shouldReapplyCameraZoomAfterSessionRun)

        #expect(state.selectCameraZoom(.standard))
        state.cameraZoomApplicationFailed()

        #expect(state.cameraZoom == .half)
        #expect(!state.hasConfirmedExplicitCameraZoom)
        #expect(!state.shouldReapplyCameraZoomAfterSessionRun)
        #expect(!state.isApplyingCameraZoom)
    }

    @Test @MainActor
    func missingConfigurableDeviceFallsBackToStandardAndHidesSelector() {
        let state = ScannerSheetView.ScannerStateModel()

        state.updateCameraZoomAvailability(
            [.standard],
            selected: .standard,
            usesConfigurableDevice: false
        )
        let zoomRequestID = state.cameraZoomRequestID

        #expect(state.availableCameraZooms == [.standard])
        #expect(state.cameraZoom == .standard)
        #expect(!state.cameraZoomUsesConfigurableDevice)
        #expect(!state.canChangeCameraZoom)

        state.selectCameraZoom(.half)

        #expect(state.cameraZoom == .standard)
        #expect(state.cameraZoomRequestID == zoomRequestID)
    }

    @Test @MainActor
    func selectingZoomBeforeAngleOneIncrementsExactlyOneRequest() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard
        )
        let initialRequestID = state.cameraZoomRequestID

        state.selectCameraZoom(.half)

        #expect(state.cameraZoom == .half)
        #expect(state.cameraZoomRequestID == initialRequestID + 1)
        #expect(state.isApplyingCameraZoom)
        #expect(!state.canChangeCameraZoom)

        state.selectCameraZoom(.half)

        #expect(state.cameraZoomRequestID == initialRequestID + 1)

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half
        )

        #expect(!state.isApplyingCameraZoom)
        #expect(state.canChangeCameraZoom)
        #expect(state.cameraZoomRequestID == initialRequestID + 1)
    }

    @Test @MainActor
    func firstAcceptedAngleLocksZoomForTheMeasurementSeries() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard
        )
        state.selectCameraZoom(.half)
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half
        )
        let zoomRequestID = state.cameraZoomRequestID

        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(0, 0, 1))
        )

        #expect(state.capturedEstimates.count == 1)
        #expect(state.cameraZoom == .half)
        #expect(!state.canChangeCameraZoom)

        state.selectCameraZoom(.standard)

        #expect(state.cameraZoom == .half)
        #expect(state.cameraZoomRequestID == zoomRequestID)
        #expect(state.capturedEstimates.count == 1)
    }

    @Test @MainActor
    func resettingSeriesReenablesZoomWithoutChangingTheSelectedLens() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard
        )
        state.selectCameraZoom(.half)
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half
        )
        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(0, 0, 1))
        )
        let zoomRequestID = state.cameraZoomRequestID

        state.resetMeasurementSeries()

        #expect(state.capturedEstimates.isEmpty)
        #expect(state.cameraZoom == .half)
        #expect(state.cameraZoomRequestID == zoomRequestID)
        #expect(!state.canChangeCameraZoom)

        state.phase = .ready

        #expect(state.canChangeCameraZoom)
    }

    @Test @MainActor
    func applyingZoomAndActiveCaptureBothDisableFurtherSelection() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard
        )
        state.selectCameraZoom(.half)
        let zoomRequestID = state.cameraZoomRequestID

        #expect(state.isApplyingCameraZoom)
        #expect(!state.canChangeCameraZoom)
        state.selectCameraZoom(.standard)
        #expect(state.cameraZoom == .half)
        #expect(state.cameraZoomRequestID == zoomRequestID)

        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half
        )
        state.phase = .scanning(progress: 0.25)

        #expect(!state.canChangeCameraZoom)
        state.selectCameraZoom(.standard)
        #expect(state.cameraZoom == .half)
        #expect(state.cameraZoomRequestID == zoomRequestID)
    }

    @Test @MainActor
    func unresolvedCapabilitiesShowCheckingInsteadOfADeadSelector() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready

        #expect(!state.hasResolvedCameraZoomAvailability)
        #expect(state.cameraZoomPresentation == .checking)
    }

    @Test @MainActor
    func unavailableConfigurableCameraShowsFixedViewTruthfully() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.standard],
            selected: .standard,
            usesConfigurableDevice: false
        )

        #expect(state.cameraZoomPresentation == .fixed)
    }

    @Test @MainActor
    func oneSupportedZoomShowsStaticOnlyBadge() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.standard],
            selected: .standard,
            usesConfigurableDevice: true
        )

        #expect(state.cameraZoomPresentation == .single(.standard))
    }

    @Test @MainActor
    func multipleSupportedZoomsShowInteractiveSelection() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )

        #expect(
            state.cameraZoomPresentation
                == .selectable(
                    zooms: [.half, .standard],
                    selected: .standard,
                    isApplying: false
                )
        )
    }

    @Test @MainActor
    func applyingSelectionRemainsVisibleWithProgressState() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )

        #expect(state.selectCameraZoom(.half))
        #expect(
            state.cameraZoomPresentation
                == .selectable(
                    zooms: [.half, .standard],
                    selected: .half,
                    isApplying: true
                )
        )
    }

    @Test @MainActor
    func additionalAngleShowsLockedZoomInsteadOfDisabledButtons() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .half,
            usesConfigurableDevice: true
        )
        state.receiveMeasurement(angleCapture(position: SIMD3<Float>(0, 0, 1)))
        state.prepareForAiming()

        #expect(state.cameraZoomPresentation == .locked(.half))
    }

    @Test @MainActor
    func activeCaptureHidesZoomPresentation() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )
        state.phase = .scanning(progress: 0.25)

        #expect(state.cameraZoomPresentation == .hidden)
    }

    @Test @MainActor
    func failedUnconfirmedSelectionRestoresLastObservedZoomForRetake() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .ready
        state.updateCameraZoomAvailability(
            [.half, .standard],
            selected: .standard,
            usesConfigurableDevice: true
        )

        #expect(state.selectCameraZoom(.half))
        #expect(state.cameraZoom == .half)
        state.cameraZoomApplicationFailed()

        #expect(state.cameraZoom == .standard)
        #expect(state.lastConfirmedCameraZoom == .standard)
        #expect(
            state.cameraZoomPresentation
                == .selectable(
                    zooms: [.half, .standard],
                    selected: .standard,
                    isApplying: false
                )
        )
    }

    private func angleCapture(
        position: SIMD3<Float>
    ) -> MeasurementAngleCapture {
        let derivedForward = SIMD2<Float>(-position.x, -position.z)
        let horizontalForward = simd_length(derivedForward) > 0.0001
            ? simd_normalize(derivedForward)
            : SIMD2<Float>(0, -1)

        return MeasurementAngleCapture(
            evidence: MeasurementCaptureEvidence(
                estimate: MeasurementEstimate(
                    lengthMeters: 0.60,
                    widthMeters: 0.40,
                    heightMeters: 0.50,
                    confidence: .medium,
                    sampleCount: 800,
                    frameCount: 1
                ),
                pointCloudConfidence: .high,
                geometryCenter: .zero
            ),
            viewpoint: MeasurementCameraViewpoint(
                position: position,
                horizontalForward: horizontalForward
            )
        )
    }
}
