import Testing
@testable import PackMeasure

@Suite("Scanner capture review policy")
struct ScannerCapturePolicyTests {
    @Test
    func lowConfidenceCaptureRequiresVisibleRetryAndCannotSave() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: estimate(confidence: .low)
        )

        #expect(
            state == .retryRequired(
                ScannerGuidanceCopy.lowConfidenceRetry
            )
        )
        #expect(!state.canSave)
    }

    @Test
    func scannerRejectionWinsEvenIfAStaleEstimateExists() {
        let scannerDiagnostic =
            "The app could not isolate one clear object from this capture. Center one item in frame and retake the photo."
        let state = ScannerCapturePolicy.reviewState(
            phase: .failed(scannerDiagnostic),
            estimate: estimate(confidence: .high)
        )

        #expect(state == .retryRequired(scannerDiagnostic))
        #expect(!state.canSave)
    }

    @Test
    func guidanceExplainsSinglePhotoCapture() {
        #expect(
            ScannerGuidanceCopy.previewTarget
                == "Keep one whole item inside the frame with a little space around it"
        )
        #expect(
            ScannerGuidanceCopy.setup
                == "Point the camera at one object so the whole item is visible with a little floor or background around its edges. Tap Take measurement to capture one frame and estimate its overall size."
        )
    }

    @Test
    func genericRetryCopyDescribesResultWithoutBlamingUser() {
        #expect(
            ScannerGuidanceCopy.lowConfidenceRetry
                == "This photo produced a weak depth sample. Retake it with one whole object in frame and clearer separation from the room."
        )
        #expect(
            ScannerGuidanceCopy.missingEstimateRetry
                == "No usable object measurement was produced from this photo. Retake it with one whole object in frame."
        )
    }

    @Test
    func measuredDimensionsAreExplicitlyLabeledAsAnEstimate() {
        #expect(ScannerResultCopy.sizeSectionTitle == "Estimated size")
    }

    @Test
    func scanQualitySummaryDoesNotClaimMeasurementAccuracy() {
        let summary = ScannerResultCopy.qualitySummary(
            for: estimate(confidence: .high)
        )

        #expect(summary == "High point-cloud quality • 800 points")
        #expect(!summary.localizedCaseInsensitiveContains("confidence"))
        #expect(!summary.localizedCaseInsensitiveContains("accuracy"))
    }

    @Test @MainActor
    func successfulResultReturnsToLivePreviewWithoutStartingCapture() {
        let state = ScannerSheetView.ScannerStateModel()
        state.captureRequestID = 7
        state.phase = .measured
        state.estimate = estimate(confidence: .high)

        state.prepareForAiming()

        #expect(state.estimate == nil)
        #expect(state.phase == .measured)
        #expect(state.previewRequestID == 1)
        #expect(state.captureRequestID == 7)
        #expect(state.isPreparingForAiming)
    }

    @Test @MainActor
    func captureStartsOnlyAfterPreviewPublishesReady() {
        let state = ScannerSheetView.ScannerStateModel()
        state.captureRequestID = 7
        state.phase = .measured
        state.estimate = estimate(confidence: .high)
        state.prepareForAiming()

        state.startMeasurement()
        #expect(state.captureRequestID == 7)

        state.phase = .ready
        state.startMeasurement()

        #expect(state.captureRequestID == 8)
        #expect(!state.isPreparingForAiming)
    }

    @Test @MainActor
    func tappingVisibleStartImmediatelyShowsCaptureInProgress() {
        let state = ScannerSheetView.ScannerStateModel()
        state.captureRequestID = 7
        state.phase = .measured
        state.estimate = estimate(confidence: .high)
        state.prepareForAiming()
        state.phase = .ready

        state.startMeasurement()

        #expect(state.captureRequestID == 8)
        #expect(state.phase == .scanning(progress: 0))
    }

    @Test
    func retakeFlowUsesDistinctAimAndCaptureActions() {
        #expect(ScannerActionCopy.measureAgain == "Measure again")
        #expect(ScannerActionCopy.preparingPreview == "Returning to camera…")
        #expect(ScannerActionCopy.startMeasurement == "Take measurement")
    }

    @Test
    func startActionOnlyEnablesAfterScannerIsReady() {
        #expect(
            !ScannerActionPolicy.canStartMeasurement(phase: .checkingSupport)
        )
        #expect(
            !ScannerActionPolicy.canStartMeasurement(phase: .scanning(progress: 0))
        )
        #expect(ScannerActionPolicy.canStartMeasurement(phase: .ready))
        #expect(ScannerActionCopy.checkingSupport == "Checking LiDAR support…")
    }

    @Test
    func usableCaptureCanSaveImmediatelyWhenEvidenceIsStrong() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: estimate(confidence: .high)
        )

        #expect(state == .accepted)
        #expect(state.canSave)
    }

    @Test
    func measuredPhaseWithoutEstimateRequiresRetry() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: nil
        )

        #expect(
            state == .retryRequired(
                ScannerGuidanceCopy.missingEstimateRetry
            )
        )
        #expect(!state.canSave)
    }

    private func estimate(confidence: ScanConfidence) -> MeasurementEstimate {
        MeasurementEstimate(
            lengthMeters: 0.6,
            widthMeters: 0.4,
            heightMeters: 0.5,
            confidence: confidence,
            sampleCount: 800,
            frameCount: 10
        )
    }
}
