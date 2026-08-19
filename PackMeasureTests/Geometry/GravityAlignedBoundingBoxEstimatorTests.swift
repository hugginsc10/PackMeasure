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

    func testTrimsDenseHorizontalSilhouetteHaloWithoutChangingHeight() throws {
        let boxLength: Float = 0.6096 // 24 inches
        let boxWidth: Float = 0.508 // 20 inches
        let boxHeight: Float = 0.508 // 20 inches
        let yaw: Float = 0.31
        let center = SIMD3<Float>(0, boxHeight / 2, 0)
        let box = cuboidSurfacePoints(
            length: boxLength,
            width: boxWidth,
            height: boxHeight,
            yaw: yaw,
            center: center,
            subdivisions: 30
        )
        let halo = horizontalSilhouetteHaloPoints(
            length: 0.7112, // observed false 28-inch length
            width: 0.6096, // observed false 24-inch width
            height: boxHeight,
            yaw: yaw,
            center: center,
            perimeterSubdivisions: 30
        )

        let estimate = try estimator.estimate(points: box + halo)
        let inches = estimate.dimensions.converted(to: .inches)

        XCTAssertGreaterThanOrEqual(inches.length, 23.9)
        XCTAssertLessThanOrEqual(inches.length, 25.0)
        XCTAssertGreaterThanOrEqual(inches.width, 19.9)
        XCTAssertLessThanOrEqual(inches.width, 21.0)
        XCTAssertEqual(inches.height, 20, accuracy: 0.1)
    }

    func testPreservesSparseFurnitureHandleProtrusion() throws {
        let boxLength: Float = 0.6096
        let boxWidth: Float = 0.508
        let boxHeight: Float = 0.508
        let yaw: Float = 0.22
        let center = SIMD3<Float>(0, boxHeight / 2, 0)
        let body = cuboidSurfacePoints(
            length: boxLength,
            width: boxWidth,
            height: boxHeight,
            yaw: yaw,
            center: center,
            subdivisions: 20
        )
        let handleLength: Float = 0.0508 // a real two-inch protrusion
        let handleCenter = worldPoint(
            boxLength / 2 + handleLength / 2,
            0,
            0,
            yaw,
            center
        )
        let sparseHandle = cuboidSurfacePoints(
            length: handleLength,
            width: 0.10,
            height: 0.10,
            yaw: yaw,
            center: handleCenter,
            subdivisions: 2
        )

        let estimate = try estimator.estimate(points: body + sparseHandle)
        let inches = estimate.dimensions.converted(to: .inches)

        XCTAssertGreaterThanOrEqual(inches.length, 25.5)
        XCTAssertEqual(inches.width, 20, accuracy: 0.5)
        XCTAssertEqual(inches.height, 20, accuracy: 0.5)
    }

    func testPreservesSparseVerticalFurnitureProtrusions() throws {
        let bodyLength: Float = 0.6096
        let bodyWidth: Float = 0.508
        let bodyHeight: Float = 0.508
        let protrusionLength: Float = 0.0508
        let protrusionHeight: Float = 0.381
        let yaw: Float = 0.22
        let center = SIMD3<Float>(0, bodyHeight / 2, 0)
        let body = cuboidSurfacePoints(
            length: bodyLength,
            width: bodyWidth,
            height: bodyHeight,
            yaw: yaw,
            center: center,
            subdivisions: 20
        )
        let protrusionY = -bodyHeight / 2 + protrusionHeight / 2
        let leftCenter = worldPoint(
            -(bodyLength + protrusionLength) / 2,
            0,
            protrusionY,
            yaw,
            center
        )
        let rightCenter = worldPoint(
            (bodyLength + protrusionLength) / 2,
            0,
            protrusionY,
            yaw,
            center
        )
        let leftProtrusion = cuboidSurfacePoints(
            length: protrusionLength,
            width: 0.05,
            height: protrusionHeight,
            yaw: yaw,
            center: leftCenter,
            subdivisions: 2
        )
        let rightProtrusion = cuboidSurfacePoints(
            length: protrusionLength,
            width: 0.05,
            height: protrusionHeight,
            yaw: yaw,
            center: rightCenter,
            subdivisions: 2
        )

        let estimate = try estimator.estimate(
            points: body + leftProtrusion + rightProtrusion
        )
        let inches = estimate.dimensions.converted(to: .inches)

        XCTAssertGreaterThanOrEqual(inches.length, 27.5)
        XCTAssertEqual(inches.width, 20, accuracy: 0.5)
        XCTAssertEqual(inches.height, 20, accuracy: 0.5)
    }

    func testKeepsDensePartialBoxDimensionsConservative() throws {
        let points = partialBoxPoints(
            length: 0.6096,
            width: 0.508,
            height: 0.508,
            yaw: 0.37,
            center: SIMD3<Float>(0.15, 0.254, -0.20),
            subdivisions: 18
        )

        let estimate = try estimator.estimate(points: points)

        assertDimensions(
            estimate.dimensions,
            0.6096,
            0.508,
            0.508,
            accuracy: 0.0127 // within half an inch without requiring hidden faces
        )
    }

    func testRecoversKnownBoxFromGroundSkirtAndBackgroundWall() throws {
        let boxLength: Float = 0.6096 // 24 inches
        let boxWidth: Float = 0.508 // 20 inches
        let boxHeight: Float = 0.508 // 20 inches
        let box = cuboidSurfacePoints(
            length: boxLength,
            width: boxWidth,
            height: boxHeight,
            yaw: 0.31,
            center: SIMD3<Float>(0, boxHeight / 2, 0),
            subdivisions: 10
        )
        let leakedFloor = horizontalPlanePoints(
            length: 2.03, // 80 inches: one of the observed false lengths
            width: 1.20, // 47 inches: the repeated observed false width
            y: -0.01,
            yaw: 0,
            lengthSubdivisions: 40,
            widthSubdivisions: 24
        )
        let backgroundWall = verticalPlanePoints(
            length: 1.80,
            height: 0.70,
            yBase: -0.01,
            z: 0.72,
            lengthSubdivisions: 30,
            heightSubdivisions: 14
        )

        let estimate = try estimator.estimate(
            points: box + leakedFloor + backgroundWall
        )

        assertDimensions(
            estimate.dimensions,
            Double(boxLength),
            Double(boxWidth),
            Double(boxHeight),
            accuracy: 0.0254 // recover within one inch
        )
        XCTAssertNotEqual(estimate.confidence.level, .high)
    }

    func testRejectsGroundRecoveryWhenTwoRaisedObjectsArePlausible() {
        let firstBox = cuboidSurfacePoints(
            length: 0.50,
            width: 0.40,
            height: 0.50,
            yaw: 0.18,
            center: SIMD3<Float>(-0.45, 0.25, 0),
            subdivisions: 8
        )
        let secondBox = cuboidSurfacePoints(
            length: 0.48,
            width: 0.38,
            height: 0.52,
            yaw: -0.12,
            center: SIMD3<Float>(0.45, 0.26, 0.05),
            subdivisions: 8
        )
        let leakedFloor = horizontalPlanePoints(
            length: 2.03,
            width: 1.20,
            y: -0.01,
            yaw: 0,
            lengthSubdivisions: 40,
            widthSubdivisions: 24
        )

        XCTAssertThrowsError(
            try estimator.estimate(points: firstBox + secondBox + leakedFloor)
        )
    }

    func testRejectsDenseRoomCornerMasqueradingAsHighConfidenceBox() {
        let knownBox = cuboidSurfacePoints(
            length: 0.6096, // 24 inches
            width: 0.508, // 20 inches
            height: 0.508, // 20 inches
            yaw: 0,
            center: SIMD3<Float>(0, 0.254, 0),
            subdivisions: 14
        )
        let sceneLength: Float = 1.4732 // observed false 58-inch length
        let sceneWidth: Float = 1.1176 // observed false 44-inch width
        let sceneHeight: Float = 0.6096 // observed false 24-inch height
        let leakedFloor = horizontalPlanePoints(
            length: sceneLength,
            width: sceneWidth,
            y: 0,
            yaw: 0,
            lengthSubdivisions: 100,
            widthSubdivisions: 75
        )
        let backgroundWall = verticalPlanePoints(
            length: sceneLength,
            height: sceneHeight,
            yBase: 0,
            z: sceneWidth / 2,
            lengthSubdivisions: 100,
            heightSubdivisions: 40
        )
        let sideWall = sideVerticalPlanePoints(
            width: sceneWidth,
            height: sceneHeight,
            yBase: 0,
            x: sceneLength / 2,
            widthSubdivisions: 75,
            heightSubdivisions: 40
        )

        let result = Result {
            try estimator.estimate(
                points: knownBox + leakedFloor + backgroundWall + sideWall
            )
        }

        switch result {
        case .success(let estimate):
            let dimensions = estimate.dimensions.converted(to: .inches)
            XCTFail(
                "Accepted scene envelope as \(dimensions.length)x\(dimensions.width)x"
                    + "\(dimensions.height) inches at \(estimate.confidence.level) confidence"
            )
        case .failure(let error):
            XCTAssertEqual(
                error as? BoundingBoxEstimationError,
                .groundPlaneContamination
            )
        }
    }

    func testAcceptsDenseBottomSurfaceWhenItMatchesRaisedObjectFootprint() throws {
        let length: Float = 0.6096
        let width: Float = 0.508
        let height: Float = 0.508
        let yaw: Float = 0.31
        let box = cuboidSurfacePoints(
            length: length,
            width: width,
            height: height,
            yaw: yaw,
            center: SIMD3<Float>(0, height / 2, 0),
            subdivisions: 8
        )
        let denseBottom = horizontalPlanePoints(
            length: length,
            width: width,
            y: 0,
            yaw: yaw,
            lengthSubdivisions: 40,
            widthSubdivisions: 34
        )

        let estimate = try estimator.estimate(points: box + denseBottom)

        assertDimensions(
            estimate.dimensions,
            Double(length),
            Double(width),
            Double(height),
            accuracy: 0.012
        )
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

    private func partialBoxPoints(
        length: Float,
        width: Float,
        height: Float,
        yaw: Float,
        center: SIMD3<Float>,
        subdivisions: Int
    ) -> [SIMD3<Float>] {
        let samples = (0...subdivisions).map { index in
            -0.5 + Float(index) / Float(subdivisions)
        }
        var points: [SIMD3<Float>] = []

        for first in samples {
            for second in samples {
                points.append(worldPoint(
                    first * length,
                    second * width,
                    height / 2,
                    yaw,
                    center
                ))
                points.append(worldPoint(
                    length / 2,
                    first * width,
                    second * height,
                    yaw,
                    center
                ))
                points.append(worldPoint(
                    -length / 2,
                    first * width,
                    second * height,
                    yaw,
                    center
                ))
                points.append(worldPoint(
                    first * length,
                    width / 2,
                    second * height,
                    yaw,
                    center
                ))
            }
        }
        return points
    }

    private func horizontalSilhouetteHaloPoints(
        length: Float,
        width: Float,
        height: Float,
        yaw: Float,
        center: SIMD3<Float>,
        perimeterSubdivisions: Int
    ) -> [SIMD3<Float>] {
        (0...perimeterSubdivisions).flatMap { index in
            let ratio = -0.5 + Float(index) / Float(perimeterSubdivisions)
            return [
                worldPoint(-length / 2, ratio * width, height / 2, yaw, center),
                worldPoint(length / 2, ratio * width, height / 2, yaw, center),
                worldPoint(ratio * length, -width / 2, height / 2, yaw, center),
                worldPoint(ratio * length, width / 2, height / 2, yaw, center),
            ]
        }
    }

    private func horizontalPlanePoints(
        length: Float,
        width: Float,
        y: Float,
        yaw: Float,
        lengthSubdivisions: Int,
        widthSubdivisions: Int
    ) -> [SIMD3<Float>] {
        (0...lengthSubdivisions).flatMap { lengthIndex in
            (0...widthSubdivisions).map { widthIndex in
                let localLength = -length / 2
                    + length * Float(lengthIndex) / Float(lengthSubdivisions)
                let localWidth = -width / 2
                    + width * Float(widthIndex) / Float(widthSubdivisions)
                return worldPoint(localLength, localWidth, y, yaw, .zero)
            }
        }
    }

    private func verticalPlanePoints(
        length: Float,
        height: Float,
        yBase: Float,
        z: Float,
        lengthSubdivisions: Int,
        heightSubdivisions: Int
    ) -> [SIMD3<Float>] {
        (0...lengthSubdivisions).flatMap { lengthIndex in
            (0...heightSubdivisions).map { heightIndex in
                SIMD3<Float>(
                    -length / 2 + length * Float(lengthIndex) / Float(lengthSubdivisions),
                    yBase + height * Float(heightIndex) / Float(heightSubdivisions),
                    z
                )
            }
        }
    }

    private func sideVerticalPlanePoints(
        width: Float,
        height: Float,
        yBase: Float,
        x: Float,
        widthSubdivisions: Int,
        heightSubdivisions: Int
    ) -> [SIMD3<Float>] {
        (0...widthSubdivisions).flatMap { widthIndex in
            (0...heightSubdivisions).map { heightIndex in
                SIMD3<Float>(
                    x,
                    yBase + height * Float(heightIndex) / Float(heightSubdivisions),
                    -width / 2 + width * Float(widthIndex) / Float(widthSubdivisions)
                )
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
