import XCTest
import simd
@testable import PackMeasure

final class RoomMeasurementTests: XCTestCase {
    func testRotatedAndTranslatedRoomKeepsMetricDimensions() throws {
        for yaw: Float in [0, 0.43, 1.2, 2.8] {
            let room = try MeasuredRoom(walls: rectangle(yaw: yaw))
            XCTAssertEqual(room.spanLength, 5, accuracy: 0.0001)
            XCTAssertEqual(room.spanWidth, 3, accuracy: 0.0001)
            XCTAssertEqual(room.wallHeight, 2.4, accuracy: 0.0001)
            assertLengthsEqual(room.walls.map(\.length).sorted(), [3, 3, 5, 5], accuracy: 0.0001)
        }
    }

    func testPreservesPartialScanInsteadOfDiscardingDetectedWalls() throws {
        for count in [1, 2] {
            let room = try MeasuredRoom(walls: Array(rectangle().prefix(count)))
            XCTAssertEqual(room.walls.count, count)
            XCTAssertFalse(room.hasRoomExtent)
            XCTAssertTrue(room.shareText.contains("Partial scan"))
            XCTAssertFalse(room.shareText.contains("Scanned span:"))
        }
    }

    func testRejectsOnlyWhenThereAreNoUsableWalls() throws {
        XCTAssertThrowsError(try MeasuredRoom(walls: []))
        let invalid = MeasuredRoom.Wall(id: UUID(), start: SIMD2(.nan, 0), end: SIMD2(1, 0), height: 2, confidence: "high")
        XCTAssertThrowsError(try MeasuredRoom(walls: [invalid])) { error in
            XCTAssertTrue(error.localizedDescription.contains("1 wall(s)"))
        }
        let room = try MeasuredRoom(walls: rectangle() + [invalid])
        XCTAssertEqual(room.walls.count, 4)
        XCTAssertEqual(room.excludedWallCount, 1)
        XCTAssertFalse(room.hasRoomExtent)
        XCTAssertTrue(room.shareText.contains("1 unusable"))
    }

    func testCollinearWallsRemainAvailableWithoutClaimingRoomWidth() throws {
        let line = MeasuredRoom.Wall(id: UUID(), start: .zero, end: SIMD2(5, 0), height: 2, confidence: "high")
        let room = try MeasuredRoom(walls: [line, line, line])
        XCTAssertFalse(room.hasRoomExtent)
        XCTAssertFalse(room.shareText.contains("Scanned span:"))
    }

    func testBuild43SavedRoomsStillDecode() throws {
        let room = try MeasuredRoom(walls: rectangle())
        let data = try JSONEncoder().encode(room)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "excludedWallCount")
        let restored = try JSONDecoder().decode(MeasuredRoom.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(restored.hasRoomExtent)
        XCTAssertEqual(restored.id, room.id)
    }

    func testIrregularOutlineRetainsIndividualWallsAndDoesNotClaimFloorArea() throws {
        let corners: [SIMD2<Float>] = [[0, 0], [5, 0], [5, 2], [2, 2], [2, 4], [0, 4]]
        let room = try MeasuredRoom(walls: walls(corners))
        XCTAssertEqual(room.walls.count, 6)
        XCTAssertEqual(room.spanLength, 5, accuracy: 0.001)
        XCTAssertEqual(room.spanWidth, 4, accuracy: 0.001)
        XCTAssertTrue(room.shareText.contains("Not floor area"))
    }

    func testRoomStorageRoundTripAndSeparateScans() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomScanStore(directory: directory)
        XCTAssertTrue(try store.load().isEmpty)
        let first = try MeasuredRoom(walls: rectangle(), name: "Bedroom", date: Date(timeIntervalSince1970: 1))
        let second = try MeasuredRoom(walls: rectangle(yaw: 1), name: "Office", date: Date(timeIntervalSince1970: 2))
        try store.save(first)
        try store.save(second)
        let loaded = try store.load()
        XCTAssertEqual(loaded.map(\.id), [second.id, first.id])
        XCTAssertEqual(loaded.map(\.name), ["Office", "Bedroom"])
        XCTAssertEqual(loaded[1].spanWidth, 3, accuracy: 0.001)
    }

    func testCorruptRoomFileSurfacesAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomScanStore(directory: directory)
        try store.save(MeasuredRoom(walls: rectangle()))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("broken.json"))
        XCTAssertThrowsError(try store.load())
    }

    private func rectangle(yaw: Float = 0) -> [MeasuredRoom.Wall] {
        let points: [SIMD2<Float>] = [[0, 0], [5, 0], [5, 3], [0, 3]]
        return walls(points.map { p in
            SIMD2(cos(yaw) * p.x - sin(yaw) * p.y + 10,
                  sin(yaw) * p.x + cos(yaw) * p.y - 7)
        })
    }

    private func walls(_ points: [SIMD2<Float>]) -> [MeasuredRoom.Wall] {
        points.indices.map { index in
            MeasuredRoom.Wall(id: UUID(), start: points[index], end: points[(index + 1) % points.count], height: 2.4, confidence: "high")
        }
    }
}

private extension XCTestCase {
    func assertLengthsEqual(_ actual: [Float], _ expected: [Float], accuracy: Float, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(actual.count == expected.count && zip(actual, expected).allSatisfy { abs($0 - $1) < accuracy }, file: file, line: line)
    }
}
