import CoreGraphics
import Testing
@testable import PackMeasure

@Suite("Build 33 scanner presentation")
struct Build33ScannerPresentationTests {
    @Test
    func automaticCaptureRequiresASelectedTargetAndExplainsReacquisition() {
        let needsSelection = ScannerBuild33RuntimePolicy.automaticCapture(
            hasTarget: false,
            ownsAcceptedEvidence: false,
            canCapture: false,
            validationMessage: nil
        )
        #expect(needsSelection.actionTitle == "Select item")
        #expect(needsSelection.guidance == "Tap the item you want to measure.")
        #expect(!needsSelection.canCapture)

        let selected = ScannerBuild33RuntimePolicy.automaticCapture(
            hasTarget: true,
            ownsAcceptedEvidence: false,
            canCapture: true,
            validationMessage: nil
        )
        #expect(selected.actionTitle == "Take photo")
        #expect(selected.targetStatus == "Item selected")
        #expect(selected.canCapture)

        let reacquiring = ScannerBuild33RuntimePolicy.automaticCapture(
            hasTarget: true,
            ownsAcceptedEvidence: true,
            canCapture: false,
            validationMessage: "Move until the same selected item is clearly visible."
        )
        #expect(reacquiring.actionTitle == "Take photo")
        #expect(reacquiring.targetStatus == "Same selected item locked")
        #expect(
            reacquiring.guidance
                == "Move until the same selected item is clearly visible."
        )
        #expect(!reacquiring.canCapture)
    }

    @Test
    func guidedEntryCopyReflectsWhetherPhotoEvidenceWillBeReplaced() {
        #expect(
            ScannerBuild33RuntimePolicy.guidedEntrySituation(
                automaticAngleCount: 0,
                automaticCaptureFailed: false
            ) == .setup
        )
        #expect(
            ScannerBuild33RuntimePolicy.guidedEntrySituation(
                automaticAngleCount: 0,
                automaticCaptureFailed: true
            ) == .automaticFailure
        )
        #expect(
            ScannerBuild33RuntimePolicy.guidedEntrySituation(
                automaticAngleCount: 1,
                automaticCaptureFailed: true
            ) == .replaceAcceptedPhotoAngles
        )
    }

    @Test
    func guidedMeasurementUsesGuidedEvidenceReviewInsteadOfPhotoConsensus() {
        let estimate = MeasurementEstimate(
            lengthMeters: 0.6,
            widthMeters: 0.4,
            heightMeters: 0.3,
            confidence: .medium,
            sampleCount: 4,
            frameCount: 4
        )

        let guidedReview = ScannerBuild33RuntimePolicy.reviewState(
            phase: .measured,
            estimate: estimate,
            measurementProgress: .awaitingFirstAngle,
            subject: .box,
            mode: .guidedCorners
        )
        #expect(guidedReview == .accepted)
        #expect(guidedReview.canSave)

        let automaticReview = ScannerBuild33RuntimePolicy.reviewState(
            phase: .measured,
            estimate: estimate,
            measurementProgress: .awaitingFirstAngle,
            subject: .box,
            mode: .automaticPhotos
        )
        #expect(!automaticReview.canSave)

        let invalidGuidedGeneralItem = ScannerBuild33RuntimePolicy.reviewState(
            phase: .measured,
            estimate: estimate,
            measurementProgress: .awaitingFirstAngle,
            subject: .generalItem,
            mode: .guidedCorners
        )
        #expect(!invalidGuidedGeneralItem.canSave)
    }

    @Test
    func modeSelectionDefaultsToBoxPhotosAndRejectsGuidedGeneralItems() {
        var selection = ScannerModeSelection()

        #expect(selection.subject == .box)
        #expect(selection.mode == .automaticPhotos)
        let selectedGuidedMode = selection.selectMode(.guidedCorners)
        #expect(selectedGuidedMode)
        #expect(selection.mode == .guidedCorners)

        let selectedGeneralItem = selection.selectSubject(.generalItem)
        #expect(selectedGeneralItem)
        #expect(selection.subject == .generalItem)
        #expect(selection.mode == .automaticPhotos)
        let rejectedGuidedMode = selection.selectMode(.guidedCorners)
        #expect(!rejectedGuidedMode)
        #expect(selection.mode == .automaticPhotos)
    }

    @Test
    func invalidInitialGeneralItemGuidedPairNormalizesToPhotos() {
        let selection = ScannerModeSelection(
            subject: .generalItem,
            mode: .guidedCorners
        )

        #expect(selection.subject == .generalItem)
        #expect(selection.mode == .automaticPhotos)
    }

    @Test
    func guidedEntryUsesTheEstablishedSetupRetryAndReplacementCopy() {
        let setup = ScannerGuidedEntryPresentation.presentation(for: .setup)
        let retry = ScannerGuidedEntryPresentation.presentation(
            for: .automaticFailure
        )
        let restart = ScannerGuidedEntryPresentation.presentation(
            for: .replaceAcceptedPhotoAngles
        )

        #expect(setup.actionTitle == ScannerCrowdedSceneCopy.enterGuidedAction)
        #expect(setup.supportingNote == ScannerCrowdedSceneCopy.setupNote)
        #expect(!setup.replacesAutomaticEvidence)
        #expect(retry.actionTitle == ScannerCrowdedSceneCopy.retryWithGuidedAction)
        #expect(retry.supportingNote == ScannerCrowdedSceneCopy.setupNote)
        #expect(!retry.replacesAutomaticEvidence)
        #expect(restart.actionTitle == ScannerCrowdedSceneCopy.restartWithGuidedAction)
        #expect(restart.supportingNote == ScannerCrowdedSceneCopy.restartReplacementNote)
        #expect(restart.replacesAutomaticEvidence)
    }

    @Test
    func targetStatusUsesAcceptedEvidenceToDistinguishSelectedFromLocked() {
        #expect(
            ScannerTargetStatusPresentation.text(ownsAcceptedEvidence: false)
                == ScannerCrowdedSceneCopy.targetStatus(ownsAcceptedEvidence: false)
        )
        #expect(
            ScannerTargetStatusPresentation.text(ownsAcceptedEvidence: true)
                == ScannerCrowdedSceneCopy.targetStatus(ownsAcceptedEvidence: true)
        )
    }

    @Test(arguments: [
        (GuidedBoxWorkflowStep.referenceCorner, "1. Reference corner: place the reticle on one visible box corner."),
        (GuidedBoxWorkflowStep.lengthEndpoint, "2. Length endpoint: place the reticle at the other end of the length edge."),
        (GuidedBoxWorkflowStep.widthEndpoint, "3. Width endpoint: place the reticle at the other end of the width edge."),
        (GuidedBoxWorkflowStep.heightEndpoint, "4. Height endpoint: place the reticle at the other end of the vertical edge."),
    ])
    func guidedCaptureUsesOneExplicitPromptPerPoint(
        step: GuidedBoxWorkflowStep,
        expectedPrompt: String
    ) {
        let presentation = ScannerGuidedCapturePresentation(step: step)

        #expect(presentation.prompt == expectedPrompt)
        #expect(presentation.actions.contains(.takePoint))
        #expect(!presentation.actions.contains(.confirm))
    }

    @Test
    func guidedReviewOffersBackAndConfirmInsteadOfAnotherPoint() {
        let presentation = ScannerGuidedCapturePresentation(step: .review)

        #expect(presentation.prompt == "Review the four points, then confirm the dimensions.")
        #expect(presentation.actions == [.back, .confirm])
        #expect(presentation.feedbackMessage == nil)
        #expect(presentation.replacementPoint == nil)
    }

    @Test
    func replacementStateNamesThePointAndKeepsTheErrorVisible() {
        let presentation = ScannerGuidedCapturePresentation(
            step: .heightEndpoint,
            feedback: .replacement(
                point: .heightEndpoint,
                message: "Retap the height point along a vertical edge."
            )
        )

        #expect(presentation.prompt.hasPrefix("4. Height endpoint:"))
        #expect(
            presentation.feedbackMessage
                == "Retap the height point along a vertical edge."
        )
        #expect(presentation.replacementPoint == .heightEndpoint)
        #expect(presentation.actions == [.back, .takePoint])
    }

    @Test
    func nonReplacementErrorStaysVisibleWithoutChangingTheCurrentStep() {
        let presentation = ScannerGuidedCapturePresentation(
            step: .widthEndpoint,
            feedback: .error("Hold still while LiDAR finds the point.")
        )

        #expect(presentation.prompt.hasPrefix("3. Width endpoint:"))
        #expect(presentation.feedbackMessage == "Hold still while LiDAR finds the point.")
        #expect(presentation.replacementPoint == nil)
        #expect(presentation.actions == [.back, .takePoint])
    }

    @Test
    func evidencePresentationNeverCrossesAutomaticAndGuidedModes() {
        #expect(
            ScannerEvidencePresentationPolicy.presentation(
                for: .automaticPhoto,
                subject: .box,
                mode: .automaticPhotos
            ) == .automaticPhotoAngles
        )
        #expect(
            ScannerEvidencePresentationPolicy.presentation(
                for: .guidedLidarCorners,
                subject: .box,
                mode: .guidedCorners
            ) == .guidedBoxMeasurement
        )
        #expect(
            ScannerEvidencePresentationPolicy.presentation(
                for: .automaticPhoto,
                subject: .box,
                mode: .guidedCorners
            ) == nil
        )
        #expect(
            ScannerEvidencePresentationPolicy.presentation(
                for: .guidedLidarCorners,
                subject: .box,
                mode: .automaticPhotos
            ) == nil
        )
        #expect(
            ScannerEvidencePresentationPolicy.presentation(
                for: .guidedLidarCorners,
                subject: .generalItem,
                mode: .guidedCorners
            ) == nil
        )
    }

    @Test
    func projectedOverlayOrdersMarkersAndDrawsEveryLineFromReference() throws {
        let reference = try #require(
            ScannerNormalizedPreviewPoint(x: 0.25, y: 0.75)
        )
        let length = try #require(
            ScannerNormalizedPreviewPoint(x: 0.75, y: 0.75)
        )
        let width = try #require(
            ScannerNormalizedPreviewPoint(x: 0.20, y: 0.35)
        )
        let height = try #require(
            ScannerNormalizedPreviewPoint(x: 0.25, y: 0.20)
        )
        let overlay = GuidedBoxProjectedOverlay(projectedPoints: [
            GuidedBoxProjectedPoint(point: .heightEndpoint, position: height),
            GuidedBoxProjectedPoint(point: .widthEndpoint, position: width),
            GuidedBoxProjectedPoint(point: .referenceCorner, position: reference),
            GuidedBoxProjectedPoint(point: .lengthEndpoint, position: length),
        ])

        #expect(overlay.markers.map(\.number) == [1, 2, 3, 4])
        #expect(overlay.referenceLines.count == 3)
        #expect(
            overlay.referenceLines.allSatisfy {
                $0.reference.point == .referenceCorner
            }
        )
        #expect(
            overlay.referenceLines.map(\.endpoint.point)
                == [.lengthEndpoint, .widthEndpoint, .heightEndpoint]
        )
    }

    @Test
    func normalizedOverlayRejectsOffscreenAndNonFiniteCoordinates() {
        #expect(ScannerNormalizedPreviewPoint(x: -0.001, y: 0.5) == nil)
        #expect(ScannerNormalizedPreviewPoint(x: 0.5, y: 1.001) == nil)
        #expect(ScannerNormalizedPreviewPoint(x: .nan, y: 0.5) == nil)
        #expect(ScannerNormalizedPreviewPoint(x: 0.5, y: .infinity) == nil)
        #expect(ScannerNormalizedPreviewPoint(x: 0, y: 1) != nil)
    }

    @Test
    func controlsPublishStableAccessibilityIDsAndMinimumHitTarget() {
        #expect(ScannerBuild33Layout.minimumHitTarget == 44)
        #expect(ScannerBuild33AccessibilityID.subjectBox == "scanner.subject.box")
        #expect(
            ScannerBuild33AccessibilityID.subjectGeneralItem
                == "scanner.subject.general-item"
        )
        #expect(
            ScannerBuild33AccessibilityID.modeAutomaticPhotos
                == "scanner.mode.automatic-photos"
        )
        #expect(
            ScannerBuild33AccessibilityID.modeGuidedCorners
                == "scanner.mode.guided-four-points"
        )
        #expect(
            ScannerBuild33AccessibilityID.guidedAction(.back)
                == "scanner.guided.back"
        )
        #expect(
            ScannerBuild33AccessibilityID.guidedAction(.takePoint)
                == "scanner.guided.take-point"
        )
        #expect(
            ScannerBuild33AccessibilityID.guidedAction(.confirm)
                == "scanner.guided.confirm"
        )
        #expect(
            ScannerBuild33AccessibilityID.guidedMarker(number: 3)
                == "scanner.guided.marker.3"
        )
    }

    @Test
    func allNewPresentationCopyAvoidsForbiddenClearSpaceDirections() {
        let copy = [
            ScannerGuidedEntryPresentation.presentation(for: .setup).actionTitle,
            ScannerGuidedEntryPresentation.presentation(for: .setup).supportingNote,
            ScannerGuidedEntryPresentation.presentation(for: .automaticFailure).actionTitle,
            ScannerGuidedEntryPresentation.presentation(for: .replaceAcceptedPhotoAngles).actionTitle,
            ScannerGuidedEntryPresentation.presentation(for: .replaceAcceptedPhotoAngles).supportingNote,
            ScannerTargetStatusPresentation.text(ownsAcceptedEvidence: false),
            ScannerTargetStatusPresentation.text(ownsAcceptedEvidence: true),
            ScannerGuidedCapturePresentation(step: .referenceCorner).prompt,
            ScannerGuidedCapturePresentation(step: .lengthEndpoint).prompt,
            ScannerGuidedCapturePresentation(step: .widthEndpoint).prompt,
            ScannerGuidedCapturePresentation(step: .heightEndpoint).prompt,
            ScannerGuidedCapturePresentation(step: .review).prompt,
        ].compactMap { $0 }
        let prohibited = [
            "plain wall",
            "space around",
            "open space",
            "contrasting background",
            "one whole object",
            "one clear object",
        ]

        for text in copy {
            for phrase in prohibited {
                #expect(!text.localizedCaseInsensitiveContains(phrase))
            }
        }
    }
}
