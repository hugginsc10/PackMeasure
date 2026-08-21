import Testing
import simd
@testable import PackMeasure

struct MeasurementEstimatorTests {
    @Test
    func finalizedMeasurementFreezesPreviewUntilNextScan() {
        var lifecycle = ScannerPreviewLifecycle()

        #expect(lifecycle.measurementFinalized() == .pause)
        #expect(lifecycle.isFrozen)
        #expect(lifecycle.measurementFinalized() == .none)

        #expect(lifecycle.scanRequested() == .resume)
        #expect(!lifecycle.isFrozen)
    }

    @Test
    func scanRequestDoesNotRestartSessionWhilePreviewIsAlreadyLive() {
        var lifecycle = ScannerPreviewLifecycle()

        #expect(lifecycle.scanRequested() == .none)
        #expect(!lifecycle.isFrozen)
    }

    @Test
    func previewAndCaptureRequestsRouteAsSeparateLifecycleCommands() {
        var tracker = ScannerViewRequestTracker()

        #expect(
            tracker.commands(previewRequestID: 0, captureRequestID: 0).isEmpty
        )
        #expect(
            tracker.commands(previewRequestID: 1, captureRequestID: 0)
                == [.resumePreview]
        )
        #expect(
            tracker.commands(previewRequestID: 1, captureRequestID: 1)
                == [.startCapture]
        )
    }

    @Test
    func frameImmediatelyAfterTapIsIgnoredUntilCameraSettles() {
        let policy = SettledFrameCapturePolicy(settleInterval: 0.25)

        #expect(!policy.shouldCapture(requestedAt: 100, frameArrivedAt: 100.01))
        #expect(!policy.shouldCapture(requestedAt: 100, frameArrivedAt: 100.249))
        #expect(
            abs(policy.progress(requestedAt: 100, frameArrivedAt: 100.125) - 0.225)
                < 0.0001
        )
    }

    @Test
    func firstFrameAtOrAfterSettleIntervalCanBeCaptured() {
        let policy = SettledFrameCapturePolicy(settleInterval: 0.25)

        #expect(policy.shouldCapture(requestedAt: 100, frameArrivedAt: 100.25))
        #expect(policy.shouldCapture(requestedAt: 100, frameArrivedAt: 100.32))
    }

    @Test
    func settledFrameGateWaitsThenConsumesExactlyOneFrame() {
        var gate = SettledFrameCaptureGate(
            requestedAt: 100,
            policy: SettledFrameCapturePolicy(settleInterval: 0.25)
        )

        guard case .wait = gate.frameArrived(at: 100.01) else {
            Issue.record("the tap-adjacent frame should remain pending")
            return
        }
        #expect(!gate.didCapture)
        guard case .wait = gate.frameArrived(at: 100.25) else {
            Issue.record("settling starts at the first continuously normal frame")
            return
        }
        #expect(gate.frameArrived(at: 100.261) == .capture)
        #expect(gate.didCapture)
        #expect(gate.frameArrived(at: 100.32) == .completed)
    }

    @Test
    func settledFrameGateRestartsDelayAfterTrackingBecomesLimited() {
        var gate = SettledFrameCaptureGate(
            requestedAt: 100,
            policy: SettledFrameCapturePolicy(settleInterval: 0.25)
        )

        guard case .wait = gate.frameArrived(at: 100.01) else {
            Issue.record("the first normal frame should begin settling")
            return
        }
        gate.trackingWasNotNormal()
        guard case .wait = gate.frameArrived(at: 100.30) else {
            Issue.record("the first recovered frame should restart settling")
            return
        }
        guard case .wait = gate.frameArrived(at: 100.549) else {
            Issue.record("continuous normal tracking has not settled yet")
            return
        }
        #expect(gate.frameArrived(at: 100.551) == .capture)
        #expect(gate.frameArrived(at: 100.60) == .completed)
    }

    @Test
    func newerSessionEventWinsWhenActorTasksArriveOutOfOrder() {
        var gate = ScannerSessionEventGate()

        let appliesNewest = gate.shouldApply(sequence: 2)
        let rejectsOlder = !gate.shouldApply(sequence: 1)
        let rejectsDuplicate = !gate.shouldApply(sequence: 2)

        #expect(appliesNewest)
        #expect(rejectsOlder)
        #expect(rejectsDuplicate)
        #expect(gate.lastAppliedSequence == 2)
    }

    @Test @MainActor
    func coordinatorIsBoundBeforeSessionConfiguration() {
        let state = ScannerSheetView.ScannerStateModel()
        let view = MeasurementARView(scannerState: state)

        let coordinator = view.makeCoordinator()

        #expect(coordinator.scannerState === state)
    }

    @Test
    func acceptsCenterSeedOnVerticalObjectFace() {
        let sample = CenteredTargetSurfaceSample(
            center: SIMD3<Float>(0, 0.50, -1),
            left: SIMD3<Float>(-0.05, 0.50, -1),
            right: SIMD3<Float>(0.05, 0.50, -1),
            up: SIMD3<Float>(0, 0.55, -1),
            down: SIMD3<Float>(0, 0.45, -1)
        )

        #expect(CenteredTargetValidator().validate(sample) == .valid)
    }

    @Test
    func acceptsElevatedHorizontalBoxTopAboveObservedFloor() {
        let sample = CenteredTargetSurfaceSample(
            center: SIMD3<Float>(0, 0.51, -1),
            left: SIMD3<Float>(-0.05, 0.51, -1),
            right: SIMD3<Float>(0.05, 0.51, -1),
            up: SIMD3<Float>(0, 0.51, -1.05),
            down: SIMD3<Float>(0, 0.51, -0.95)
        )
        let context = CenteredTargetContext(
            floorEstimate: SceneFloorEstimate(y: 0, source: .peripheralDepth),
            regionCoverage: 0.24,
            regionTouchesImageEdge: false
        )

        let assessment = CenteredTargetValidator().assess(sample, context: context)

        #expect(assessment.validation == .valid)
        #expect((assessment.elevationAboveFloorMeters ?? 0) > 0.5)
        #expect(assessment.absoluteUpNormal > 0.95)
    }

    @Test
    func acceptsCompactHorizontalTopWhenFloorIsNotObservable() {
        let sample = CenteredTargetSurfaceSample(
            center: SIMD3<Float>(0, 0.45, -0.8),
            left: SIMD3<Float>(-0.04, 0.45, -0.8),
            right: SIMD3<Float>(0.04, 0.45, -0.8),
            up: SIMD3<Float>(0, 0.45, -0.84),
            down: SIMD3<Float>(0, 0.45, -0.76)
        )
        let context = CenteredTargetContext(
            floorEstimate: nil,
            regionCoverage: 0.18,
            regionTouchesImageEdge: false
        )

        #expect(CenteredTargetValidator().validate(sample, context: context) == .valid)
    }

    @Test
    func rejectsBroadHorizontalSeedAtObservedFloorHeight() {
        let sample = CenteredTargetSurfaceSample(
            center: SIMD3<Float>(0, 0.01, -1),
            left: SIMD3<Float>(-0.05, 0.01, -1),
            right: SIMD3<Float>(0.05, 0.01, -1),
            up: SIMD3<Float>(0, 0.01, -1.05),
            down: SIMD3<Float>(0, 0.01, -0.95)
        )
        let context = CenteredTargetContext(
            floorEstimate: SceneFloorEstimate(y: 0, source: .peripheralDepth),
            regionCoverage: 0.68,
            regionTouchesImageEdge: true
        )

        let assessment = CenteredTargetValidator().assess(sample, context: context)

        #expect(assessment.validation == .rejected(.floorSurface))
        #expect(abs(assessment.elevationAboveFloorMeters ?? 1) < 0.02)
        #expect(assessment.absoluteUpNormal > 0.95)
    }

    @Test
    func singleNoisyFloorAssessmentDoesNotVetoAcceptedObjectFrames() {
        let policy = CenteredTargetCapturePolicy()

        let validation = policy.finalValidation(
            acceptedObjectFrameCount: 5,
            floorRejectedFrameCount: 1
        )

        #expect(validation == .valid)
    }

    @Test
    func consistentFloorMajorityRejectsCapture() {
        let policy = CenteredTargetCapturePolicy()

        let validation = policy.finalValidation(
            acceptedObjectFrameCount: 1,
            floorRejectedFrameCount: 5
        )

        #expect(validation == .rejected(.floorSurface))
    }

    @Test
    func peripheralDepthFindsLowestDenseFloorBandAmidClutter() throws {
        var points: [SIMD3<Float>] = []
        for index in 0..<90 {
            let noise = Float((index % 5) - 2) * 0.002
            points.append(SIMD3<Float>(Float(index) * 0.01, noise, -1))
        }
        for index in 0..<45 {
            points.append(SIMD3<Float>(0.4, 0.08 + Float(index) * 0.02, -1.4))
        }
        for index in 0..<35 {
            points.append(SIMD3<Float>(Float(index) * 0.01, 0.52, -0.9))
        }

        let estimate = try #require(PeripheralFloorEstimator().estimate(from: points))

        #expect(abs(estimate.y) < 0.02)
        #expect(estimate.source == .peripheralDepth)
    }

    @Test
    func floorBridgeCannotPullBackgroundIntoReticleSeededObject() throws {
        let width = 11
        let height = 9
        func index(_ x: Int, _ y: Int) -> Int { y * width + x }

        let objectIndices = Set(
            (2...6).flatMap { y in (4...6).map { x in index(x, y) } }
        )
        let floorIndices = Set((0..<width).map { x in index(x, 7) })
        let backgroundIndices = Set(
            (1...6).flatMap { y in (0...2).map { x in index(x, y) } }
        )
        let contaminatedIndices = objectIndices
            .union(floorIndices)
            .union(backgroundIndices)
        let region = DepthRegion(
            indices: contaminatedIndices.sorted(),
            seedDepthMeters: 1,
            bounds: PixelBounds(minX: 0, minY: 1, maxX: 10, maxY: 7)
        )

        var worldPointsByIndex: [Int: SIMD3<Float>] = [:]
        for contaminatedIndex in contaminatedIndices {
            let x = contaminatedIndex % width
            let y = contaminatedIndex / width
            let worldY: Float
            if floorIndices.contains(contaminatedIndex) {
                worldY = 0
            } else if objectIndices.contains(contaminatedIndex) {
                worldY = 0.05 + Float(6 - y) * 0.10
            } else {
                worldY = 0.08 + Float(6 - y) * 0.07
            }
            worldPointsByIndex[contaminatedIndex] = SIMD3<Float>(
                Float(x) * 0.05,
                worldY,
                -1 - Float(y) * 0.02
            )
        }

        let filtered = try #require(
            ReticleSeededObjectRegionFilter().filter(
                region: region,
                gridWidth: width,
                gridHeight: height,
                floorEstimate: SceneFloorEstimate(y: 0, source: .peripheralDepth),
                worldPointAt: { worldPointsByIndex[$0] }
            )
        )

        #expect(Set(filtered.indices) == objectIndices)
        #expect(filtered.bounds == PixelBounds(minX: 4, minY: 2, maxX: 6, maxY: 6))
    }

    @Test
    func measurementOutcomePreservesTargetRejectionReason() {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: 0
        )

        let outcome = MeasurementEstimator.outcome(
            from: points,
            frameCount: 10,
            targetValidation: .rejected(.floorSurface)
        )

        #expect(outcome == .failure(.targetRejected(.floorSurface)))
    }

    @Test
    func consistentFloorCapturePreservesReasonWithoutGeometryFrames() {
        let outcome = MeasurementEstimator.outcome(
            from: [],
            frameCount: 0,
            targetValidation: .rejected(.floorSurface)
        )

        #expect(outcome == .failure(.targetRejected(.floorSurface)))
    }

    @Test
    func measurementOutcomePreservesGeometryFailureReason() {
        let points = Array(repeating: SIMD3<Float>(0, 0, -1), count: 24)

        let outcome = MeasurementEstimator.outcome(from: points, frameCount: 3)

        #expect(
            outcome
                == .failure(
                    .geometry(.insufficientUniquePoints(actual: 1, minimum: 8))
                )
        )
    }

    @Test
    func invalidFloorTargetCannotReturnHighConfidenceMeasurement() throws {
        let misleadingFloorRegion = boxSurfacePoints(
            length: 2.1,
            width: 1.6,
            height: 0.8,
            yaw: .pi / 14
        )
        let unvalidated = try #require(
            MeasurementEstimator.estimate(
                from: misleadingFloorRegion,
                frameCount: 11,
                completenessEvidence: .independentViewpoints
            )
        )
        #expect(unvalidated.lengthMeters > 2)
        #expect(unvalidated.confidence == .high)

        let rejected = MeasurementEstimator.estimate(
            from: misleadingFloorRegion,
            frameCount: 11,
            targetValidation: .rejected(.floorSurface)
        )

        #expect(rejected == nil)
    }

    @Test
    func mapsSharedGeometryEstimateWithoutRecomputingDimensions() throws {
        let points = boxSurfacePoints(
            length: 1.18,
            width: 0.62,
            height: 0.74,
            yaw: .pi / 8
        )
        let geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: points)

        let measurement = MeasurementEstimator.estimate(
            from: points,
            frameCount: 11,
            completenessEvidence: .independentViewpoints
        )

        let unwrapped = try #require(measurement)
        #expect(unwrapped.lengthMeters == geometry.dimensions.lengthMeters)
        #expect(unwrapped.widthMeters == geometry.dimensions.widthMeters)
        #expect(unwrapped.heightMeters == geometry.dimensions.heightMeters)
        #expect(unwrapped.sampleCount == geometry.diagnostics.inlierPointCount)
        #expect(unwrapped.frameCount == 11)
        #expect(unwrapped.confidence.rawValue == geometry.confidence.level.rawValue)
    }

    @Test
    func returnsNilWhenSharedGeometryEstimatorRejectsPointCloud() {
        let points = Array(repeating: SIMD3<Float>(0, 0, -1), count: 24)

        #expect(MeasurementEstimator.estimate(from: points, frameCount: 3) == nil)
    }

    @Test
    func denseSingleFrameEstimateCapsHighGeometryConfidenceAtMedium() throws {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: .pi / 10
        )
        let geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: points)
        #expect(geometry.confidence.level == .high)

        let measurement = try #require(
            MeasurementEstimator.estimate(from: points, frameCount: 1)
        )

        #expect(measurement.lengthMeters == geometry.dimensions.lengthMeters)
        #expect(measurement.widthMeters == geometry.dimensions.widthMeters)
        #expect(measurement.heightMeters == geometry.dimensions.heightMeters)
        #expect(measurement.sampleCount == geometry.diagnostics.inlierPointCount)
        #expect(measurement.frameCount == 1)
        #expect(measurement.confidence == .medium)
    }

    @Test
    func multipleSameViewFramesDoNotClaimIndependentCompleteness() throws {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: .pi / 10
        )
        let geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: points)
        #expect(geometry.confidence.level == .high)

        let measurement = try #require(
            MeasurementEstimator.estimate(from: points, frameCount: 2)
        )

        #expect(measurement.lengthMeters == geometry.dimensions.lengthMeters)
        #expect(measurement.widthMeters == geometry.dimensions.widthMeters)
        #expect(measurement.heightMeters == geometry.dimensions.heightMeters)
        #expect(measurement.sampleCount == geometry.diagnostics.inlierPointCount)
        #expect(measurement.frameCount == 2)
        #expect(measurement.confidence == .medium)
    }

    @Test
    func explicitIndependentViewEvidenceCanRetainHighGeometryConfidence() throws {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: .pi / 10
        )
        let geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: points)
        #expect(geometry.confidence.level == .high)

        let measurement = try #require(
            MeasurementEstimator.estimate(
                from: points,
                frameCount: 2,
                completenessEvidence: .independentViewpoints
            )
        )

        #expect(measurement.confidence == .high)
    }

    @Test
    func captureEvidencePreservesRawGeometryCenterAndPointCloudConfidence() throws {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: .pi / 10
        )
        let geometry = try GravityAlignedBoundingBoxEstimator().estimate(points: points)
        #expect(geometry.confidence.level == .high)

        guard case .success(let evidence) = MeasurementEstimator.captureEvidenceOutcome(
            from: points,
            frameCount: 1
        ) else {
            Issue.record("expected dense capture evidence")
            return
        }

        #expect(evidence.geometryCenter == geometry.center)
        #expect(evidence.pointCloudConfidence == .high)
        #expect(evidence.estimate.confidence == .medium)
        #expect(evidence.estimate.lengthMeters == geometry.dimensions.lengthMeters)
        #expect(evidence.estimate.widthMeters == geometry.dimensions.widthMeters)
        #expect(evidence.estimate.heightMeters == geometry.dimensions.heightMeters)
    }

    @Test
    func viewpointRequiresMinimumHorizontalBaseline() {
        let policy = MeasurementViewpointPolicy()
        let reference = angleCapture(position: SIMD3<Float>(-0.074, 0, 0))
        let belowThreshold = angleCapture(position: SIMD3<Float>(0.074, 0, 0))
        let aboveThreshold = angleCapture(position: SIMD3<Float>(0.076, 0, 0))

        #expect(policy.validate(belowThreshold, against: reference) == .tooSimilar)
        #expect(policy.validate(aboveThreshold, against: reference) == .distinct)
    }

    @Test
    func viewpointRequiresTwentyFiveDegreeOrbitInsteadOfDistanceAlone() {
        let policy = MeasurementViewpointPolicy()
        let reference = angleCapture(position: SIMD3<Float>(0, 0, 1))
        let belowAngle = Float.pi * 24 / 180
        let aboveAngle = Float.pi * 26 / 180
        let tooSimilar = angleCapture(
            position: SIMD3<Float>(sin(belowAngle), 0, cos(belowAngle))
        )
        let distinct = angleCapture(
            position: SIMD3<Float>(sin(aboveAngle), 0, cos(aboveAngle))
        )

        #expect(policy.validate(tooSimilar, against: reference) == .tooSimilar)
        #expect(policy.validate(distinct, against: reference) == .distinct)
    }

    @Test
    func viewpointRejectsTargetCenterDriftBeforeComparingOrbit() {
        let policy = MeasurementViewpointPolicy()
        let reference = angleCapture(position: SIMD3<Float>(0, 0, 1))
        let stable = angleCapture(
            center: SIMD3<Float>(0.0508, 0, 0),
            position: SIMD3<Float>(1, 0, 0)
        )
        let moved = angleCapture(
            center: SIMD3<Float>(0.061, 0, 0),
            position: SIMD3<Float>(1, 0, 0)
        )

        #expect(policy.validate(stable, against: reference) == .distinct)
        #expect(policy.validate(moved, against: reference) == .targetMoved)
    }

    @Test
    func twoAgreeingViewsAcceptConservativeUpperAxisEnvelope() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(
            length: 0.60,
            width: 0.40,
            height: 0.50,
            sampleCount: 100,
            position: SIMD3<Float>(0, 0, 1)
        )
        let second = angleCapture(
            length: 0.62,
            width: 0.39,
            height: 0.51,
            sampleCount: 200,
            position: SIMD3<Float>(1, 0, 0)
        )

        #expect(
            workflow.record(first)
                == .needsAnotherAngle(reason: .firstAngleCaptured, acceptedCount: 1)
        )
        let progress = workflow.record(second)
        guard case .accepted(let consensus) = progress else {
            Issue.record("expected two-view consensus")
            return
        }

        #expect(consensus.lengthMeters == 0.62)
        #expect(consensus.widthMeters == 0.40)
        #expect(consensus.heightMeters == 0.51)
        #expect(consensus.sampleCount == 300)
        #expect(consensus.frameCount == 2)
        #expect(consensus.comparisonAngleCount == 2)
        #expect(consensus.comparisonAgreementCount == 2)
        #expect(consensus.confidence == .high)
        #expect(first.evidence.estimate.lengthMeters == 0.60)
        #expect(second.evidence.estimate.widthMeters == 0.39)
    }

    @Test
    func twoDistinctViewsThatDisagreeRequestAThirdAngle() {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(position: SIMD3<Float>(0, 0, 1))
        let second = angleCapture(
            length: 0.70,
            position: SIMD3<Float>(1, 0, 0)
        )

        _ = workflow.record(first)

        #expect(
            workflow.record(second)
                == .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
        )
        #expect(workflow.captures.count == 2)
    }

    @Test
    func tooSimilarRetryIsNotAppendedAndLaterDistinctViewCanResolve() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(position: SIMD3<Float>(0, 0, 1))
        let tooSimilar = angleCapture(
            length: 0.61,
            width: 0.41,
            height: 0.51,
            position: SIMD3<Float>(0.10, 0, 1)
        )
        let laterDistinct = angleCapture(
            length: 0.61,
            width: 0.41,
            height: 0.51,
            position: SIMD3<Float>(1, 0, 0)
        )

        _ = workflow.record(first)
        #expect(
            workflow.record(tooSimilar)
                == .needsAnotherAngle(reason: .viewpointTooSimilar, acceptedCount: 1)
        )
        #expect(workflow.captures == [first])

        guard case .accepted(let consensus) = workflow.record(laterDistinct) else {
            Issue.record("expected a later distinct view to resolve the staged first capture")
            return
        }
        #expect(workflow.captures == [first, laterDistinct])
        #expect(consensus.comparisonAngleCount == 2)
        #expect(consensus.comparisonAgreementCount == 2)
    }

    @Test
    func exactSuitcaseLargerSecondCannotBeDiscardedBySmallerThird() {
        var workflow = MultiAngleMeasurementWorkflow()
        let smallerFirst = angleCapture(
            length: meters(fromInches: 14),
            width: meters(fromInches: 10),
            height: meters(fromInches: 18),
            position: SIMD3<Float>(0, 0, 1)
        )
        let largerSecond = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 22),
            position: SIMD3<Float>(1, 0, 0)
        )
        let smallerThird = angleCapture(
            length: meters(fromInches: 14),
            width: meters(fromInches: 10),
            height: meters(fromInches: 18),
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(smallerFirst)
        #expect(
            workflow.record(largerSecond)
                == .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
        )
        #expect(
            workflow.record(smallerThird)
                == .inconsistent(.dimensionsInconsistent)
        )
    }

    @Test
    func exactSuitcaseLargerFirstCannotBeDiscardedBySmallerThird() {
        var workflow = MultiAngleMeasurementWorkflow()
        let largerFirst = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 22),
            position: SIMD3<Float>(0, 0, 1)
        )
        let smallerSecond = angleCapture(
            length: meters(fromInches: 14),
            width: meters(fromInches: 10),
            height: meters(fromInches: 18),
            position: SIMD3<Float>(1, 0, 0)
        )
        let smallerThird = angleCapture(
            length: meters(fromInches: 14),
            width: meters(fromInches: 10),
            height: meters(fromInches: 18),
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(largerFirst)
        #expect(
            workflow.record(smallerSecond)
                == .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
        )
        #expect(
            workflow.record(smallerThird)
                == .inconsistent(.dimensionsInconsistent)
        )
    }

    @Test
    func exactSuitcaseLargerThirdResolvesWhenSmallerWasFirst() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let smallerFirst = angleCapture(
            length: meters(fromInches: 14),
            width: meters(fromInches: 10),
            height: meters(fromInches: 18),
            position: SIMD3<Float>(0, 0, 1)
        )
        let largerSecond = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 22),
            center: SIMD3<Float>(0, 0.0508, 0),
            position: SIMD3<Float>(1, 0, 0)
        )
        let largerThird = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 22),
            center: SIMD3<Float>(0, 0.0508, 0),
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(smallerFirst)
        #expect(
            workflow.record(largerSecond)
                == .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
        )
        let progress = workflow.record(largerThird)
        assertResolvedSuitcaseDimensions(progress)
    }

    @Test
    func exactSuitcaseLargerThirdResolvesWhenSmallerWasSecond() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let largerFirst = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 22),
            position: SIMD3<Float>(0, 0, 1)
        )
        let smallerSecond = angleCapture(
            length: meters(fromInches: 14),
            width: meters(fromInches: 10),
            height: meters(fromInches: 18),
            position: SIMD3<Float>(1, 0, 0)
        )
        let largerThird = angleCapture(
            length: meters(fromInches: 16),
            width: meters(fromInches: 10),
            height: meters(fromInches: 22),
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(largerFirst)
        #expect(
            workflow.record(smallerSecond)
                == .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
        )
        let progress = workflow.record(largerThird)
        assertResolvedSuitcaseDimensions(progress)
    }

    @Test
    func thirdAngleUsesConservativeEnvelopeOfGloballyAgreeingPair() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(
            length: 0.60,
            width: 0.40,
            height: 0.50,
            sampleCount: 100,
            position: SIMD3<Float>(0, 0, 1)
        )
        let smallerDiscordantSecond = angleCapture(
            length: 0.50,
            width: 0.30,
            height: 0.40,
            sampleCount: 200,
            position: SIMD3<Float>(1, 0, 0)
        )
        let agreeingThird = angleCapture(
            length: 0.61,
            width: 0.41,
            height: 0.51,
            sampleCount: 300,
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(first)
        #expect(
            workflow.record(smallerDiscordantSecond)
                == .needsAnotherAngle(reason: .dimensionsDisagree, acceptedCount: 2)
        )
        let progress = workflow.record(agreeingThird)
        guard case .accepted(let consensus) = progress else {
            Issue.record("expected the globally agreeing pair to resolve capture")
            return
        }

        #expect(consensus.lengthMeters == 0.61)
        #expect(consensus.widthMeters == 0.41)
        #expect(consensus.heightMeters == 0.51)
        #expect(consensus.sampleCount == 400)
        #expect(consensus.frameCount == 2)
        #expect(consensus.comparisonAngleCount == 3)
        #expect(consensus.comparisonAgreementCount == 2)
    }

    @Test
    func materiallyLargerDiscordantThirdPhotoCannotBeDiscarded() {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(position: SIMD3<Float>(0, 0, 1))
        let largerDiscordantSecond = angleCapture(
            length: 0.80,
            width: 0.60,
            height: 0.70,
            position: SIMD3<Float>(1, 0, 0)
        )
        let agreeingThird = angleCapture(
            length: 0.61,
            width: 0.41,
            height: 0.51,
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(first)
        _ = workflow.record(largerDiscordantSecond)

        #expect(
            workflow.record(agreeingThird)
                == .inconsistent(.dimensionsInconsistent)
        )
    }

    @Test
    func threeAnglesWithoutAnyGloballyAgreeingPairFailConsensus() {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(
            length: 0.50,
            width: 0.30,
            height: 0.40,
            position: SIMD3<Float>(0, 0, 1)
        )
        let second = angleCapture(
            length: 0.60,
            width: 0.40,
            height: 0.50,
            position: SIMD3<Float>(1, 0, 0)
        )
        let third = angleCapture(
            length: 0.70,
            width: 0.50,
            height: 0.60,
            position: SIMD3<Float>(0, 0, -1)
        )

        _ = workflow.record(first)
        _ = workflow.record(second)

        #expect(workflow.record(third) == .inconsistent(.dimensionsInconsistent))
    }

    @Test
    func consensusNormalizesSwappedBaseAxesAcrossViewpoints() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(
            length: 0.60,
            width: 0.40,
            position: SIMD3<Float>(0, 0, 1)
        )
        let swapped = angleCapture(
            length: 0.40,
            width: 0.60,
            position: SIMD3<Float>(1, 0, 0)
        )

        _ = workflow.record(first)
        let progress = workflow.record(swapped)
        guard case .accepted(let consensus) = progress else {
            Issue.record("expected swapped base axes to agree")
            return
        }

        #expect(consensus.lengthMeters == 0.60)
        #expect(consensus.widthMeters == 0.40)
        #expect(consensus.heightMeters == 0.50)
    }

    @Test
    func agreeingViewsWithGenuinelyMediumPointCloudRemainMedium() throws {
        var workflow = MultiAngleMeasurementWorkflow()
        let first = angleCapture(
            pointCloudConfidence: .medium,
            position: SIMD3<Float>(0, 0, 1)
        )
        let second = angleCapture(
            length: 0.61,
            width: 0.41,
            height: 0.51,
            pointCloudConfidence: .high,
            position: SIMD3<Float>(1, 0, 0)
        )

        _ = workflow.record(first)
        let progress = workflow.record(second)
        guard case .accepted(let consensus) = progress else {
            Issue.record("expected agreeing medium-quality views to resolve")
            return
        }

        #expect(consensus.confidence == .medium)
    }

    @Test
    func axisAndVolumeAgreementThresholdsAreBothEnforced() {
        let policy = MultiAngleMeasurementConsensusPolicy()
        let reference = angleCapture(position: SIMD3<Float>(0, 0, 1)).evidence
        let justInsideAxisLimit = angleCapture(
            length: 0.60 + policy.maximumAxisDifferenceMeters - 0.000_001,
            position: SIMD3<Float>(1, 0, 0)
        ).evidence
        let justOutsideAxisLimit = angleCapture(
            length: 0.60 + policy.maximumAxisDifferenceMeters + 0.000_001,
            position: SIMD3<Float>(1, 0, 0)
        ).evidence
        let insideVolumeLimit = angleCapture(
            length: 0.60 * 1.06,
            width: 0.40 * 1.06,
            height: 0.50 * 1.06,
            position: SIMD3<Float>(1, 0, 0)
        ).evidence
        let outsideVolumeLimit = angleCapture(
            length: 0.60 * 1.065,
            width: 0.40 * 1.065,
            height: 0.50 * 1.065,
            position: SIMD3<Float>(1, 0, 0)
        ).evidence

        #expect(policy.measurementsAgree(reference, justInsideAxisLimit))
        #expect(!policy.measurementsAgree(reference, justOutsideAxisLimit))
        #expect(policy.measurementsAgree(reference, insideVolumeLimit))
        #expect(!policy.measurementsAgree(reference, outsideVolumeLimit))
    }

    @Test
    func acceptsOneContributingDepthFrameForPhotoCapture() throws {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: 0
        )

        let measurement = try #require(
            MeasurementEstimator.estimate(from: points, frameCount: 1)
        )

        #expect(measurement.frameCount == 1)
    }

    private func angleCapture(
        length: Double = 0.60,
        width: Double = 0.40,
        height: Double = 0.50,
        sampleCount: Int = 100,
        pointCloudConfidence: ScanConfidence = .high,
        center: SIMD3<Float> = .zero,
        position: SIMD3<Float>
    ) -> MeasurementAngleCapture {
        MeasurementAngleCapture(
            evidence: MeasurementCaptureEvidence(
                estimate: MeasurementEstimate(
                    lengthMeters: length,
                    widthMeters: width,
                    heightMeters: height,
                    confidence: pointCloudConfidence == .high ? .medium : pointCloudConfidence,
                    sampleCount: sampleCount,
                    frameCount: 1
                ),
                pointCloudConfidence: pointCloudConfidence,
                geometryCenter: center
            ),
            viewpoint: MeasurementCameraViewpoint(position: position)
        )
    }

    private func assertResolvedSuitcaseDimensions(
        _ progress: MultiAngleMeasurementProgress,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case .accepted(let consensus) = progress else {
            Issue.record("expected the two larger suitcase captures to resolve", sourceLocation: sourceLocation)
            return
        }
        #expect(
            consensus.lengthMeters == meters(fromInches: 16),
            sourceLocation: sourceLocation
        )
        #expect(
            consensus.widthMeters == meters(fromInches: 10),
            sourceLocation: sourceLocation
        )
        #expect(
            consensus.heightMeters == meters(fromInches: 22),
            sourceLocation: sourceLocation
        )
        #expect(consensus.comparisonAngleCount == 3, sourceLocation: sourceLocation)
        #expect(consensus.comparisonAgreementCount == 2, sourceLocation: sourceLocation)
    }

    private func meters(fromInches inches: Double) -> Double {
        inches * 0.0254
    }

    private func boxSurfacePoints(
        length: Float,
        width: Float,
        height: Float,
        yaw: Float
    ) -> [SIMD3<Float>] {
        let cosine = cos(yaw)
        let sine = sin(yaw)

        func rotated(x: Float, y: Float, z: Float) -> SIMD3<Float> {
            SIMD3<Float>(
                x * cosine - z * sine,
                y,
                x * sine + z * cosine
            )
        }

        var points: [SIMD3<Float>] = []
        let xSteps = 24
        let ySteps = 16
        let zSteps = 18

        for xIndex in 0...xSteps {
            let x = -length / 2 + length * Float(xIndex) / Float(xSteps)
            for yIndex in 0...ySteps {
                let y = height * Float(yIndex) / Float(ySteps)
                points.append(rotated(x: x, y: y, z: -width / 2))
                points.append(rotated(x: x, y: y, z: width / 2))
            }
        }
        for zIndex in 0...zSteps {
            let z = -width / 2 + width * Float(zIndex) / Float(zSteps)
            for yIndex in 0...ySteps {
                let y = height * Float(yIndex) / Float(ySteps)
                points.append(rotated(x: -length / 2, y: y, z: z))
                points.append(rotated(x: length / 2, y: y, z: z))
            }
        }
        for xIndex in 0...xSteps {
            let x = -length / 2 + length * Float(xIndex) / Float(xSteps)
            for zIndex in 0...zSteps {
                let z = -width / 2 + width * Float(zIndex) / Float(zSteps)
                points.append(rotated(x: x, y: 0, z: z))
                points.append(rotated(x: x, y: height, z: z))
            }
        }
        return points
    }
}
