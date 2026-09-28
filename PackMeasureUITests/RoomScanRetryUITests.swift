import XCTest

final class RoomScanRetryUITests: XCTestCase {
    // The simulator has no LiDAR, so the sheet's access gate fails immediately.
    // Retrying must run the gate again instead of stranding the user on the
    // "Checking camera access…" spinner (same path as a denied camera prompt).
    @MainActor func testStartNewScanRechecksAccessInsteadOfHanging() {
        let app=XCUIApplication();app.launchArguments=["room-sheet"];app.launch()
        let failure=app.staticTexts["Room scan needs another try"]
        XCTAssertTrue(failure.waitForExistence(timeout:5))
        app.buttons["Start new scan"].tap()
        XCTAssertTrue(failure.waitForExistence(timeout:5),"Retry never re-ran the access check")
        XCTAssertFalse(app.staticTexts["Checking camera access…"].exists)
        let a=XCTAttachment(screenshot:app.screenshot());a.name="room-retry-rechecked";a.lifetime = .keepAlways;add(a)
    }
}
