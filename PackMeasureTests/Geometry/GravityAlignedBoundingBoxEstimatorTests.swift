import XCTest
@testable import PackMeasure

final class GravityAlignedBoundingBoxEstimatorTests: XCTestCase {
    private let estimator = GravityAlignedBoundingBoxEstimator()

    func testEstimatesAxisAlignedCuboidDimensionsAndCenter() throws {
        let points = cuboidSurfacePoints(
            length: 1.20,
            width: 0.60,
            height: 0.80,
            yaw: 0,
            center: SIMD3<Float>(0.30, 0.70, -0.20)
        )
        let estimate = try estimator.estimate(points: points)

        assertDimensions(estimate.dimensions, 1.20, 0.60, 0.80, accuracy: 0.006)
        XCTAssertEqual(estimate.center.x, 0.30, accuracy: 0.006)
        XCTAssertEqual(estimate.center.y, 0.70, accuracy: 0.006)
        XCTAssertEqual(estimate.center.z, -0.20, accuracy: 0.006)
    }

    func testUsesGravityAlignedPCAForYawedCuboid() throws {
        let yaw = Float.pi * 0.31
        let points = cuboidSurfacePoints(
            length: 1.80,
            width: 0.72,
            height: 0.95,
            yaw: yaw,
            center: SIMD3<Float>(-0.45, 0.85, 0.65)
        )
        let estimate = try estimator.estimate(points: points)

        assertDimensions(estimate.dimensions, 1.80, 0.72, 0.95, accuracy: 0.012)
        XCTAssertLessThan(angularDistanceModuloHalfTurn(estimate.yawRadians, yaw), 0.015)
    }

    func testTrimsGrossOutliersWithoutShrinkingObjectEnvelope() throws {
        var points = cuboidSurfacePoints(
            length: 1.40,
            width: 0.55,
            height: 0.70,
            yaw: 0.43,
            center: SIMD3<Float>(0, 0.45, 0)
        )
        points.append(contentsOf: [
            SIMD3<Float>(12, 8, -9),
            SIMD3<Float>(-11, -5, 10),
            SIMD3<Float>(7, 0.2, 13),
        ])

        let estimate = try estimator.estimate(points: points)

        assertDimensions(estimate.dimensions, 1.40, 0.55, 0.70, accuracy: 0.018)
        XCTAssertEqual(estimate.diagnostics.rejectedOutlierCount, 3)
        XCTAssertLessThan(estimate.confidence.inlierRatio, 1)
        XCTAssertGreaterThan(estimate.confidence.inlierRatio, 0.98)
    }

    func testVoxelDeduplicationPreventsDenseSamplesBiasingBounds() throws {
        let base = cuboidSurfacePoints(
            length: 1.25,
            width: 0.50,
            height: 0.65,
            yaw: 0.52,
            center: SIMD3<Float>(0, 0.50, 0)
        )
        let repeatedCorner = SIMD3<Float>(0.410, 0.825, 0.545)
        let clusteredDuplicates = (0..<2_000).map { index in
            let offset = Float(index % 5) * 0.0002
            return repeatedCorner + SIMD3<Float>(offset, offset, -offset)
        }

        let estimate = try estimator.estimate(points: base + clusteredDuplicates)

        assertDimensions(estimate.dimensions, 1.25, 0.50, 0.65, accuracy: 0.02)
        XCTAssertLessThan(estimate.diagnostics.uniquePointCount, base.count + 10)
        XCTAssertGreaterThan(estimate.diagnostics.deduplicatedPointCount, 1_990)
    }

    func testYawedSquareFootprintDoesNotBecomeDiagonalBox() throws {
        let points = cuboidSurfacePoints(
            length: 0.90,
            width: 0.90,
            height: 0.60,
            yaw: 0.37,
            center: SIMD3<Float>(0, 0.40, 0)
        )
        let estimate = try estimator.estimate(points: points)

        assertDimensions(estimate.dimensions, 0.90, 0.90, 0.60, accuracy: 0.012)
        XCTAssertLessThan(estimate.confidence.horizontalStability, 0.10)
        XCTAssertNotEqual(estimate.confidence.level, .high)
    }

    func testConfidenceDistinguishesDenseAndSparseValidScans() throws {
        let dense = cuboidSurfacePoints(
            length: 1.50,
            width: 0.65,
            height: 0.75,
            yaw: 0.22,
            center: SIMD3<Float>(0, 0.50, 0),
            subdivisions: 14
        )
        let sparse = cuboidCornerPoints(
            length: 1.20,
            width: 0.55,
            height: 0.70,
            yaw: 0.18
        )

        let denseEstimate = try estimator.estimate(points: dense)
        let sparseEstimate = try estimator.estimate(points: sparse)

        XCTAssertEqual(denseEstimate.confidence.level, .high)
        XCTAssertGreaterThanOrEqual(denseEstimate.confidence.score, 0.80)
        XCTAssertGreaterThan(denseEstimate.confidence.horizontalStability, 0.50)
        XCTAssertGreaterThan(denseEstimate.confidence.pointCount, 500)
        assertDimensions(sparseEstimate.dimensions, 1.20, 0.55, 0.70, accuracy: 0.012)
        XCTAssertEqual(sparseEstimate.confidence.level, .low)
        XCTAssertLessThan(sparseEstimate.confidence.score, 0.50)
    }

    func testRejectsTooFewFinitePointsAfterFiltering() {
        let points = [
            SIMD3<Float>(0, 0, 0),
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(.nan, 0, 0),
            SIMD3<Float>(0, .infinity, 0),
        ]

        XCTAssertThrowsError(try estimator.estimate(points: points)) { error in
            XCTAssertEqual(
                error as? BoundingBoxEstimationError,
                .insufficientFinitePoints(actual: 3, minimum: 8)
            )
        }
    }

    func testRejectsCollinearOrFlatPointCloudAsDegenerate() {
        let points = (0..<30).map { index in
            SIMD3<Float>(Float(index) * 0.02, 0, 0)
        }

        XCTAssertThrowsError(try estimator.estimate(points: points)) { error in
            XCTAssertEqual(error as? BoundingBoxEstimationError, .degeneratePointCloud)
        }
    }

    func testConvertsMeterDimensionsToPackingDisplayUnits() {
        let dimensions = GeometryDimensions(
            lengthMeters: 1,
            widthMeters: 0.3048,
            heightMeters: 0.0254
        )

        let inches = dimensions.converted(to: .inches)
        let feet = dimensions.converted(to: .feet)
        let centimeters = dimensions.converted(to: .centimeters)

        XCTAssertEqual(inches.length, 39.370_078_74, accuracy: 0.000_001)
        XCTAssertEqual(inches.width, 12, accuracy: 0.000_001)
        XCTAssertEqual(inches.height, 1, accuracy: 0.000_001)
        XCTAssertEqual(feet.width, 1, accuracy: 0.000_001)
        XCTAssertEqual(centimeters.length, 100, accuracy: 0.000_001)
        XCTAssertEqual(dimensions.footprintSquareMeters, 0.3048, accuracy: 0.000_001)
        XCTAssertEqual(dimensions.volumeCubicMeters, 0.007_741_92, accuracy: 0.000_001)
    }

    private func assertDimensions(
        _ actual: GeometryDimensions,
        _ length: Double,
        _ width: Double,
        _ height: Double,
        accuracy: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.lengthMeters, length, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.widthMeters, width, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.heightMeters, height, accuracy: accuracy, file: file, line: line)
    }

    private func angularDistanceModuloHalfTurn(_ lhs: Float, _ rhs: Float) -> Float {
        let halfTurn = Float.pi
        let raw = abs(lhs - rhs).truncatingRemainder(dividingBy: halfTurn)
        return min(raw, halfTurn - raw)
    }

    private func cuboidSurfacePoints(
        length: Float,
        width: Float,
        height: Float,
        yaw: Float,
        center: SIMD3<Float>,
        subdivisions: Int = 10
    ) -> [SIMD3<Float>] {
        var points: [SIMD3<Float>] = []
        let samples = (0...subdivisions).map { index in
            -0.5 + Float(index) / Float(subdivisions)
        }

        for a in samples {
            for b in samples {
                points.append(worldPoint(a * length, b * width, -height / 2, yaw, center))
                points.append(worldPoint(a * length, b * width, height / 2, yaw, center))
                points.append(worldPoint(-length / 2, a * width, b * height, yaw, center))
                points.append(worldPoint(length / 2, a * width, b * height, yaw, center))
                points.append(worldPoint(a * length, -width / 2, b * height, yaw, center))
                points.append(worldPoint(a * length, width / 2, b * height, yaw, center))
            }
        }
        return points
    }

    private func cuboidCornerPoints(
        length: Float,
        width: Float,
        height: Float,
        yaw: Float
    ) -> [SIMD3<Float>] {
        [-0.5 as Float, 0.5].flatMap { xSign in
            [-0.5 as Float, 0.5].flatMap { zSign in
                [-0.5 as Float, 0.5].map { ySign in
                    worldPoint(
                        xSign * length,
                        zSign * width,
                        ySign * height,
                        yaw,
                        .zero
                    )
                }
            }
        }
    }

    private func worldPoint(
        _ localLength: Float,
        _ localWidth: Float,
        _ localHeight: Float,
        _ yaw: Float,
        _ center: SIMD3<Float>
    ) -> SIMD3<Float> {
        let cosine = cos(yaw)
        let sine = sin(yaw)
        return SIMD3<Float>(
            center.x + localLength * cosine - localWidth * sine,
            center.y + localHeight,
            center.z + localLength * sine + localWidth * cosine
        )
    }
}
