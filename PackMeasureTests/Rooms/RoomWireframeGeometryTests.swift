import XCTest
@testable import PackMeasure

final class RoomWireframeGeometryTests: XCTestCase {
    private let size = CGSize(width: 402, height: 440)

    private func wall(_ a: SIMD2<Float>, _ b: SIMD2<Float>, height: Float = 2.74) -> MeasuredRoom.Wall {
        .init(id: UUID(), start: a, end: b, height: height, confidence: "high")
    }

    private var closet: [MeasuredRoom.Wall] {
        [wall([0, 0], [1.42, 0]), wall([1.42, 0], [1.42, 1.16]),
         wall([1.42, 1.16], [0, 1.16]), wall([0, 1.16], [0, 0])]
    }

    func testClosetFitsWithDistinctFloorAndTopAndKeepsRecordedDimensions() throws {
        let walls = closet
        let room = try MeasuredRoom(walls: walls)
        let geometry = RoomWireframeGeometry(walls: walls, size: size)
        XCTAssertEqual(geometry.faces.count, 4)
        for face in geometry.faces {
            XCTAssertEqual(face.corners.count, 4)
            for p in face.corners { XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: 30, dy: 30).contains(p)) }
            XCTAssertEqual(face.corners[0].x, face.corners[3].x, accuracy: 0.001)
            XCTAssertGreaterThan(face.corners[0].y, face.corners[3].y)
        }
        XCTAssertEqual(room.spanLength, 1.42, accuracy: 0.001)
        XCTAssertEqual(room.spanWidth, 1.16, accuracy: 0.001)
        XCTAssertEqual(room.wallHeight, 2.74, accuracy: 0.001)
    }

    func testTranslationDoesNotChangeTheRendering() {
        let walls = closet
        let shifted = walls.map { wall($0.start + SIMD2(100, -50), $0.end + SIMD2(100, -50), height: $0.height) }
        let a = RoomWireframeGeometry(walls: walls, size: size).faces.sorted { $0.index < $1.index }
        let b = RoomWireframeGeometry(walls: shifted, size: size).faces.sorted { $0.index < $1.index }
        for (first, second) in zip(a, b) {
            for (p, q) in zip(first.corners, second.corners) {
                XCTAssertEqual(p.x, q.x, accuracy: 0.002)
                XCTAssertEqual(p.y, q.y, accuracy: 0.002)
            }
        }
    }

    func testIndividualWallHeightsAreNotReplacedWithMaximum() throws {
        let geometry = RoomWireframeGeometry(walls: [wall([0, 0], [2, 0], height: 1), wall([2, 0], [2, 2], height: 3)], size: size)
        let short = try XCTUnwrap(geometry.faces.first { $0.index == 0 })
        let tall = try XCTUnwrap(geometry.faces.first { $0.index == 1 })
        XCTAssertEqual((tall.corners[0].y - tall.corners[3].y) / (short.corners[0].y - short.corners[3].y), 3, accuracy: 0.001)
    }

    func testConcaveRoomRetainsEveryWallAndDoesNotClosePartialGaps() throws {
        let points: [SIMD2<Float>] = [[0, 0], [4, 0], [4, 2], [2, 2], [2, 4], [0, 4]]
        let walls = points.indices.map { wall(points[$0], points[($0 + 1) % points.count]) }
        let geometry = RoomWireframeGeometry(walls: walls, size: size)
        XCTAssertEqual(Set(geometry.faces.map(\.index)), Set(0..<6))
        // Neighbouring projected endpoints coincide even at the inward corner.
        let ordered = geometry.faces.sorted { $0.index < $1.index }
        for i in ordered.indices {
            XCTAssertEqual(ordered[i].corners[1], ordered[(i + 1) % ordered.count].corners[0])
        }
        let partial = RoomWireframeGeometry(walls: Array(walls.prefix(3)), size: size)
        XCTAssertEqual(partial.faces.count, 3)
        let first = try XCTUnwrap(partial.faces.first { $0.index == 0 })
        let last = try XCTUnwrap(partial.faces.first { $0.index == 2 })
        XCTAssertNotEqual(first.corners[0], last.corners[1])
    }

    func testSelectionWorksOnTopFloorAndVerticalEdgesAfterRotationAndZoom() throws {
        let geometry = RoomWireframeGeometry(walls: [wall([0, 0], [2, 0])], size: size, yaw: 0.3, pitch: 0.6, zoom: 1.7)
        let face = try XCTUnwrap(geometry.faces.first)
        for (a, b) in face.edges {
            let midpoint = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            XCTAssertEqual(geometry.nearestWall(to: midpoint, tolerance: 1), 0)
        }
        XCTAssertNil(geometry.nearestWall(to: CGPoint(x: -1000, y: -1000)))
    }

    func testZoomScalesAboutViewportCenter() {
        let fit = RoomWireframeGeometry(walls: closet, size: size)
        let zoom = RoomWireframeGeometry(walls: closet, size: size, zoom: 2)
        for (a, b) in zip(fit.faces, zoom.faces) {
            for (p, q) in zip(a.corners, b.corners) {
                XCTAssertEqual(q.x - size.width / 2, 2 * (p.x - size.width / 2), accuracy: 0.001)
                XCTAssertEqual(q.y - size.height / 2, 2 * (p.y - size.height / 2), accuracy: 0.001)
            }
        }
    }

    func testLabelsAvoidEachOtherAndHeightBadgeWithSelectionPriority() {
        let geometry = RoomWireframeGeometry(walls: closet, size: size)
        let reserved = CGRect(x: 300, y: 150, width: 80, height: 26)
        let labels = geometry.labels(sizes: closet.map { _ in CGSize(width: 84, height: 26) }, selected: 2,
                                     viewport: CGRect(origin: .zero, size: size), avoiding: reserved)
        XCTAssertEqual(labels.first?.index, 2)
        XCTAssertEqual(labels.count, 4)
        for (i, label) in labels.enumerated() {
            XCTAssertFalse(label.rect.intersects(reserved))
            for other in labels.dropFirst(i + 1) { XCTAssertFalse(label.rect.intersects(other.rect)) }
        }
    }

    func testLengthLabelsStayAnchoredToFloorEdgesAfterRotation() throws {
        for yaw: Float in [-0.1, .pi / 4, .pi / 2] {
            let geometry = RoomWireframeGeometry(walls: closet, size: size, yaw: yaw)
            let labels = geometry.labels(sizes: closet.map { _ in CGSize(width: 84, height: 26) }, selected: nil,
                                         viewport: CGRect(origin: .zero, size: size))
            XCTAssertEqual(labels.count, 4)
            for label in labels {
                let face = try XCTUnwrap(geometry.faces.first { $0.index == label.index })
                XCTAssertEqual(label.anchor.x, (face.corners[0].x + face.corners[1].x) / 2, accuracy: 0.001)
                XCTAssertEqual(label.anchor.y, (face.corners[0].y + face.corners[1].y) / 2, accuracy: 0.001)
                XCTAssertGreaterThan(label.anchor.y, (face.corners[2].y + face.corners[3].y) / 2)
            }
        }
    }

    func testEmptyDegenerateAndInvalidWallsAreSafeAndKeepOriginalIndices() {
        XCTAssertTrue(RoomWireframeGeometry(walls: [], size: size).faces.isEmpty)
        XCTAssertTrue(RoomWireframeGeometry(walls: closet, size: .zero).faces.isEmpty)
        let geometry = RoomWireframeGeometry(walls: [wall([0, 0], [0, 0]), wall([0, 0], [2, 0]),
                                                    wall([.nan, 0], [1, 0])], size: size)
        XCTAssertEqual(geometry.faces.map(\.index), [1])
        XCTAssertTrue(geometry.faces.flatMap(\.corners).allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
}
