import XCTest
@testable import PackMeasure

final class RoomWallSelectionTests: XCTestCase {
    private func wall(_ start: SIMD2<Float>, _ end: SIMD2<Float>, height: Float = 2.76, confidence: String = "high") -> MeasuredRoom.Wall {
        .init(id: UUID(), start: start, end: end, height: height, confidence: confidence)
    }

    private func contaminatedCloset() throws -> MeasuredRoom {
        try MeasuredRoom(walls: [wall([0, 0], [1.42, 0]), wall([1.42, 0], [1.42, 1.16]),
                                 wall([1.42, 1.16], [0, 1.16]), wall([0, 1.16], [0, 0], confidence: "low"),
                                 wall([0, 0], [-3, 0], height: 3.69), wall([-3, 0], [-3, -2], height: 3.69)],
                         name: "Closet", date: Date(timeIntervalSince1970: 100))
    }

    func testRemovingOutsideWallsRecalculatesSpansAndHeightFromOnlyKeptWalls() throws {
        let original = try contaminatedCloset()
        let kept = try original.keepingWalls(Set(original.walls.prefix(4).map(\.id)))
        XCTAssertEqual(kept.walls.count, 4)
        XCTAssertEqual(kept.spanLength, 1.42, accuracy: 0.001)
        XCTAssertEqual(kept.spanWidth, 1.16, accuracy: 0.001)
        XCTAssertEqual(kept.wallHeight, 2.76, accuracy: 0.001)
        XCTAssertEqual(kept.omittedWallCount, 2)
        XCTAssertEqual(kept.excludedWallCount, 0)
        XCTAssertTrue(kept.hasRoomExtent)
        XCTAssertFalse(kept.shareText.contains("3.69"))
        XCTAssertNotNil(original.heightReviewMessage)
        XCTAssertNil(kept.heightReviewMessage)
        XCTAssertEqual(original.walls.count, 6)
    }

    func testSelectionPreservesStableIdentityOrderDimensionsAndConfidence() throws {
        let original = try contaminatedCloset()
        let kept = try original.keepingWalls([original.walls[3].id, original.walls[1].id])
        XCTAssertEqual(kept.id, original.id)
        XCTAssertEqual(kept.name, original.name)
        XCTAssertEqual(kept.date, original.date)
        XCTAssertEqual(kept.walls.map(\.id), [original.walls[1].id, original.walls[3].id])
        for (actual, expected) in zip(kept.walls, [original.walls[1], original.walls[3]]) {
            XCTAssertEqual(actual.start, expected.start)
            XCTAssertEqual(actual.end, expected.end)
            XCTAssertEqual(actual.height, expected.height)
            XCTAssertEqual(actual.confidence, expected.confidence)
        }
        XCTAssertFalse(kept.hasRoomExtent)
        XCTAssertFalse(kept.shareText.contains("Scanned span:"))
    }

    func testNoWallAndUnknownIDsCannotBecomeASavableRoom() throws {
        let room = try contaminatedCloset()
        XCTAssertThrowsError(try room.keepingWalls([]))
        XCTAssertThrowsError(try room.keepingWalls([UUID()]))
        let kept = try room.keepingWalls([UUID(), room.walls[0].id])
        XCTAssertEqual(kept.walls.map(\.id), [room.walls[0].id])
        XCTAssertFalse(kept.hasRoomExtent)
    }

    func testRestoreAllUsesOriginalScanWithoutAccumulatingOmissions() throws {
        let original = try contaminatedCloset()
        _ = try original.keepingWalls([original.walls[0].id])
        let restored = try original.keepingWalls(Set(original.walls.map(\.id)))
        XCTAssertEqual(restored.omittedWallCount, 0)
        XCTAssertEqual(restored.walls.map(\.id), original.walls.map(\.id))
        XCTAssertEqual(restored.spanLength, original.spanLength)
        XCTAssertEqual(restored.wallHeight, original.wallHeight)
    }

    func testUnusableCaptureProvenanceSurvivesReviewWithoutCountingIntentionalOmissionsAsInvalid() throws {
        let valid = try contaminatedCloset().walls
        let original = try MeasuredRoom(walls: valid + [wall([0, 0], [0, 0])])
        let kept = try original.keepingWalls(Set(valid.prefix(4).map(\.id)))
        XCTAssertEqual(kept.excludedWallCount, 1)
        XCTAssertEqual(kept.omittedWallCount, 2)
        XCTAssertFalse(kept.hasRoomExtent)
    }

    func testSavedSelectionAndShareUseOnlyKeptGeometry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomScanStore(directory: directory)
        let original = try contaminatedCloset()
        let kept = try original.keepingWalls(Set(original.walls.prefix(4).map(\.id)))
        try store.save(kept)
        let restored = try XCTUnwrap(store.load().first)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.walls.map(\.id), kept.walls.map(\.id))
        XCTAssertEqual(restored.omittedWallCount, 2)
        XCTAssertEqual(restored.shareText, kept.shareText)
        XCTAssertFalse(restored.shareText.contains("Wall 5:"))
        XCTAssertFalse(restored.shareText.contains("3.69"))
        XCTAssertTrue(restored.shareText.contains("2 wall(s) left out"))
    }

    func testOlderSavedRoomsWithoutSelectionMetadataStillDecode() throws {
        let original = try contaminatedCloset()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "omittedWallCount")
        let decoded = try JSONDecoder().decode(MeasuredRoom.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.omittedWallCount)
        XCTAssertEqual(decoded.walls.map(\.id), original.walls.map(\.id))
        XCTAssertEqual(decoded.spanLength, original.spanLength)
    }

    func testUniformAndSmallHeightDifferencesDoNotClaimACeilingProblem() throws {
        let room = try MeasuredRoom(walls: [wall([0, 0], [1, 0], height: 2.76), wall([1, 0], [1, 1], height: 2.85)])
        XCTAssertNil(room.heightReviewMessage)
    }
}
