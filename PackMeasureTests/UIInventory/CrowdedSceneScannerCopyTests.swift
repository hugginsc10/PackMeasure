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
            .photo(.maskTouchesImageEdge(stage: .sourceMask)),
            .photo(
                .multipleRigidItemsDetected(
                    PhotoRigidItemMultiplicityEvaluation(
                        assessment: .multipleRigidItems(
                            PhotoRigidItemMultiplicityEvidence(
                                splitHeightFraction: 0.5,
                                maximumBoundaryShiftMeters: 0.1,
                                normalizedBoundaryShift: 0.2,
                                significantBoundaryCount: 2
                            )
                        ),
                        finitePointCount: 256,
                        minimumPointCount: 160,
                        usableBinCount: 20,
                        comparableSplitCount: 4,
                        indeterminateReason: nil
                    )
                )
            ),
            .photo(
                .rigidItemMultiplicityUncertain(
                    PhotoRigidItemMultiplicityEvaluation(
                        assessment: .insufficientEvidence,
                        finitePointCount: 160,
                        minimumPointCount: 160,
                        usableBinCount: 6,
                        comparableSplitCount: 0,
                        indeterminateReason: .noComparableSplit
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

    @Test
    func v02KeepsTheItemStillAndMovesTheCameraInstead() {
        let copy = ScannerPhotoFailureCopy.message(for: .foreground(.noObservation))

        #expect(copy.localizedCaseInsensitiveContains("keep the item still"))
        #expect(copy.localizedCaseInsensitiveContains("move the phone closer"))
        #expect(!copy.localizedCaseInsensitiveContains("move the item"))
        #expect(!copy.localizedCaseInsensitiveContains("clear the scene"))
    }

    @Test
    func f09GuidanceMatchesTheIndeterminateReason() {
        func message(
            for reason: PhotoRigidItemMultiplicityIndeterminateReason
        ) -> String {
            ScannerPhotoFailureCopy.message(
                for: .photo(
                    .rigidItemMultiplicityUncertain(
                        PhotoRigidItemMultiplicityEvaluation(
                            assessment: .insufficientEvidence,
                            finitePointCount: 320,
                            minimumPointCount: 160,
                            usableBinCount: 12,
                            comparableSplitCount: 6,
                            indeterminateReason: reason,
                            eligibleSplitCount: 14
                        )
                    )
                )
            )
        }

        let oneBoundary = message(for: .oneStrongBoundary)
        #expect(oneBoundary.localizedCaseInsensitiveContains("another box or an obstruction"))
        #expect(oneBoundary.localizedCaseInsensitiveContains("4 points"))

        let incomplete = message(for: .incompleteProfileCoverage)
        #expect(incomplete.localizedCaseInsensitiveContains("three-quarter angle"))
        #expect(incomplete.localizedCaseInsensitiveContains("4 points"))

        let tooSmall = message(for: .footprintBelowMinimum)
        #expect(tooSmall.localizedCaseInsensitiveContains("too small"))
        #expect(tooSmall.localizedCaseInsensitiveContains("4 points"))
        #expect(!tooSmall.localizedCaseInsensitiveContains("closer"))

        let flat = message(for: .degenerateVerticalSpan)
        #expect(flat.localizedCaseInsensitiveContains("flat face"))
        #expect(flat.localizedCaseInsensitiveContains("three-quarter angle"))
    }
}
