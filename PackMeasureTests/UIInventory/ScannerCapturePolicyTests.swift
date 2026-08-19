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
                "Scan rejected: the object was not separated clearly enough. Keep the target on the object—not the floor or wall—and scan again."
            )
        )
        #expect(!state.canSave)
    }

    @Test
    func scannerRejectionWinsEvenIfAStaleEstimateExists() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .failed("No centered object was detected."),
            estimate: estimate(confidence: .high),
            targetConfirmed: true
        )

        #expect(state == .retryRequired("No centered object was detected."))
        #expect(!state.canSave)
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
                "No valid object measurement was produced. Center the target on the object and scan again."
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
