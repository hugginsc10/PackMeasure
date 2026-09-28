import XCTest
import simd
@testable import PackMeasure

final class RoomShelfMeasurementTests: XCTestCase {
    let points: [SIMD3<Float>] = [[0.5,0,0.4],[0,1.2,0],[1,1.2,0],[0.5,1.2,0.4],[0.5,1.7,0.4]]
    let seed = SIMD3<Float>(0.5,1.2,0.2)
    func testShelfDepthUsesPerpendicularDistanceAndHeightUsesVerticalDifference() throws {
        var oblique = points; oblique[3].x = 0.8; oblique[4].x = 0.8
        let result = try ShelfGeometry(points: oblique, selectedTop: seed)
        XCTAssertEqual(result.depth, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.height, 1.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.clearance), 0.5, accuracy: 0.0001)
    }
    func testGeometrySurvivesCameraWorldTranslationAndYawRotation() throws {
        let rotate = simd_quatf(angle: 0.83, axis: [0,1,0])
        let offset = SIMD3<Float>(3,-2,4)
        let result = try ShelfGeometry(points: points.map { rotate.act($0)+offset }, selectedTop: rotate.act(seed)+offset)
        XCTAssertEqual(result.depth, 0.4, accuracy: 0.0001)
        XCTAssertEqual(result.height, 1.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(result.clearance), 0.5, accuracy: 0.0001)
    }
    func testReversingBackEdgeKeepsDepthAndLockContainment() throws {
        var reversed = points; reversed.swapAt(1,2)
        XCTAssertEqual(try ShelfGeometry(points: reversed, selectedTop: seed).depth, 0.4, accuracy: 0.0001)
    }
    func testSelectedBoxTopOrAdjacentSurfaceDoesNotMatchShelfGeometry() {
        XCTAssertThrowsError(try ShelfGeometry(points: points, selectedTop: seed + [0,0.2,0]))
        XCTAssertThrowsError(try ShelfGeometry(points: points, selectedTop: seed + [2,0,0]))
        XCTAssertThrowsError(try ShelfGeometry(points: points, selectedTop: seed + [0,0,1]))
        XCTAssertThrowsError(try ShelfGeometry(points: points, selectedTop: seed + [0,0,-1]))
    }
    func testRejectsShortBackReferenceNonlevelShelfAndImpossibleFloorOrUpperPoint() {
        var bad = points; bad[2] = bad[1] + [0.1,0,0]
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
        bad = points; bad[2].y += 0.1
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
        bad = points; bad[3].y += 0.1
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
        bad = points; bad[0].y = 2
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
        bad = points; bad[4].y = 1
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
        bad = points; bad[4].x += 0.3
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
        bad = points; bad[1].z = .nan
        XCTAssertThrowsError(try ShelfGeometry(points: bad))
    }
    func testClearanceCanBeOmittedWithoutInventingCeilingOrUpperShelf() throws {
        XCTAssertNil(try ShelfGeometry(points: Array(points.prefix(4)), selectedTop: seed).clearance)
    }
    func testAlignedDistanceSubtractionRejectsReversedNegativeAndNonfiniteInputs() throws {
        XCTAssertEqual(try RoomShelfMeasurement.depthFromDistances(back: 1.42, front: 1.02), 0.4, accuracy: 0.0001)
        for pair: (Float,Float) in [(1,2),(1,1),(1,-1),(.nan,0),(1,.infinity)] {
            XCTAssertThrowsError(try RoomShelfMeasurement.depthFromDistances(back: pair.0, front: pair.1))
        }
    }
    func testManualUnitsRoundTripNineFeetAndRejectAmbiguousOrExtremeInput() throws {
        var input = RoomLengthEntry(); input.feet = "9"; input.inches = "0"
        XCTAssertEqual(try XCTUnwrap(input.value(in: .imperial)), 2.7432, accuracy: 0.00001)
        try input.convert(from: .imperial)
        XCTAssertEqual(try XCTUnwrap(input.value(in: .metric)), 2.7432, accuracy: 0.00001)
        input.inches = "12"; XCTAssertThrowsError(try input.value(in: .imperial))
        input.inches = "0"; input.feet = "1.5"; XCTAssertThrowsError(try input.value(in: .imperial))
        input.feet = "9999999999999999999999999"; XCTAssertThrowsError(try input.value(in: .imperial))
        input.meters = "nan"; XCTAssertThrowsError(try input.value(in: .metric))
        input.meters = "2,7432"; XCTAssertEqual(try XCTUnwrap(input.value(in: .metric)), 2.7432, accuracy: 0.00001)
        XCTAssertNil(try RoomLengthEntry(Float.greatestFiniteMagnitude).value(in: .imperial))
        XCTAssertNil(try RoomLengthEntry().value(in: .imperial))
    }
    func testInchRoundingCarriesIntoFeetInsteadOfDisplayingTwelveInches() throws {
        let entry = RoomLengthEntry(0.3047999)
        XCTAssertEqual(entry.feet, "1")
        XCTAssertEqual(entry.inches, "0.00")
    }
    private func room() throws -> MeasuredRoom {
        try MeasuredRoom(walls: [
            .init(id: UUID(), start: [0,0], end: [1.42,0], height: 3.09, confidence: "high"),
            .init(id: UUID(), start: [1.42,0], end: [1.42,1.16], height: 3.09, confidence: "high"),
            .init(id: UUID(), start: [1.42,1.16], end: [0,1.16], height: 2.76, confidence: "high")])
    }
    func testEnteredCeilingChangesRenderingWithoutChangingCapturedWallDimensions() throws {
        var room = try room(); let walls = room.walls
        room.ceilingHeight = try RoomCeilingHeight(meters: 2.7432)
        XCTAssertEqual(room.wallHeight, 3.09)
        XCTAssertEqual(room.walls.map(\.height), walls.map(\.height))
        XCTAssertEqual(room.renderedWalls.map(\.height), [2.7432,2.7432,2.7432])
        XCTAssertEqual(room.renderedWalls.map(\.id), walls.map(\.id))
        XCTAssertEqual(room.displayedHeight, 2.7432)
        XCTAssertTrue(room.shareText.contains("entered manually"))
        room.ceilingHeight = nil
        XCTAssertEqual(room.renderedWalls.map(\.height), walls.map(\.height))
    }
    func testShelfAndCeilingPersistenceAndSelectionKeepOnlyAssignedRemainingWalls() throws {
        var room = try room()
        room.ceilingHeight = try RoomCeilingHeight(meters: 2.7432)
        let included = try RoomShelfMeasurement(name: "Keep", wallID: room.walls[0].id, depth: 0.4, heightAboveFloor: 1.2, clearanceAbove: 0.5, source: .manual)
        let excluded = try RoomShelfMeasurement(name: "Outside", wallID: room.walls[1].id, depth: 0.5, heightAboveFloor: 1, clearanceAbove: nil, source: .manual)
        let unassigned = try RoomShelfMeasurement(name: "Unassigned", depth: 0.3, heightAboveFloor: 0.4, clearanceAbove: nil, source: .manual)
        room.shelves = [included, excluded, unassigned]
        let kept = try room.keepingWalls([room.walls[0].id])
        XCTAssertEqual(kept.shelves?.map(\.name), ["Keep","Unassigned"])
        XCTAssertEqual(kept.ceilingHeight?.meters, 2.7432)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomScanStore(directory: directory); try store.save(kept)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.shareText, kept.shareText)
        XCTAssertEqual(loaded.shelves?.map(\.id), [included.id, unassigned.id])
        XCTAssertTrue(loaded.shareText.contains("clear space above not measured"))
    }
    func testOlderSavedRoomsWithoutAnnotationsDecodeAndRenderCapturedGeometry() throws {
        let original = try room()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String:Any])
        json.removeValue(forKey: "ceilingHeight"); json.removeValue(forKey: "shelves")
        let old = try JSONDecoder().decode(MeasuredRoom.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.ceilingHeight); XCTAssertNil(old.shelves)
        XCTAssertEqual(old.renderedWalls.map(\.height), original.walls.map(\.height))
    }
    func testInvalidMeasurementsCannotBeConstructedAndCalculationProvenanceIsExplicit() throws {
        XCTAssertThrowsError(try RoomCeilingHeight(meters: 0))
        XCTAssertThrowsError(try RoomCeilingHeight(meters: .nan))
        XCTAssertThrowsError(try RoomShelfMeasurement(name: "Bad", depth: -1, heightAboveFloor: 1, clearanceAbove: nil, source: .manual))
        XCTAssertThrowsError(try RoomShelfMeasurement(name: "Bad", depth: 0.2, heightAboveFloor: 1, clearanceAbove: 0, source: .manual))
        XCTAssertThrowsError(try RoomShelfMeasurement(name: "Bad", depth: 0.5, heightAboveFloor: 1, clearanceAbove: nil, source: .difference, referenceToBack: 2, referenceToFront: 1))
        let shelf = try RoomShelfMeasurement(name: "Calculated", depth: 0.4, heightAboveFloor: 1, clearanceAbove: 0.5, source: .difference, referenceToBack: 1.4, referenceToFront: 1)
        XCTAssertTrue(shelf.shareText.contains("Depth calculation:"))
        XCTAssertTrue(shelf.sourceLabel.contains("entered"))
    }
}

@MainActor final class ShelfScanStateTests: XCTestCase {
    private func capture(_ state: ShelfScanState, _ point: SIMD3<Float>, horizontal: Bool = true) {
        state.ready = true; state.request()
        for _ in 0..<5 { state.receive(point, horizontalSurface: horizontal, request: state.requestID) }
    }
    func testExplicitTapLocksRequestedSurfaceAndShelfPointsStayOnSelectedLevel() {
        let state = ShelfScanState(); state.ready = true
        state.request(at: [0.2,0.7])
        XCTAssertEqual(state.target, SIMD2<Float>(0.2,0.7))
        for _ in 0..<5 { state.receive([0.5,1.2,0.2], horizontalSurface: true, request: state.requestID) }
        XCTAssertNotNil(state.selectedTop)
        capture(state,[0.5,0,0.4])
        capture(state,[0,1.5,0]) // Box top / different shelf level.
        XCTAssertEqual(state.points.count,1)
        XCTAssertNotNil(state.error)
        capture(state,[0,1.2,0]); capture(state,[1,1.2,0]); capture(state,[0.5,1.2,0.4]); capture(state,[0.5,1.7,0.4])
        XCTAssertEqual(state.points.count,5)
        XCTAssertEqual(state.result?.depth,0.4)
    }
    func testWallBehindWireGapCannotLockAsHorizontalShelfTop() {
        let state = ShelfScanState(); capture(state,[0,1,0],horizontal:false)
        XCTAssertNil(state.selectedTop); XCTAssertNotNil(state.error)
    }
    func testFloorAndUndersideRejectVerticalFacesWithoutAdvancing() {
        let state = ShelfScanState(); capture(state,[0.5,1.2,0.2])
        capture(state,[0,0,0],horizontal:false)
        XCTAssertTrue(state.points.isEmpty)
        capture(state,[0,0,0]); capture(state,[0,1.2,0]); capture(state,[1,1.2,0]); capture(state,[0.5,1.2,0.4])
        capture(state,[0.5,1.7,0.4],horizontal:false)
        XCTAssertEqual(state.points.count,4); XCTAssertNil(state.result)
        capture(state,[0.5,1.7,0.4])
        XCTAssertNotNil(state.result)
    }
    func testUnstableSamplesFailLocallyWithoutSelectingAnotherSurface() {
        let state = ShelfScanState(); state.ready = true; state.request(at:[0.1,0.2])
        state.receive([0,1,0],horizontalSurface:true,request:state.requestID)
        state.receive([0,1,0.03],horizontalSurface:true,request:state.requestID)
        XCTAssertNil(state.selectedTop); XCTAssertFalse(state.isCapturing)
        XCTAssertEqual(state.target,SIMD2<Float>(0.1,0.2))
    }
    func testInterruptionAndUndoRejectOldRequestsAndClearWorldPoints() {
        let state = ShelfScanState(); capture(state,[0.5,1.2,0.2]); capture(state,[0,0,0])
        state.request(); let old = state.requestID
        state.invalidate("Interrupted")
        for _ in 0..<5 { state.receive([0,1.2,0],horizontalSurface:true,request:old) }
        XCTAssertNil(state.selectedTop); XCTAssertTrue(state.points.isEmpty); XCTAssertFalse(state.ready)
        capture(state,[0.5,1.2,0.2]); state.request(); let pending = state.requestID; state.undo()
        state.receive([0,0,0],horizontalSurface:true,request:pending)
        XCTAssertNil(state.selectedTop); XCTAssertTrue(state.points.isEmpty)
    }
    func testSkipClearanceDoesNotInventMeasurementAndResultSurvivesBackground() {
        let state = ShelfScanState()
        capture(state,[0.5,1.2,0.2]); capture(state,[0,0,0]); capture(state,[0,1.2,0]); capture(state,[1,1.2,0]); capture(state,[0.5,1.2,0.4])
        state.skipClearance(); XCTAssertNotNil(state.result); XCTAssertNil(state.result?.clearance)
        state.invalidate("Background"); XCTAssertNotNil(state.result)
    }
}
