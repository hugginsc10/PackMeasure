import Testing
import simd
@testable import PackMeasure

struct MeasurementEstimatorTests {
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
    func rejectsCenterSeedOnFloorSurface() {
        let sample = CenteredTargetSurfaceSample(
            center: SIMD3<Float>(0, 0, -1),
            left: SIMD3<Float>(-0.05, 0, -1),
            right: SIMD3<Float>(0.05, 0, -1),
            up: SIMD3<Float>(0, 0, -1.05),
            down: SIMD3<Float>(0, 0, -0.95)
        )

        #expect(
            CenteredTargetValidator().validate(sample)
                == .rejected(.horizontalSurface)
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
            targetValidation: .rejected(.horizontalSurface)
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
