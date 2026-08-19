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
