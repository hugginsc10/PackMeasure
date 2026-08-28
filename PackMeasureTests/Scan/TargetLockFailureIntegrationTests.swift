import Testing
@testable import PackMeasure

@Suite("Target-lock scanner failure integration")
struct TargetLockFailureIntegrationTests {
    @Test
    func everyExactFrameTargetRejectionFailsClosedAsT03() {
        for reason in TargetLockFrameValidationFailure.allCases {
            let failure = SingleShotCaptureFailure.targetLock(reason)

            #expect(failure.retryCategory == .isolation)
            #expect(failure.disposition == .targetRejected)
            #expect(failure.diagnosticCode == "T03")
            #expect(!failure.shouldAttemptReticleDepthFallback)
            #expect(failure.diagnosticDescription.contains("target_lock_frame_rejected"))
            #expect(failure.diagnosticDescription.contains(String(describing: reason)))
        }
    }

    @Test
    func exactFrameTargetCopyUsesTheValidatorRecoveryAction() {
        for reason in TargetLockFrameValidationFailure.allCases {
            let copy = ScannerPhotoFailureCopy.message(
                for: .targetLock(reason)
            )

            #expect(copy == "\(reason.actionMessage) Diagnostic T03.")
            #expect(!copy.localizedCaseInsensitiveContains("center-depth fallback"))
        }
    }
}
