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
    func temporalSupportRemovesShallowHaloAndPreservesDeepVisibleSide() {
        let elevatedCore: [SIMD3<Float>] = [
            SIMD3<Float>(-0.24, 0.18, -1.00),
            SIMD3<Float>(0.00, 0.18, -1.00),
            SIMD3<Float>(0.24, 0.18, -1.00),
            SIMD3<Float>(-0.24, 0.48, -1.00),
            SIMD3<Float>(0.00, 0.48, -1.00),
            SIMD3<Float>(0.24, 0.48, -1.00),
        ]
        let deepVisibleSide = [Float(0.18), Float(0.48)].flatMap { y in
            (1...7).map { step in
                SIMD3<Float>(0.24, y, -1.00 - Float(step) * 0.06)
            }
        }
        let shallowRamp = (0...9).map { step in
            SIMD3<Float>(
                0.28 + Float(step) * 0.04,
                0.48,
                -1.02 - Float(step) * 0.025
            )
        }
        let aboveFloorBackground: [SIMD3<Float>] = [
            SIMD3<Float>(0.68, 0.18, -1.25),
            SIMD3<Float>(0.76, 0.18, -1.25),
            SIMD3<Float>(0.68, 0.48, -1.25),
            SIMD3<Float>(0.76, 0.48, -1.25),
        ]
        let jitter = SIMD3<Float>(0.008, -0.004, 0.007)
        let frames = [
            elevatedCore + deepVisibleSide,
            (elevatedCore + deepVisibleSide).map { $0 + jitter },
            elevatedCore.map { $0 - jitter } + shallowRamp + aboveFloorBackground,
        ]

        let result = TemporalWorldPointSupportFilter().filter(frames: frames)

        #expect(result.contributingFrameCount == 3)
        #expect(result.requiredSupportingFrameCount == 2)
        #expect(result.points.contains { $0.z < -1.38 })
        #expect(!result.points.contains { $0.x > 0.30 })
        #expect(result.points.count < frames.flatMap { $0 }.count)
    }

    @Test
    func temporalSupportRejectsTwoFrameFringeInTypicalCapture() {
        let stableCore = SIMD3<Float>(0, 0.35, -1)
        let partiallyVisibleSide = SIMD3<Float>(0.24, 0.35, -1.40)
        let repeatedFringe = SIMD3<Float>(0.48, 0.35, -1.18)
        let frames = (0..<10).map { frameIndex in
            let jitter = Float((frameIndex % 3) - 1) * 0.004
            var points = [stableCore + SIMD3<Float>(jitter, 0, -jitter)]
            if frameIndex < 3 {
                points.append(partiallyVisibleSide + SIMD3<Float>(jitter, 0, -jitter))
            }
            if frameIndex < 2 {
                points.append(repeatedFringe + SIMD3<Float>(jitter, 0, -jitter))
            }
            return points
        }

        let result = TemporalWorldPointSupportFilter().filter(frames: frames)

        #expect(result.requiredSupportingFrameCount == 3)
        #expect(result.points.contains { $0.z < -1.35 })
        #expect(!result.points.contains { $0.x > 0.40 })
    }

    @Test
    func temporalSupportRejectsTwoFrameFringeInShortCaptures() {
        let stableCore = SIMD3<Float>(0, 0.35, -1)
        let legitimateSide = SIMD3<Float>(0.24, 0.35, -1.40)
        let repeatedFringe = SIMD3<Float>(0.48, 0.35, -1.18)

        for frameCount in [3, 4, 7] {
            let frames = (0..<frameCount).map { frameIndex in
                var points = [stableCore]
                if frameIndex < 3 {
                    points.append(legitimateSide)
                }
                if frameIndex < 2 {
                    points.append(repeatedFringe)
                }
                return points
            }

            let result = TemporalWorldPointSupportFilter().filter(frames: frames)

            #expect(result.requiredSupportingFrameCount == 3)
            #expect(result.points.contains(legitimateSide))
            #expect(!result.points.contains(repeatedFringe))
        }
    }

    @Test
    func temporalSupportDistinguishesNeighborToleranceFromParallelSlab() {
        let stableSurface = SIMD3<Float>(0.001, 0.35, -1)
        let withinNeighborTolerance = SIMD3<Float>(0.039, 0.35, -1)
        let outsideNeighborTolerance = SIMD3<Float>(0.041, 0.35, -1)
        let frames = (0..<4).map { frameIndex in
            frameIndex < 2
                ? [stableSurface, withinNeighborTolerance, outsideNeighborTolerance]
                : [stableSurface]
        }

        let result = TemporalWorldPointSupportFilter().filter(frames: frames)

        #expect(result.points.contains(withinNeighborTolerance))
        #expect(!result.points.contains(outsideNeighborTolerance))
    }

    @Test
    func temporallyFilteredCaptureMatchesStableMeasurementPipeline() {
        let stableObject = boxSurfacePoints(
            length: 0.60,
            width: 0.40,
            height: 0.50,
            yaw: 0
        )
        let parallelFringe = (0...16).flatMap { yIndex in
            (0...18).map { zIndex in
                SIMD3<Float>(
                    0.90,
                    0.50 * Float(yIndex) / 16,
                    -0.20 + 0.40 * Float(zIndex) / 18
                )
            }
        }
        let frames = [
            stableObject + parallelFringe,
            stableObject + parallelFringe,
            stableObject,
        ]

        let filtered = TemporalWorldPointSupportFilter().filter(frames: frames)
        let filteredOutcome = MeasurementEstimator.outcome(
            from: filtered.points,
            frameCount: frames.count
        )
        let stableOutcome = MeasurementEstimator.outcome(
            from: stableObject,
            frameCount: frames.count
        )

        #expect(filteredOutcome == stableOutcome)
    }

    @Test
    func temporalSupportMatchesNeighboringVoxelsAcrossDepthJitter() {
        let frames = [
            [SIMD3<Float>(0.024, 0.30, -1.024)],
            [SIMD3<Float>(0.026, 0.30, -1.026)],
            [SIMD3<Float>(0.023, 0.30, -1.023)],
        ]

        let result = TemporalWorldPointSupportFilter().filter(frames: frames)

        #expect(result.points.count == 3)
    }

    @Test
    func temporalSupportHandlesEmptyCapture() {
        let result = TemporalWorldPointSupportFilter().filter(frames: [])

        #expect(result.points.isEmpty)
        #expect(result.contributingFrameCount == 0)
        #expect(result.requiredSupportingFrameCount == 0)
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
                frameCount: 11
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

        let measurement = MeasurementEstimator.estimate(from: points, frameCount: 11)

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
    func requiresMultipleContributingDepthFrames() {
        let points = boxSurfacePoints(
            length: 0.8,
            width: 0.5,
            height: 0.6,
            yaw: 0
        )

        #expect(MeasurementEstimator.estimate(from: points, frameCount: 2) == nil)
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
