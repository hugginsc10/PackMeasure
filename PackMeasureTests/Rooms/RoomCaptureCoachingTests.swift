import XCTest
@testable import PackMeasure

final class RoomCaptureCoachingTests: XCTestCase {
    private func wall(id: UUID = UUID(), shift: Float = 0, height: Float = 2.4, confidence: String = "high") -> MeasuredRoom.Wall {
        .init(id: id, start: [shift, 0], end: [2 + shift, 0], height: height, confidence: confidence)
    }

    func testRepeatedCloseCallbacksDoNotPostponeRecovery() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 100)
        coach.receive(.moveAwayFromWall, at: 102)
        coach.receive(.moveAwayFromWall, at: 108)
        XCTAssertFalse(coach.persistentCloseWarning(at: 109.9))
        XCTAssertTrue(coach.persistentCloseWarning(at: 110))
        XCTAssertTrue(coach.showsGuidance(.room, at: 110))
        XCTAssertFalse(coach.offersReview(at: 110))
        XCTAssertTrue(coach.diagnosticSummary(at: 110).contains("instruction_moveAwayFromWall_s=8.0"))
    }

    func testNormalFeedbackClearsPersistentCloseWarning() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        coach.receive(.moveAwayFromWall, at: 1)
        XCTAssertTrue(coach.persistentCloseWarning(at: 10))
        coach.receive(.normal, at: 11)
        XCTAssertFalse(coach.persistentCloseWarning(at: 12))
        XCTAssertFalse(coach.showsGuidance(.room, at: 12))
        XCTAssertTrue(coach.showsGuidance(.tightCloset, at: 12))
        XCTAssertTrue(coach.diagnosticSummary(at: 12).contains("instruction_moveAwayFromWall_s=10.0"))
    }

    func testReviewRequiresUsableWallsAndNeverClosesOrChangesThem() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        coach.receive(.moveAwayFromWall, at: 1)
        let invalid = wall(height: .nan)
        coach.receive(RoomCaptureObservation(walls: [invalid]), at: 2)
        XCTAssertFalse(coach.offersReview(at: 10))
        let usable = wall(confidence: "low")
        coach.receive(RoomCaptureObservation(walls: [invalid, usable]), at: 11)
        XCTAssertTrue(coach.offersReview(at: 11))
        XCTAssertTrue(coach.isActive)
        XCTAssertEqual(coach.validWallCount, 1)
        XCTAssertEqual(coach.lowConfidenceWallCount, 1)
        XCTAssertEqual(coach.walls.map(\.id), [invalid.id, usable.id])
    }

    func testGeometryRefinementAtSameCountPreventsFalseStall() {
        var coach = RoomCaptureCoaching()
        let id = UUID()
        coach.begin(at: 0)
        coach.receive(RoomCaptureObservation(walls: [wall(id: id)]), at: 1)
        XCTAssertTrue(coach.outlineUnchanged(at: 21))
        coach.receive(RoomCaptureObservation(walls: [wall(id: id, shift: 0.1)]), at: 22)
        XCTAssertFalse(coach.outlineUnchanged(at: 23))
        XCTAssertTrue(coach.outlineUnchanged(at: 37))
    }

    func testSlowGeometryRefinementAccumulatesAgainstLastMeaningfulBaseline() {
        var coach = RoomCaptureCoaching()
        let id = UUID()
        coach.begin(at: 0)
        coach.receive(RoomCaptureObservation(walls: [wall(id: id)]), at: 1)
        coach.receive(RoomCaptureObservation(walls: [wall(id: id, shift: 0.03)]), at: 20)
        XCTAssertTrue(coach.outlineUnchanged(at: 21))
        coach.receive(RoomCaptureObservation(walls: [wall(id: id, shift: 0.08)]), at: 22)
        XCTAssertFalse(coach.outlineUnchanged(at: 23))
    }

    func testReorderingEndpointReversalAndSmallJitterDoNotMaskStall() {
        var coach = RoomCaptureCoaching()
        let a = wall(), b = wall(shift: 3)
        coach.begin(at: 0)
        coach.receive(RoomCaptureObservation(walls: [a, b]), at: 1)
        let reversed = MeasuredRoom.Wall(id: a.id, start: a.end, end: a.start, height: a.height, confidence: a.confidence)
        coach.receive(RoomCaptureObservation(walls: [wall(id: b.id, shift: 3.02), reversed]), at: 20)
        XCTAssertTrue(coach.outlineUnchanged(at: 21))
    }

    func testMissingWallsAndConfidenceChangesResetProgressEvidence() {
        var coach = RoomCaptureCoaching()
        let a = wall(confidence: "low"), b = wall(shift: 3)
        coach.begin(at: 0)
        coach.receive(RoomCaptureObservation(walls: [a, b]), at: 1)
        coach.receive(RoomCaptureObservation(walls: [a]), at: 20)
        XCTAssertFalse(coach.outlineUnchanged(at: 21))
        coach.receive(RoomCaptureObservation(walls: [wall(id: a.id, confidence: "high")]), at: 34)
        XCTAssertFalse(coach.outlineUnchanged(at: 36))
        XCTAssertEqual(coach.peakWallCount, 2)
    }

    func testNoWallsCanTriggerAdviceButNeverReviewOrCompletion() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        coach.receive(RoomCaptureObservation(walls: []), at: 19)
        XCTAssertFalse(coach.outlineUnchanged(at: 19.9))
        XCTAssertTrue(coach.outlineUnchanged(at: 20))
        XCTAssertFalse(coach.offersReview(at: 20))
        XCTAssertTrue(coach.isActive)
    }

    func testFinishFreezesDiagnosticsAndRejectsLateCoachingAndGeometry() {
        var coach = RoomCaptureCoaching()
        let a = wall()
        coach.begin(at: 0)
        coach.receive(.moveAwayFromWall, at: 2)
        coach.receive(RoomCaptureObservation(walls: [a], tracking: "normal"), at: 3)
        coach.end(at: 12)
        let diagnostic = coach.diagnosticSummary(at: 12)
        coach.receive(.turnOnLight, at: 20)
        coach.receive(RoomCaptureObservation(walls: [wall(), wall()]), at: 20)
        coach.end(at: 30)
        XCTAssertEqual(coach.diagnosticSummary(at: 1000), diagnostic)
        XCTAssertEqual(coach.walls.map(\.id), [a.id])
        XCTAssertFalse(coach.showsGuidance(.tightCloset, at: 1000))
        XCTAssertFalse(coach.offersReview(at: 1000))
    }

    func testNewSessionResetsOldWarningsProgressAndDiagnostics() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        coach.receive(.moveAwayFromWall, at: 1)
        coach.receive(RoomCaptureObservation(walls: [wall()], tracking: "limited"), at: 2)
        coach.end(at: 15)
        coach.begin(at: 100)
        XCTAssertTrue(coach.walls.isEmpty)
        XCTAssertEqual(coach.instruction, .normal)
        XCTAssertEqual(coach.wallUpdates, 0)
        XCTAssertEqual(coach.peakWallCount, 0)
        XCTAssertFalse(coach.outlineUnchanged(at: 101))
        XCTAssertTrue(coach.diagnosticSummary(at: 101).contains("instruction_moveAwayFromWall_s=0.0"))
    }

    func testLightingAdviceTakesPriorityOverStalledOutline() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        coach.receive(.turnOnLight, at: 25)
        XCTAssertTrue(coach.outlineUnchanged(at: 30))
        XCTAssertEqual(coach.advice(at: 30).title, "Light the closet")
        coach.receive(.slowDown, at: 31)
        XCTAssertEqual(coach.advice(at: 32).title, "Sweep more slowly")
    }

    func testDiagnosticHistoryIsBoundedWhileDurationRemainsComplete() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        for i in 1...100 { coach.receive(i.isMultiple(of: 2) ? .normal : .slowDown, at: Double(i)) }
        let report = coach.diagnosticSummary(at: 100)
        XCTAssertEqual(report.split(separator: "\n").filter { $0.hasPrefix("t=") }.count, 40)
        XCTAssertTrue(report.contains("instruction_slowDown_s=50.0"))
        XCTAssertTrue(report.contains("instruction_normal_s=50.0"))
    }

    func testRepeatedCompleteSnapshotsDoNotDisguiseAnUnchangedCloset() {
        var coach = RoomCaptureCoaching()
        coach.begin(at: 0)
        let walls = (0..<5).map { wall(shift: Float($0) * 3) }
        for step in 1...100 {
            coach.receive(RoomCaptureObservation(walls: walls, tracking: "normal"), at: Double(step) * 0.6)
        }
        XCTAssertEqual(coach.validWallCount, 5)
        XCTAssertTrue(coach.outlineUnchanged(at: 60))
        XCTAssertTrue(coach.offersReview(at: 60))
        XCTAssertEqual(coach.diagnosticSummary(at: 60).split(separator: "\n").filter { $0.hasPrefix("t=") }.count, 1)
    }

    func testUnstartedSessionIgnoresEventsAndDoesNotReportSystemUptimeAsScanDuration() {
        var coach = RoomCaptureCoaching()
        coach.receive(.moveAwayFromWall, at: 1000)
        coach.receive(RoomCaptureObservation(walls: [wall()]), at: 1000)
        XCTAssertFalse(coach.showsGuidance(.tightCloset, at: 1000))
        XCTAssertEqual(coach.diagnosticSummary(at: 1000), "Capture has not started.")
    }
}
