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
            "The center target was on a horizontal surface. Aim at the object's front or side face and scan again."
        let state = ScannerCapturePolicy.reviewState(
            phase: .failed(scannerDiagnostic),
            estimate: estimate(confidence: .high),
            targetConfirmed: true
        )

        #expect(state == .retryRequired(scannerDiagnostic))
        #expect(!state.canSave)
    }

    @Test
    func guidanceKeepsTopVisibleButTargetsOnlyVerticalFace() {
        #expect(
            ScannerGuidanceCopy.previewTarget
                == "Aim center dot at a vertical front or side face — not the top, floor, or wall"
        )
        #expect(
            ScannerGuidanceCopy.setup
                == "Stand at a 3/4 angle so the front, side, and top are visible. Put the whole object inside the yellow frame, then place the center dot on a vertical front or side face. Do not aim at the horizontal top."
        )
        #expect(
            ScannerGuidanceCopy.targetConfirmation
                == "Center dot stayed on a vertical front or side face"
        )
    }

    @Test
    func genericRetryCopyDescribesResultWithoutBlamingUser() {
        #expect(
            ScannerGuidanceCopy.lowConfidenceRetry
                == "This scan did not produce a reliable object measurement. Aim the center dot at a vertical front or side face and scan again."
        )
        #expect(
            ScannerGuidanceCopy.missingEstimateRetry
                == "No object measurement was produced. Aim the center dot at a vertical front or side face and scan again."
        )
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
