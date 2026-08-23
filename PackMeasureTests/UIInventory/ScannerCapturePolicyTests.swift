import Testing
import simd
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
    func photoFailureCopyReportsExactDepthCoverageAndDiagnosticCode() {
        let copy = ScannerPhotoFailureCopy.message(
            for: .photo(.insufficientDepthCoverage(actual: 0.42, minimum: 0.60))
        )

        #expect(copy.contains("42%"))
        #expect(copy.contains("60%"))
        #expect(copy.contains("Diagnostic D02"))
        #expect(!copy.localizedCaseInsensitiveContains("isolate one clear object"))
    }

    @Test
    func failedNearThresholdDoesNotRoundToEqualValues() {
        let copy = ScannerPhotoFailureCopy.message(
            for: .photo(.insufficientDepthCoverage(actual: 0.5996, minimum: 0.60))
        )

        #expect(copy.contains("59.9%"))
        #expect(copy.contains("needs 60%"))
        #expect(!copy.contains("covered 60%"))
    }

    @Test
    func supportSpanCopyDescribesPhotoAxesNotPhysicalDimensions() {
        let horizontal = ScannerPhotoFailureCopy.message(
            for: .photo(.insufficientHorizontalDepthSupport(actual: 0.51, minimum: 0.65))
        )
        let vertical = ScannerPhotoFailureCopy.message(
            for: .photo(.insufficientVerticalDepthSupport(actual: 0.49, minimum: 0.65))
        )

        #expect(horizontal.localizedCaseInsensitiveContains("horizontal span in the photo"))
        #expect(vertical.localizedCaseInsensitiveContains("vertical span in the photo"))
        #expect(!horizontal.localizedCaseInsensitiveContains("object's width"))
        #expect(!vertical.localizedCaseInsensitiveContains("object's height"))
    }

    @Test
    func foregroundAndFramingFailuresReceiveTruthfulDistinctCopy() {
        let foregroundCopy = ScannerPhotoFailureCopy.message(
            for: .foreground(.noObservation)
        )
        let framingCopy = ScannerPhotoFailureCopy.message(
            for: .photo(.maskTouchesImageEdge)
        )

        #expect(foregroundCopy.localizedCaseInsensitiveContains("didn't recognize"))
        #expect(foregroundCopy.contains("Diagnostic V02"))
        #expect(!foregroundCopy.localizedCaseInsensitiveContains("not enough object depth"))
        #expect(framingCopy.localizedCaseInsensitiveContains("edge"))
        #expect(framingCopy.contains("Diagnostic F05"))
    }

    @Test
    func f01FallbackFailureReportsTheAttemptInsteadOfBlamingFraming() {
        let trigger = SingleShotCaptureFailure.foreground(
            .photo(stage: .instanceSelection, error: .noForegroundInstance)
        )
        let unavailable = ScannerPhotoFailureCopy.message(
            for: trigger,
            fallbackResult: .unavailable
        )
        let rejected = ScannerPhotoFailureCopy.message(
            for: trigger,
            fallbackResult: .targetRejected(.insufficientSurfaceEvidence)
        )

        #expect(unavailable.localizedCaseInsensitiveContains("center-depth fallback"))
        #expect(unavailable.localizedCaseInsensitiveContains("wasn't ready"))
        #expect(rejected.localizedCaseInsensitiveContains("center-depth fallback"))
        #expect(rejected.localizedCaseInsensitiveContains("couldn't isolate enough"))
        #expect(unavailable.contains("Diagnostic F01"))
        #expect(rejected.contains("Diagnostic F01"))
        #expect(!unavailable.localizedCaseInsensitiveContains("contrasting background"))
        #expect(!rejected.localizedCaseInsensitiveContains("contrasting background"))
    }

    @Test
    func pipelineFailureDoesNotBlameObjectFraming() {
        let copy = ScannerPhotoFailureCopy.message(
            for: .unexpectedProcessingFailure(domain: "Test", code: 7)
        )

        #expect(copy.localizedCaseInsensitiveContains("couldn't process"))
        #expect(copy.contains("Diagnostic C03"))
        #expect(!copy.localizedCaseInsensitiveContains("whole object"))
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

    @Test
    func singlePhotoResultCopyDisclosesThePrecisionLimitation() {
        let summary = ScannerResultCopy.qualitySummary(
            for: estimate(confidence: .medium, frameCount: 1)
        )

        #expect(
            summary
                == "Approximate single-photo estimate — compare another angle for tight fits"
        )
        #expect(!summary.localizedCaseInsensitiveContains("high scan quality"))
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
    func measuredObjectOutlineIsStoredThenClearedBeforeLiveAiming() throws {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .scanning(progress: 0.5)
        let outline = try #require(
            MeasurementObjectOutline(
                width: 4,
                height: 4,
                selectedIndices: [5, 6, 9, 10]
            )
        )
        let overlay = MeasurementObjectOverlay(
            displayOrientedImageSize: SIMD2<Float>(3, 4),
            outline: outline
        )

        _ = state.receiveMeasurement(
            angleCapture(
                position: SIMD3<Float>(0, 0, 1),
                objectOverlay: overlay
            )
        )

        #expect(state.objectOverlay == overlay)
        #expect(state.capturedEstimates.count == 1)

        state.prepareForAiming()

        #expect(state.objectOverlay == nil)
        #expect(state.capturedEstimates.count == 1)
        #expect(state.isPreparingForAiming)
    }

    @Test @MainActor
    func restartingMeasurementSeriesClearsMeasuredObjectOutline() throws {
        let state = ScannerSheetView.ScannerStateModel()
        let outline = try #require(
            MeasurementObjectOutline(width: 2, height: 2, selectedIndices: [0])
        )
        _ = state.receiveMeasurement(
            angleCapture(
                position: SIMD3<Float>(0, 0, 1),
                objectOverlay: MeasurementObjectOverlay(
                    displayOrientedImageSize: SIMD2<Float>(3, 4),
                    outline: outline
                )
            )
        )

        state.resetMeasurementSeries()

        #expect(state.objectOverlay == nil)
        #expect(state.capturedEstimates.isEmpty)
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

        #expect(state.previewBecameReady())
        state.startMeasurement()

        #expect(state.captureRequestID == 8)
        #expect(!state.isPreparingForAiming)
    }

    @Test @MainActor
    func initialPreviewBecomesReadyOnlyThroughFrameReadinessPublication() {
        let state = ScannerSheetView.ScannerStateModel()

        #expect(state.phase == .checkingSupport)
        #expect(state.previewBecameReady())
        #expect(state.phase == .ready)
        #expect(!state.previewBecameReady())
    }

    @Test @MainActor
    func failedPreviewResumeStaysDisabledUntilFrameBecomesReady() {
        let state = ScannerSheetView.ScannerStateModel()
        state.phase = .failed("Retake")

        state.prepareForAiming()

        #expect(state.isPreparingForAiming)
        #expect(!state.canStartMeasurement)
        #expect(state.previewBecameReady())
        #expect(state.phase == .ready)
        #expect(!state.isPreparingForAiming)
        #expect(state.canStartMeasurement)
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

    @Test @MainActor
    func firstComparisonAngleDisablesSaveAndRequestsAnotherView() {
        let state = ScannerSheetView.ScannerStateModel()

        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(0, 0, 1))
        )

        #expect(state.phase == .measured)
        #expect(state.estimate == nil)
        #expect(state.capturedEstimates.count == 1)
        #expect(
            state.measurementProgress
                == .needsAnotherAngle(reason: .firstAngleCaptured, acceptedCount: 1)
        )
        let review = ScannerCapturePolicy.reviewState(
            phase: state.phase,
            estimate: state.estimate,
            measurementProgress: state.measurementProgress
        )
        #expect(
            review
                == .needsAnotherAngle(
                    ScannerGuidanceCopy.additionalAngleMessage(for: .firstAngleCaptured)
                )
        )
        #expect(!review.canSave)
    }

    @Test @MainActor
    func preparingNextAnglePreservesTheCurrentMeasurementSeries() {
        let state = ScannerSheetView.ScannerStateModel()
        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(0, 0, 1))
        )
        let seriesID = state.measurementSeriesID

        state.prepareForAiming()

        #expect(state.measurementSeriesID == seriesID)
        #expect(state.capturedEstimates.count == 1)
        #expect(
            state.measurementProgress
                == .needsAnotherAngle(reason: .firstAngleCaptured, acceptedCount: 1)
        )
        #expect(state.previewRequestID == 1)
        #expect(state.isPreparingForAiming)

        state.phase = .ready
        state.startMeasurement()

        #expect(state.measurementSeriesID == seriesID)
        #expect(state.capturedEstimates.count == 1)
        #expect(state.captureRequestID == 1)
    }

    @Test @MainActor
    func stationaryBoxLargeFitCenterDriftResolvesWithoutAlignmentRetryLoop() throws {
        let state = ScannerSheetView.ScannerStateModel()
        let first = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 5),
            position: SIMD3<Float>(0, 0, 1)
        )
        state.receiveMeasurement(first)
        let progress = state.receiveMeasurement(
            angleCapture(
                length: meters(fromInches: 16),
                width: meters(fromInches: 11),
                height: meters(fromInches: 5),
                center: SIMD3<Float>(2.5, -1.5, 3.0),
                position: SIMD3<Float>(1, 0, 0)
            )
        )

        guard case .accepted(let consensus) = progress else {
            Issue.record("expected stationary box views to resolve without an alignment retry")
            return
        }
        #expect(state.capturedEstimates.count == 2)
        #expect(state.estimate == consensus)
        #expect(consensus.lengthMeters == meters(fromInches: 16))
        #expect(consensus.widthMeters == meters(fromInches: 11))
        #expect(consensus.heightMeters == meters(fromInches: 5))
        #expect(
            ScannerCapturePolicy.reviewState(
                phase: state.phase,
                estimate: state.estimate,
                measurementProgress: state.measurementProgress
            ) == .accepted
        )
    }

    @Test @MainActor
    func lowConfidenceRetryDoesNotConsumeStagedAngleAndLaterGoodViewResolves() {
        let state = ScannerSheetView.ScannerStateModel()
        let first = angleCapture(position: SIMD3<Float>(0, 0, 1))
        state.receiveMeasurement(first)
        let seriesID = state.measurementSeriesID
        let lowConfidenceRetry = angleCapture(
            pointCloudConfidence: .low,
            position: SIMD3<Float>(1, 0, 0)
        )

        let retryProgress = state.receiveMeasurement(lowConfidenceRetry)

        #expect(
            retryProgress
                == .needsAnotherAngle(reason: .firstAngleCaptured, acceptedCount: 1)
        )
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.capturedEstimates == [first.evidence.estimate])
        #expect(state.estimate == lowConfidenceRetry.evidence.estimate)
        #expect(
            ScannerCapturePolicy.reviewState(
                phase: state.phase,
                estimate: state.estimate,
                measurementProgress: state.measurementProgress
            ) == .retryRequired(ScannerGuidanceCopy.lowConfidenceRetry)
        )

        state.prepareForAiming()
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.capturedEstimates == [first.evidence.estimate])

        state.phase = .ready
        state.startMeasurement()
        let resolvedProgress = state.receiveMeasurement(
            angleCapture(
                length: 0.61,
                width: 0.41,
                height: 0.51,
                position: SIMD3<Float>(1, 0, 0)
            )
        )

        guard case .accepted(let consensus) = resolvedProgress else {
            Issue.record("expected a good retry from the distinct view to resolve")
            return
        }
        #expect(state.measurementSeriesID == seriesID)
        #expect(state.capturedEstimates.count == 2)
        #expect(state.estimate == consensus)
        #expect(consensus.comparisonAngleCount == 2)
        #expect(consensus.comparisonAgreementCount == 2)
    }

    @Test @MainActor
    func acceptedMultiAngleConsensusEnablesSaving() throws {
        let state = ScannerSheetView.ScannerStateModel()
        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(0, 0, 1))
        )
        state.receiveMeasurement(
            angleCapture(
                length: 0.61,
                width: 0.41,
                height: 0.51,
                position: SIMD3<Float>(1, 0, 0)
            )
        )

        guard case .accepted(let consensus) = state.measurementProgress else {
            Issue.record("expected accepted scanner consensus")
            return
        }
        #expect(state.estimate == consensus)
        let review = ScannerCapturePolicy.reviewState(
            phase: state.phase,
            estimate: state.estimate,
            measurementProgress: state.measurementProgress
        )
        #expect(review == .accepted)
        #expect(review.canSave)
    }

    @Test @MainActor
    func restartingAnInconsistentConsensusClearsCapturesAndIncrementsSeries() {
        let state = ScannerSheetView.ScannerStateModel()
        state.receiveMeasurement(
            angleCapture(
                length: 0.50,
                width: 0.30,
                height: 0.40,
                position: SIMD3<Float>(0, 0, 1)
            )
        )
        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(1, 0, 0))
        )
        state.receiveMeasurement(
            angleCapture(
                length: 0.70,
                width: 0.50,
                height: 0.60,
                position: SIMD3<Float>(0, 0, -1)
            )
        )
        #expect(state.measurementProgress == .inconsistent(.dimensionsInconsistent))
        #expect(state.capturedEstimates.count == 3)
        let previousSeriesID = state.measurementSeriesID

        state.prepareForAiming()

        #expect(state.measurementSeriesID == previousSeriesID + 1)
        #expect(state.measurementProgress == .awaitingFirstAngle)
        #expect(state.capturedEstimates.isEmpty)
        #expect(state.estimate == nil)
        #expect(state.isPreparingForAiming)
        #expect(state.previewRequestID == 1)
    }

    @Test @MainActor
    func resettingMeasurementSeriesClearsStagedCaptureAndIncrementsSeries() {
        let state = ScannerSheetView.ScannerStateModel()
        state.receiveMeasurement(
            angleCapture(position: SIMD3<Float>(0, 0, 1))
        )
        let previousSeriesID = state.measurementSeriesID
        #expect(state.capturedEstimates.count == 1)

        state.resetMeasurementSeries()

        #expect(state.measurementSeriesID == previousSeriesID + 1)
        #expect(state.measurementProgress == .awaitingFirstAngle)
        #expect(state.capturedEstimates.isEmpty)
        #expect(state.estimate == nil)
        #expect(!state.isPreparingForAiming)
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
    func approximateSinglePhotoEstimateRemainsSaveable() {
        let state = ScannerCapturePolicy.reviewState(
            phase: .measured,
            estimate: estimate(confidence: .medium, frameCount: 1)
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

    private func estimate(
        confidence: ScanConfidence,
        frameCount: Int = 10
    ) -> MeasurementEstimate {
        MeasurementEstimate(
            lengthMeters: 0.6,
            widthMeters: 0.4,
            heightMeters: 0.5,
            confidence: confidence,
            sampleCount: 800,
            frameCount: frameCount
        )
    }

    private func angleCapture(
        length: Double = 0.60,
        width: Double = 0.40,
        height: Double = 0.50,
        pointCloudConfidence: ScanConfidence = .high,
        center: SIMD3<Float> = .zero,
        position: SIMD3<Float>,
        horizontalForward: SIMD2<Float>? = nil,
        objectOverlay: MeasurementObjectOverlay? = nil
    ) -> MeasurementAngleCapture {
        let derivedForward = SIMD2<Float>(-position.x, -position.z)
        let resolvedForward: SIMD2<Float>
        if let horizontalForward {
            resolvedForward = horizontalForward
        } else if simd_length(derivedForward) > 0.0001 {
            resolvedForward = simd_normalize(derivedForward)
        } else {
            resolvedForward = SIMD2<Float>(0, -1)
        }

        return MeasurementAngleCapture(
            evidence: MeasurementCaptureEvidence(
                estimate: MeasurementEstimate(
                    lengthMeters: length,
                    widthMeters: width,
                    heightMeters: height,
                    confidence: pointCloudConfidence == .high ? .medium : pointCloudConfidence,
                    sampleCount: 800,
                    frameCount: 1
                ),
                pointCloudConfidence: pointCloudConfidence,
                geometryCenter: center
            ),
            viewpoint: MeasurementCameraViewpoint(
                position: position,
                horizontalForward: resolvedForward
            ),
            objectOverlay: objectOverlay
        )
    }

    private func meters(fromInches inches: Double) -> Double {
        inches * 0.0254
    }
}
