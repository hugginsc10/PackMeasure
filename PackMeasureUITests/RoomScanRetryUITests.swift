import XCTest

final class RoomScanRetryUITests: XCTestCase {
    // The simulator has no LiDAR, so the sheet's access gate fails immediately.
    // Retrying must run the gate again instead of stranding the user on the
    // "Checking camera access…" spinner (same path as a denied camera prompt).
    // The failure view's identifier names the scan the gate last checked, so
    // an unchanged identifier means the gate never re-ran for the retry.
    @MainActor func testStartNewScanRechecksAccessInsteadOfHanging() {
        let app=XCUIApplication();app.launchArguments=["room-sheet"];app.launch()
        let checked=NSPredicate(format:"identifier BEGINSWITH 'room-scan-failure-' AND identifier != 'room-scan-failure-unchecked'")
        let first=app.descendants(matching:.any).matching(checked).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout:5))
        let firstID=first.identifier
        app.buttons["Start new scan"].tap()
        let rechecked=app.descendants(matching:.any).matching(NSCompoundPredicate(andPredicateWithSubpredicates:[
            checked,NSPredicate(format:"identifier != %@",firstID)])).firstMatch
        XCTAssertTrue(rechecked.waitForExistence(timeout:5),"Retry never re-ran the access check")
        XCTAssertTrue(app.staticTexts["Room scan needs another try"].exists)
        XCTAssertFalse(app.staticTexts["Checking camera access…"].exists)
        let a=XCTAttachment(screenshot:app.screenshot());a.name="room-retry-rechecked";a.lifetime = .keepAlways;add(a)
    }
}
