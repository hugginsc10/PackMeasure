import Testing
@testable import PackMeasure

@Suite("Crowded-scene scanner copy")
struct CrowdedSceneScannerCopyTests {
    @Test
    func boxGuidanceMakesTheNoClearSpaceContractExplicit() {
        #expect(
            ScannerCrowdedSceneCopy.setupNote
                == "No clear space needed; nearby items may touch the box."
        )
        #expect(ScannerCrowdedSceneCopy.enterGuidedAction == "Crowded box? Measure with 4 points")
        #expect(ScannerCrowdedSceneCopy.retryWithGuidedAction == "Use 4 points instead")
        #expect(ScannerCrowdedSceneCopy.restartWithGuidedAction == "Restart with 4 points")
        #expect(
            ScannerCrowdedSceneCopy.restartReplacementNote
                == "Replaces saved photo angles. No clear space needed."
        )
    }

    @Test
    func selectedLanguageStaysScopedToTheCurrentAngle() {
        #expect(
            ScannerCrowdedSceneCopy.targetStatus(ownsAcceptedEvidence: false)
                == "Item selected for this angle"
        )
        #expect(
            ScannerCrowdedSceneCopy.targetStatus(ownsAcceptedEvidence: true)
                == "Item captured for this angle"
        )
    }

    @Test
    func reachableBoxFailureCopyNeverDemandsAnEmptyScene() {
        let failures: [SingleShotCaptureFailure] = [
            .foreground(.noObservation),
            .foreground(
                .photo(stage: .instanceSelection, error: .noForegroundInstance)
            ),
            .targetSelection(.noForegroundAtTargetPoint),
            .photo(.ambiguousForegroundInstances(labels: [1, 2])),
            .photo(.noReticleDepthSurface),
            .photo(.maskAreaTooSmall(actual: 0.01, minimum: 0.03)),
            .photo(.maskAreaTooLarge(actual: 0.90, maximum: 0.85)),
            .photo(.maskTouchesImageEdge),
            .photo(
                .multipleRigidItemsDetected(
                    PhotoRigidItemMultiplicityEvidence(
                        splitHeightFraction: 0.5,
                        maximumBoundaryShiftMeters: 0.1,
                        normalizedBoundaryShift: 0.2,
                        significantBoundaryCount: 2
                    )
                )
            ),
        ]
        let prohibited = [
            "plain wall",
            "space around",
            "open space",
            "contrasting background",
            "one whole object",
            "one clear object",
        ]

        for failure in failures {
            let copy = ScannerPhotoFailureCopy.message(for: failure)
            for phrase in prohibited {
                #expect(
                    !copy.localizedCaseInsensitiveContains(phrase),
                    "Reachable copy unexpectedly contained \(phrase): \(copy)"
                )
            }
        }
    }
}
