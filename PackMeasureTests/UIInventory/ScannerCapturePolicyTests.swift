import Testing
@testable import PackMeasure

@Suite("Scanner capture review policy")
struct ScannerCapturePolicyTests {
    @Test
    func lowConfidenceCaptureRequiresVisibleRetryAndCannotSave() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: estimate(confidence: .low),
            targetConfirmed: true
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
            "The measurement could not isolate the object from its surroundings. Keep the object centered with clear edges and scan again."
        let state = ScannerCapturePolicy.reviewState(
            phase: .failed(scannerDiagnostic),
            estimate: estimate(confidence: .high),
            targetConfirmed: true
        )

        #expect(state == .retryRequired(scannerDiagnostic))
        #expect(!state.canSave)
    }

    @Test
    func guidanceAllowsAnyClearObjectFaceAndSeparatesBackground() {
        #expect(
            ScannerGuidanceCopy.previewTarget
                == "Put center dot on a clear object face — keep floor and background outside the object"
        )
        #expect(
            ScannerGuidanceCopy.setup
                == "Stand at a 3/4 angle so the front, side, and top are visible. Put the whole object inside the yellow frame, place the center dot on a clear object face, and keep visible floor or background around the object's edges."
        )
        #expect(
            ScannerGuidanceCopy.targetConfirmation
                == "Center dot stayed on a clear object face"
        )
    }

    @Test
    func genericRetryCopyDescribesResultWithoutBlamingUser() {
        #expect(
            ScannerGuidanceCopy.lowConfidenceRetry
                == "This scan could not isolate a reliable object measurement. Keep the object inside the frame, put the center dot on a clear object face, and scan again."
        )
        #expect(
            ScannerGuidanceCopy.missingEstimateRetry
                == "No object measurement was produced. Keep the object inside the frame, put the center dot on a clear object face, and scan again."
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

    @Test
    func usableCaptureCannotSaveUntilUserConfirmsTargetStayedOnObject() {
        let unconfirmed = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: estimate(confidence: .high),
            targetConfirmed: false
        )
        let confirmed = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: estimate(confidence: .high),
            targetConfirmed: true
        )

        #expect(unconfirmed == .confirmTarget)
        #expect(!unconfirmed.canSave)
        #expect(confirmed == .accepted)
        #expect(confirmed.canSave)
    }

    @Test
    func measuredPhaseWithoutEstimateRequiresRetry() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: nil,
            targetConfirmed: true
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
