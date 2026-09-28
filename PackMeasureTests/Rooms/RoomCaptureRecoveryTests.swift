import XCTest
@testable import PackMeasure

final class RoomCaptureRecoveryTests: XCTestCase {
    private func wall(_ a: SIMD2<Float>, _ b: SIMD2<Float>, height: Float = 2.76) -> MeasuredRoom.Wall {
        .init(id: UUID(), start: a, end: b, height: height, confidence: "high")
    }

    private var closet: [MeasuredRoom.Wall] {
        [wall([0, 0], [1.42, 0]), wall([1.42, 0], [1.42, 1.16]),
         wall([1.42, 1.16], [0, 1.16]), wall([0, 1.16], [0, 0])]
    }

    func testFourLiveWallsToOneProcessedRequiresExplicitChoiceWithoutCombiningGeometry() throws {
        var recovery = RoomCaptureRecovery()
        let live = closet
        recovery.receive(live)
        recovery.freeze()
        let finalWall = wall([0.5419644, -0.24283662], [-0.4332952, -0.59084094], height: 3.09)
        let processed = try MeasuredRoom(walls: [finalWall], captureSource: .processed)
        let result = try XCTUnwrap(recovery.comparison(processed: processed, failure: nil))
        XCTAssertTrue(result.needsChoice)
        XCTAssertEqual(result.title, "Fewer walls after Finish")
        XCTAssertEqual(result.live?.walls.map(\.id), live.map(\.id))
        XCTAssertEqual(result.processed?.walls.map(\.id), [finalWall.id])
        XCTAssertEqual(result.live?.wallHeight, 2.76)
        XCTAssertEqual(result.processed?.wallHeight, 3.09)
        XCTAssertEqual(result.live?.captureSource, .liveSnapshot)
        XCTAssertEqual(result.processed?.captureSource, .processed)
        XCTAssertTrue(recovery.diagnosticSummary.contains("live_snapshot_frozen=true detected_walls=4"))
        XCTAssertTrue(recovery.diagnosticSummary.contains("id=\(live[0].id)"))
        XCTAssertTrue(recovery.diagnosticSummary.contains("start_xz="))
    }

    func testQueuedSnapshotsCannotOverwriteFrozenOutlineAndFreezeIsIdempotent() throws {
        var recovery = RoomCaptureRecovery()
        let live = closet
        recovery.receive(live)
        recovery.freeze()
        recovery.receive([])
        recovery.receive([wall([0, 0], [9, 9])])
        recovery.freeze()
        XCTAssertEqual(recovery.frozenWalls?.map(\.id), live.map(\.id))
    }

    func testLatestCompleteSnapshotReplacesPeakAndNeverResurrectsRemovedWalls() throws {
        var recovery = RoomCaptureRecovery()
        let live = closet
        recovery.receive(live)
        recovery.receive([live[0]])
        recovery.freeze()
        let result = try XCTUnwrap(recovery.comparison(processed: nil, failure: "Empty result"))
        XCTAssertEqual(result.live?.walls.map(\.id), [live[0].id])
        XCTAssertTrue(result.needsChoice)
    }

    func testAnEmptyLatestSnapshotDoesNotRecoverTheEarlierPeak() {
        var recovery = RoomCaptureRecovery()
        recovery.receive(closet)
        recovery.receive([])
        recovery.freeze()
        XCTAssertNil(recovery.comparison(processed: nil, failure: "Empty result"))
    }

    func testProcessingErrorOrTimeoutPreservesLiveCandidateAndFailureForDiagnostics() throws {
        for failure in ["Processing failed", "Room processing did not finish within 45 seconds."] {
            var recovery = RoomCaptureRecovery()
            recovery.receive(closet)
            recovery.freeze()
            let result = try XCTUnwrap(recovery.comparison(processed: nil, failure: failure))
            XCTAssertNil(result.processed)
            XCTAssertEqual(result.live?.walls.count, 4)
            XCTAssertTrue(result.needsChoice)
            XCTAssertTrue(result.diagnosticSummary.contains(failure))
        }
    }

    func testNoUsableLiveWallsKeepsProcessedResultWithoutRecoveryPrompt() throws {
        var recovery = RoomCaptureRecovery()
        recovery.receive([wall([0, 0], [0, 0])])
        recovery.freeze()
        let processed = try MeasuredRoom(walls: closet, captureSource: .processed)
        let result = try XCTUnwrap(recovery.comparison(processed: processed, failure: nil))
        XCTAssertNil(result.live)
        XCTAssertFalse(result.needsChoice)
        XCTAssertEqual(result.processed?.id, processed.id)
    }

    func testInvalidWallsAreNotOfferedAsRecoverableAndRemainInDiagnostics() throws {
        var recovery = RoomCaptureRecovery()
        recovery.receive(closet + [wall([0, 0], [0, 0])])
        recovery.freeze()
        let result = try XCTUnwrap(recovery.comparison(processed: nil, failure: "No final walls"))
        XCTAssertEqual(result.live?.walls.count, 4)
        XCTAssertEqual(result.live?.excludedWallCount, 1)
        XCTAssertTrue(recovery.diagnosticSummary.contains("detected_walls=5 valid_walls=4"))
    }

    func testUnchangedResultDoesNotInterruptReviewWhenIDsOrOrderChange() throws {
        var recovery = RoomCaptureRecovery()
        let live = closet
        recovery.receive(live)
        let processed = try MeasuredRoom(walls: live.reversed().map { wall($0.end, $0.start) })
        let result = try XCTUnwrap(recovery.comparison(processed: processed, failure: nil))
        XCTAssertFalse(result.needsChoice)
    }

    func testSameCountWithLargeLengthOrHeightLossPromptsComparison() throws {
        var recovery = RoomCaptureRecovery()
        let live = closet
        recovery.receive(live)
        let shorter = try MeasuredRoom(walls: live.map { wall($0.start, $0.start + ($0.end - $0.start) * 0.5) })
        XCTAssertTrue(try XCTUnwrap(recovery.comparison(processed: shorter, failure: nil)).needsChoice)
        let lower = try MeasuredRoom(walls: live.map { wall($0.start, $0.end, height: 1.9) })
        XCTAssertTrue(try XCTUnwrap(recovery.comparison(processed: lower, failure: nil)).needsChoice)
    }

    func testSmallRefinementsDoNotPromptButLiveCandidateRemainsAvailable() throws {
        var recovery = RoomCaptureRecovery()
        let live = closet
        recovery.receive(live)
        let processed = try MeasuredRoom(walls: live.map { wall($0.start, $0.start + ($0.end - $0.start) * 0.97, height: 2.7) })
        let result = try XCTUnwrap(recovery.comparison(processed: processed, failure: nil))
        XCTAssertFalse(result.needsChoice)
        XCTAssertEqual(result.live?.walls.count, 4)
    }

    func testNewScanStartsWithoutPreviousRecoveryGeometry() {
        var recovery = RoomCaptureRecovery()
        recovery.receive(closet)
        recovery.freeze()
        recovery = RoomCaptureRecovery()
        XCTAssertNil(recovery.frozenWalls)
        XCTAssertNil(recovery.comparison(processed: nil, failure: "No walls"))
    }

    func testLiveProvenanceSurvivesSelectionSaveReloadAndShareAndOldRoomsDecode() throws {
        var recovery = RoomCaptureRecovery()
        recovery.receive(closet)
        let live = try XCTUnwrap(recovery.comparison(processed: nil, failure: nil)?.live)
        let kept = try live.keepingWalls(Set(live.walls.prefix(3).map(\.id)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RoomScanStore(directory: directory)
        try store.save(kept)
        let loaded = try XCTUnwrap(store.load().first)
        XCTAssertEqual(loaded.captureSource, .liveSnapshot)
        XCTAssertEqual(loaded.omittedWallCount, 1)
        XCTAssertEqual(loaded.walls.map(\.id), kept.walls.map(\.id))
        XCTAssertTrue(loaded.shareText.contains("Live outline · unprocessed"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(kept)) as? [String: Any])
        json.removeValue(forKey: "captureSource")
        let old = try JSONDecoder().decode(MeasuredRoom.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.captureSource)
        XCTAssertNil(old.captureSourceMessage)
    }
}
