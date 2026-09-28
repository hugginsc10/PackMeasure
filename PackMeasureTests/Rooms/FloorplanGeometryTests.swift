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

    func testLengthLabelsUseSavedLengthAndKeepWallIDsAvailable() {
        let sample = wall([10, 20], [13.81, 20])
        XCTAssertEqual(FloorplanLabelMode.lengths.text(for: sample, index: 18), "12.5 ft")
        XCTAssertEqual(FloorplanLabelMode.wallIDs.text(for: sample, index: 18), "19")
        XCTAssertEqual(FloorplanLabelMode.lengths.text(for: wall([0, 0], [0.16, 0]), index: 0), "0.5 ft")
    }

    func testLengthBadgeSizesDriveCollisionAndSelectedHitRegion() {
        let walls = (0..<12).map { i in wall([Float(i), 0], [Float(i + 1), 0]) }
        let geometry = FloorplanGeometry(walls: walls, size: CGSize(width: 350, height: 300))
        let sizes = walls.map { _ in CGSize(width: 80, height: 26) }
        let labels = geometry.labels(zoom: 1, selected: 5, sizes: sizes)
        XCTAssertEqual(labels.first?.index, 5)
        XCTAssertEqual(labels.first?.rect.width, 80)
        XCTAssertTrue(labels[0].rect.contains(CGPoint(x: labels[0].rect.maxX - 1, y: labels[0].rect.midY)))
        XCTAssertLessThan(labels.count, geometry.labels(zoom: 1, selected: 5).count)
        let zoomed = geometry.transformed(zoom: 4, offset: .zero).labels(zoom: 1, selected: 5, sizes: sizes)
        XCTAssertGreaterThan(zoomed.count, labels.count)
        for (index, label) in labels.enumerated() {
            for other in labels.dropFirst(index + 1) { XCTAssertFalse(label.rect.intersects(other.rect)) }
        }
    }

    func testEmptyGeometryHasNoSelectableWallsOrLabels() {
        let geometry = FloorplanGeometry(walls: [], size: CGSize(width: 300, height: 500))
        XCTAssertNil(geometry.nearestWall(to: .zero, tolerance: 22))
        XCTAssertTrue(geometry.labels(zoom: 1, selected: nil).isEmpty)
    }
}
