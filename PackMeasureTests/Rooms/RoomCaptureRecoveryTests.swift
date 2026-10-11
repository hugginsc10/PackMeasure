import XCTest
@testable import PackMeasure

final class RoomCaptureRecoveryTests: XCTestCase {
    private func wall(_ a: SIMD2<Float>, _ b: SIMD2<Float>, height: Float = 2.76,
                      id: UUID = UUID(), confidence: String = "high") -> MeasuredRoom.Wall {
        .init(id: id, start: a, end: b, height: height, confidence: confidence)
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

    func testBuild66LostLiveBoundaryRequiresChoiceDespiteMoreProcessedWalls() throws {
        // Report 9B923FA9-DF9D-45C9-9317-CBA0B067BD37, captured October 7, 2026.
        // These are the reported coordinates, not a claim about the physical room.
        let live = [
            wall([1.7118312, 0.9347325], [0.6512946, 1.448025], height: 2.3886647,
                 id: UUID(uuidString: "B77E5231-4717-43F5-A6C8-B21016607049")!, confidence: "medium"),
            wall([-0.7961388, 2.37172], [-2.143776, -0.46396965], height: 2.55093,
                 id: UUID(uuidString: "41ED80FB-CCC4-4C4E-BC49-A2BAE56BE710")!),
            wall([0.22436583, 3.533479], [-1.6028551, 4.445547], height: 2.3886647,
                 id: UUID(uuidString: "91E06355-B2FD-49C2-A6CD-BD68CC3ECF58")!),
            wall([0.46663254, -1.7119524], [1.7118311, 0.93473244], height: 2.55093,
                 id: UUID(uuidString: "BCF3F300-502F-433E-ACEF-6034296B6967")!),
            wall([-2.143776, -0.46396947], [0.4666326, -1.7119524], height: 2.55093,
                 id: UUID(uuidString: "81F39481-8D74-455A-9525-B513B0107377")!)
        ]
        let finished = [
            wall([-0.7777767, 2.3906348], [-2.1390243, -0.4682619], height: 2.5500002, id: live[1].id),
            wall([0.47232085, -1.711639], [1.8141024, 1.1063756], height: 2.5500002, id: live[3].id),
            wall([-2.1390243, -0.4682619], [0.4723209, -1.7116389], height: 2.5500002, id: live[4].id),
            wall([0.5768366, -0.9625462], [0.7823944, -1.0604213], height: 2.5500002,
                 id: UUID(uuidString: "9D6904AE-CDA9-416A-92A5-E010F18D06B9")!),
            wall([0.97855663, 1.3604449], [-0.030340046, 1.8408252], height: 2.385,
                 id: UUID(uuidString: "1DB55BCF-A64D-4EB5-B0B9-FBDDA646B1FD")!),
            wall([0.6468361, -1.3451215], [0.5768365, -0.9625462], height: 2.5500002,
                 id: UUID(uuidString: "F580E12A-B087-4348-A487-EC341C78C456")!)
        ]
        var recovery = RoomCaptureRecovery()
        recovery.receive(live)
        recovery.freeze()
        let processed = try MeasuredRoom(walls: finished, captureSource: .processed)
        let result = try XCTUnwrap(recovery.comparison(processed: processed, failure: nil))
        let before = live.reduce(0) { $0 + $1.length }
        let after = finished.reduce(0) { $0 + $1.length }
        XCTAssertEqual(before, 12.1784153, accuracy: 0.00001)
        XCTAssertEqual(after, 10.9138536, accuracy: 0.00001)
        XCTAssertGreaterThan(after, before * 0.75)
        XCTAssertLessThan(try XCTUnwrap(result.live).wallHeight - processed.wallHeight, 0.3)
        XCTAssertEqual(result.processed?.walls.count, 6)
        XCTAssertTrue(result.needsChoice)
        XCTAssertEqual(result.title, "The outline changed after Finish")
        XCTAssertTrue(result.diagnosticSummary.contains("wall_coverage_loss"))
        XCTAssertTrue(result.diagnosticSummary.contains("comparison_uncovered_live_wall=\(live[2].id)"))
        XCTAssertEqual(result.live?.walls.map(\.id), live.map(\.id))
        XCTAssertEqual(result.processed?.walls.map(\.id), finished.map(\.id))
        for (actual, expected) in zip(try XCTUnwrap(result.live).walls, live) {
            XCTAssertEqual(actual.start, expected.start)
            XCTAssertEqual(actual.end, expected.end)
        }
        for (actual, expected) in zip(try XCTUnwrap(result.processed).walls, finished) {
            XCTAssertEqual(actual.start, expected.start)
            XCTAssertEqual(actual.end, expected.end)
        }
    }

    func testLostWallCannotBeMaskedByAddedWallsAndLongerTotalLength() throws {
        let live = closet
        let processed = [live[0], live[1], live[2], wall([4, 4], [8, 4]), wall([8, 4], [8, 8])]
        XCTAssertGreaterThan(processed.reduce(0) { $0 + $1.length }, live.reduce(0) { $0 + $1.length })
        let result = try comparison(live: live, processed: processed)
        XCTAssertTrue(result.needsChoice)
        XCTAssertTrue(result.diagnosticSummary.contains("wall_coverage_loss"))
    }

    func testCollinearSplitAndMergeCoverageIgnoresIDsOrderAndDirection() throws {
        let live = [wall([0, 0], [1, 0]), wall([1, 0], [2, 0]),
                    wall([2, 0], [2, 1]), wall([2, 1], [0, 1])]
        let processed = [wall([0, 0], [2, 0]), wall([2, 0], [2, 0.5]),
                         wall([2, 0.5], [2, 1]), wall([2, 1], [0, 1])]
        let reversed = processed.reversed().map { wall($0.end, $0.start) }
        let result = try comparison(live: live, processed: reversed)
        XCTAssertFalse(result.needsChoice)
        XCTAssertFalse(result.diagnosticSummary.contains("wall_coverage_loss"))
    }

    func testOverlappingProcessedSegmentsDoNotDoubleCountCoverage() throws {
        let live = [wall([0, 0], [4, 0])]
        let processed = [wall([0, 0], [2, 0]), wall([2, 0], [0, 0])]
        let result = try comparison(live: live, processed: processed)
        XCTAssertTrue(result.needsChoice)
        XCTAssertTrue(result.diagnosticSummary.contains("uncovered_m=2.000 uncovered_fraction=0.500"))
    }

    func testCrossingAndDistantParallelSegmentsDoNotCoverLiveWall() throws {
        let result = try comparison(live: [wall([0, 0], [4, 0])],
                                    processed: [wall([2, -2], [2, 2]), wall([0, 0.4], [4, 0.4])])
        XCTAssertTrue(result.needsChoice)
        XCTAssertTrue(result.diagnosticSummary.contains("uncovered_m=4.000 uncovered_fraction=1.000"))
    }

    func testSmallPositionAngleAndLengthRefinementsRemainInFinishedReview() throws {
        let live = closet
        let processed = live.map { original in
            let transform: (SIMD2<Float>) -> SIMD2<Float> = { point in
                let scaled = point * 0.97
                return [scaled.x * cos(0.01) - scaled.y * sin(0.01) + 0.03,
                        scaled.x * sin(0.01) + scaled.y * cos(0.01) - 0.02]
            }
            return wall(transform(original.end), transform(original.start), height: 2.7)
        }
        XCTAssertFalse(try comparison(live: live, processed: processed).needsChoice)
    }

    func testWholesaleFrameShiftConservativelyPromptsWithoutAligningCandidates() throws {
        let live = closet
        let offset = SIMD2<Float>(5, 6)
        let processed = live.map { wall($0.start + offset, $0.end + offset) }
        let result = try comparison(live: live, processed: processed)
        XCTAssertTrue(result.needsChoice)
        XCTAssertEqual(result.live?.walls[0].start, live[0].start)
        XCTAssertEqual(result.processed?.walls[0].start, processed[0].start)
    }

    func testSpatialCoverageCueRequiresBothAbsoluteAndRelativeLoss() throws {
        for (length, remaining, expected) in [(Float(0.8), Float(0.55), false),
                                               (4, 3, false), (0.8, 0.54, true), (4, 2.9, true)] {
            // The unrelated added wall makes count and total-length cues irrelevant.
            let result = try comparison(live: [wall([0, 0], [length, 0])],
                                        processed: [wall([0, 0], [remaining, 0]), wall([10, 10], [20, 10])])
            XCTAssertEqual(result.needsChoice, expected, "length=\(length) remaining=\(remaining)")
        }
    }

    private func comparison(live: [MeasuredRoom.Wall], processed: [MeasuredRoom.Wall]) throws -> RoomCaptureComparison {
        var recovery = RoomCaptureRecovery()
        recovery.receive(live)
        recovery.freeze()
        return try XCTUnwrap(recovery.comparison(processed: MeasuredRoom(walls: processed, captureSource: .processed),
                                               failure: nil))
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
