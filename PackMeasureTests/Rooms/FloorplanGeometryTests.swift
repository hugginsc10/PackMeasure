import XCTest
@testable import PackMeasure

final class FloorplanGeometryTests: XCTestCase {
    private func wall(_ start: SIMD2<Float>, _ end: SIMD2<Float>) -> MeasuredRoom.Wall {
        .init(id: UUID(), start: start, end: end, height: 2.4, confidence: "high")
    }

    func testProjectionFitsTranslatedPartialWallAndRetainsLength() {
        let walls = [wall([100, -20], [105, -20])]
        let geometry = FloorplanGeometry(walls: walls, size: CGSize(width: 300, height: 500))
        XCTAssertEqual(geometry.segments[0].start.x, 32, accuracy: 0.01)
        XCTAssertEqual(geometry.segments[0].end.x, 268, accuracy: 0.01)
        XCTAssertEqual(geometry.segments[0].start.y, 250, accuracy: 0.01)
        XCTAssertEqual(walls[0].length, 5)
    }

    func testSelectionUsesNearestSegmentWithScreenSpaceTolerance() {
        let geometry = FloorplanGeometry(walls: [wall([0, 0], [5, 0]), wall([5, 0], [5, 5])], size: CGSize(width: 300, height: 300))
        XCTAssertEqual(geometry.nearestWall(to: CGPoint(x: 150, y: 40), tolerance: 22), 0)
        XCTAssertNil(geometry.nearestWall(to: CGPoint(x: 150, y: 40), tolerance: 22 / 4))
        XCTAssertEqual(geometry.nearestWall(to: CGPoint(x: 264, y: 150), tolerance: 22 / 4), 1)
        XCTAssertNil(geometry.nearestWall(to: CGPoint(x: 150, y: 150), tolerance: 22))
        XCTAssertNil(geometry.nearestWall(to: CGPoint(x: 5, y: 32), tolerance: 22))
    }

    func testCrowdedLabelsDoNotOverlapAndZoomRevealsMore() {
        let walls = (0..<24).map { i in wall([Float(i) / 10, 0], [Float(i + 1) / 10, 0]) }
        let geometry = FloorplanGeometry(walls: walls, size: CGSize(width: 300, height: 300))
        let fit = geometry.labels(zoom: 1, selected: 12)
        let zoomed = geometry.labels(zoom: 8, selected: 12)
        XCTAssertEqual(fit.first?.index, 12)
        XCTAssertGreaterThan(zoomed.count, fit.count)
        for labels in [fit, zoomed] {
            for i in labels.indices {
                for j in labels.indices where i != j {
                    XCTAssertFalse(labels[i].rect.intersects(labels[j].rect))
                }
            }
        }
    }

    func testPannedZoomedWallSelectionAndBadgesStayInScreenCoordinates() {
        let geometry = FloorplanGeometry(walls: [wall([0, 0], [5, 0])], size: CGSize(width: 300, height: 300))
            .transformed(zoom: 4, offset: CGPoint(x: 400, y: 500))
        XCTAssertEqual(geometry.nearestWall(to: CGPoint(x: 200, y: 110), tolerance: 22), 0)
        XCTAssertNil(geometry.nearestWall(to: CGPoint(x: 200, y: 130), tolerance: 22))
        XCTAssertEqual(geometry.labels(zoom: 1, selected: 0)[0].rect.height, 24)
    }

    func testEmptyGeometryHasNoSelectableWallsOrLabels() {
        let geometry = FloorplanGeometry(walls: [], size: CGSize(width: 300, height: 500))
        XCTAssertNil(geometry.nearestWall(to: .zero, tolerance: 22))
        XCTAssertTrue(geometry.labels(zoom: 1, selected: nil).isEmpty)
    }
}
