import XCTest
@testable import PackMeasure

final class DiagnosticMailOutcomeTests: XCTestCase {
    func testQueuedMailDoesNotClaimReceiptAndOtherOutcomesRemainActionable() {
        XCTAssertFalse(DiagnosticMailOutcome.sent.message.lowercased().contains("delivered"))
        XCTAssertTrue(DiagnosticMailOutcome.sent.message.contains("confirm delivery"))
        XCTAssertTrue(DiagnosticMailOutcome.saved.message.contains("tap Send"))
        XCTAssertTrue(DiagnosticMailOutcome.cancelled.message.contains("note and report are still here"))
        XCTAssertTrue(DiagnosticMailOutcome.failed.message.contains("Share report"))
    }
}
