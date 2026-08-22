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

        #expect(zooms == [.standard])
    }

    @Test
    func capabilityMappingKeepsOnlyDepthCompatibleFactors() {
        let zooms = ScannerCameraZoomPolicy.supportedZooms(
            displayMultiplier: 0.5,
            minDeviceFactor: 1.0,
            maxDeviceFactor: 4.0,
            depthCompatibleDeviceFactorRanges: [1.75 ... 2.25, 3.0 ... 4.0]
        )

        #expect(zooms == [.standard])
    }

    @Test
    func emptyAVDepthRangesFallBackToARKitSceneDepthConfirmation() {
        let zooms = ScannerCameraZoomPolicy.supportedZooms(
            displayMultiplier: 0.5,
            minDeviceFactor: 1.0,
            maxDeviceFactor: 4.0,
            depthCompatibleDeviceFactorRanges: []
        )

        #expect(zooms == [.half, .standard])
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
    func confirmationRequiresTwoNewerNormalDepthFrames() {
        var gate = ScannerCameraZoomConfirmationGate(
            minimumFrameTimestamp: 10
        )

        let staleFrameAccepted = gate.observe(
            frameTimestamp: 10,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let firstNewFrameAccepted = gate.observe(
            frameTimestamp: 10.1,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let secondNewFrameAccepted = gate.observe(
            frameTimestamp: 10.2,
            hasNormalDepth: true,
            zoomMatches: true
        )

        #expect(!staleFrameAccepted)
        #expect(!firstNewFrameAccepted)
        #expect(secondNewFrameAccepted)
        #expect(gate.matchingFrameCount == 2)
    }

    @Test
    func confirmationResetsWhenDepthOrReadbackStopsMatching() {
        var gate = ScannerCameraZoomConfirmationGate(
            minimumFrameTimestamp: 20
        )

        let firstMatch = gate.observe(
            frameTimestamp: 20.1,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let missingDepth = gate.observe(
            frameTimestamp: 20.2,
            hasNormalDepth: false,
            zoomMatches: true
        )
        let firstMatchAfterDepth = gate.observe(
            frameTimestamp: 20.3,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let mismatchedReadback = gate.observe(
            frameTimestamp: 20.4,
            hasNormalDepth: true,
            zoomMatches: false
        )
        let firstMatchAfterMismatch = gate.observe(
            frameTimestamp: 20.5,
            hasNormalDepth: true,
            zoomMatches: true
        )
        let secondMatchAfterMismatch = gate.observe(
            frameTimestamp: 20.6,
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
