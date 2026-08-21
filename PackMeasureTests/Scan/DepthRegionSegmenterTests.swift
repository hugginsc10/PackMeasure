import XCTest
@testable import PackMeasure

final class DepthRegionSegmenterTests: XCTestCase {
    func testSegmentsCenteredObjectAndRejectsDistantBackground() throws {
        var grid = DepthGrid.fixture(width: 15, height: 15, depth: 3.0)
        grid.fill(x: 4...10, y: 3...11, depth: 1.25, confidence: 2)

        let region = try XCTUnwrap(DepthRegionSegmenter().segment(grid))

        XCTAssertEqual(region.pixelCount, 63)
        XCTAssertEqual(region.bounds, PixelBounds(minX: 4, minY: 3, maxX: 10, maxY: 11))
        XCTAssertEqual(region.seedDepthMeters, 1.25, accuracy: 0.001)
        XCTAssertTrue(region.indices.allSatisfy { grid.depths[$0] < 2.0 })
    }

    func testFollowsGradualDepthAcrossVisibleSideButStopsAtEdge() throws {
        var grid = DepthGrid.fixture(width: 17, height: 11, depth: 3.5)
        for x in 3...13 {
            let slopedDepth = 1.1 + Float(abs(x - 8)) * 0.045
            grid.fill(x: x...x, y: 2...8, depth: slopedDepth, confidence: 2)
        }

        let region = try XCTUnwrap(DepthRegionSegmenter().segment(grid))

        XCTAssertEqual(region.bounds, PixelBounds(minX: 3, minY: 2, maxX: 13, maxY: 8))
        XCTAssertEqual(region.pixelCount, 77)
    }

    func testSegmentsRoundedSlopedSuitcaseAndExcludesFartherFloorAndBackground() throws {
        let width = 21
        let height = 17
        var grid = DepthGrid.fixture(width: width, height: height, depth: 3.4)
        grid.fill(x: 0...(width - 1), y: 14...16, depth: 2.45, confidence: 2)

        let silhouette: [Int: ClosedRange<Int>] = [
            3: 8...12,
            4: 6...14,
            5: 5...15,
            6: 4...16,
            7: 4...16,
            8: 4...16,
            9: 4...16,
            10: 4...16,
            11: 4...16,
            12: 5...15,
            13: 6...14,
        ]
        var expectedIndices = Set<Int>()
        for (y, xRange) in silhouette {
            for x in xRange {
                let slopedDepth = 1.12
                    + Float(abs(x - width / 2)) * 0.035
                    + Float(abs(y - height / 2)) * 0.008
                grid.set(x: x, y: y, depth: slopedDepth, confidence: 2)
                expectedIndices.insert(y * width + x)
            }
        }

        let region = try XCTUnwrap(DepthRegionSegmenter().segment(grid))

        XCTAssertEqual(Set(region.indices), expectedIndices)
        XCTAssertEqual(region.bounds, PixelBounds(minX: 4, minY: 3, maxX: 16, maxY: 13))
        XCTAssertTrue(region.contains(x: 10, y: 8, gridWidth: width))
        XCTAssertFalse(region.contains(x: 3, y: 8, gridWidth: width))
        XCTAssertFalse(region.contains(x: 10, y: 14, gridWidth: width))
    }

    func testExcludesLowConfidencePixelsEvenWhenDepthMatches() throws {
        var grid = DepthGrid.fixture(width: 13, height: 13, depth: 4.0)
        grid.fill(x: 3...9, y: 3...9, depth: 1.0, confidence: 2)
        grid.set(x: 3, y: 6, depth: 1.0, confidence: 0)
        grid.set(x: 9, y: 6, depth: 1.0, confidence: 0)

        let region = try XCTUnwrap(DepthRegionSegmenter(minimumConfidence: 1).segment(grid))

        XCTAssertEqual(region.pixelCount, 47)
        XCTAssertFalse(region.contains(x: 3, y: 6, gridWidth: grid.width))
        XCTAssertFalse(region.contains(x: 9, y: 6, gridWidth: grid.width))
    }

    func testFindsNearbyValidSeedWhenExactCenterIsMissing() throws {
        var grid = DepthGrid.fixture(width: 11, height: 11, depth: .nan, confidence: 0)
        grid.fill(x: 2...8, y: 2...8, depth: 1.4, confidence: 2)
        grid.set(x: 5, y: 5, depth: .nan, confidence: 0)

        let region = try XCTUnwrap(DepthRegionSegmenter().segment(grid))

        XCTAssertEqual(region.pixelCount, 48)
        XCTAssertEqual(region.seedDepthMeters, 1.4, accuracy: 0.001)
    }

    func testReturnsNilWhenNoConfidentCenterSeedExists() {
        let grid = DepthGrid.fixture(width: 9, height: 9, depth: .nan, confidence: 0)

        XCTAssertNil(DepthRegionSegmenter().segment(grid))
    }
}

private extension DepthGrid {
    static func fixture(
        width: Int,
        height: Int,
        depth: Float,
        confidence: UInt8 = 2
    ) -> DepthGrid {
        DepthGrid(
            width: width,
            height: height,
            depths: Array(repeating: depth, count: width * height),
            confidences: Array(repeating: confidence, count: width * height)
        )
    }

    mutating func fill(
        x xRange: ClosedRange<Int>,
        y yRange: ClosedRange<Int>,
        depth: Float,
        confidence: UInt8
    ) {
        for y in yRange {
            for x in xRange {
                set(x: x, y: y, depth: depth, confidence: confidence)
            }
        }
    }

    mutating func set(x: Int, y: Int, depth: Float, confidence: UInt8) {
        let index = y * width + x
        depths[index] = depth
        confidences[index] = confidence
    }
}
