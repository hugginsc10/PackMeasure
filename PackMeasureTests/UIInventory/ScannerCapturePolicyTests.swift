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
    func cameraGuidanceIsShortAndUsesEverydayLanguage() {
        #expect(
            ScannerGuidanceCopy.previewTarget
                == "Fit one object inside the frame"
        )
        #expect(
            ScannerGuidanceCopy.setup
                == "Keep the whole object visible, then take a photo."
        )

        let primaryCopy = [
            ScannerGuidanceCopy.previewTarget,
            ScannerGuidanceCopy.setup,
            ScannerActionCopy.startMeasurement,
        ].joined(separator: " ")

        for technicalTerm in ["target", "dot", "face", "point-cloud", "LiDAR"] {
            #expect(!primaryCopy.localizedCaseInsensitiveContains(technicalTerm))
        }
    }

    @Test
    func genericRetryCopyDescribesResultWithoutBlamingUser() {
        #expect(
            ScannerGuidanceCopy.lowConfidenceRetry
                == "We couldn't get clear dimensions from this photo. Keep one object fully visible and try again."
        )
        #expect(
            ScannerGuidanceCopy.missingEstimateRetry
                == "We couldn't measure this photo. Keep one object fully visible and try again."
        )
    }

    @Test
    func measuredDimensionsAreExplicitlyLabeledAsAnEstimate() {
        #expect(ScannerResultCopy.sizeSectionTitle == "Estimated dimensions")
    }

    @Test
    func scanQualitySummaryDoesNotClaimMeasurementAccuracy() {
        let summary = ScannerResultCopy.qualitySummary(
            for: estimate(confidence: .high)
        )

        #expect(summary == "High scan quality")
        #expect(!summary.localizedCaseInsensitiveContains("confidence"))
        #expect(!summary.localizedCaseInsensitiveContains("accuracy"))
        #expect(!summary.localizedCaseInsensitiveContains("point-cloud"))
        #expect(!summary.localizedCaseInsensitiveContains("points"))
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
    func failedPhotoReturnsToLivePreviewWithoutStartingCapture() {
        let state = ScannerSheetView.ScannerStateModel()
        state.captureRequestID = 7
        state.phase = .failed("No clear object")

        state.prepareForAiming()

        #expect(state.estimate == nil)
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
        #expect(ScannerActionCopy.measureAgain == "Retake photo")
        #expect(ScannerActionCopy.retryPhoto == "Retake photo")
        #expect(ScannerActionCopy.preparingPreview == "Opening camera…")
        #expect(ScannerActionCopy.startMeasurement == "Take photo")
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
        #expect(ScannerActionCopy.checkingSupport == "Starting camera…")
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
