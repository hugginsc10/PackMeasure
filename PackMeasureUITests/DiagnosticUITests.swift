import XCTest

final class DiagnosticUITests: XCTestCase {
    @MainActor func testReportSurvivesItsLiveDiagnosticButtonBeingRemoved() {
        let app = XCUIApplication()
        app.launchArguments = ["diagnostics-lifecycle"]
        app.launch()
        app.buttons["Fixture diagnostics"].tap()
        XCTAssertTrue(app.navigationBars["Send diagnostics"].waitForExistence(timeout: 5))
        let identifier = app.staticTexts["diagnostic-report-id"].label
        let note = app.textViews["diagnostic-note"]
        note.tap()
        note.typeText("Capture changed while I was writing.")
        XCTAssertEqual(app.staticTexts["diagnostic-report-id"].label, identifier)
        XCTAssertEqual(note.value as? String, "Capture changed while I was writing.")
        app.navigationBars["Send diagnostics"].buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["diagnostic-live-control-removed"].waitForExistence(timeout: 3))
    }

    @MainActor func testSettingsReportShowsRecipientAndMailFallbackWithoutSending() {
        let app = XCUIApplication()
        app.launchArguments = ["home", "light"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        reveal(app.buttons["settings-report-problem"], in: app)
        app.buttons["settings-report-problem"].tap()
        XCTAssertTrue(app.navigationBars["Send diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["diagnostic-recipient"].label.contains("hugginsc10@gmail.com"))
        XCTAssertTrue(app.staticTexts["App version, build, iPhone model, and iOS version. No scan report is attached."].exists)
        let note = app.textViews["diagnostic-note"]
        note.tap()
        note.typeText("The app closed after review.")
        app.buttons["diagnostic-note-done"].tap()
        reveal(app.buttons["diagnostic-email"], in: app)
        XCTAssertFalse(app.buttons["diagnostic-email"].isEnabled, "Simulator must use the unavailable-Mail path; no email is sent")
        reveal(app.buttons["diagnostic-copy-email"], in: app)
        app.buttons["diagnostic-copy-email"].tap()
        XCTAssertTrue(app.staticTexts["diagnostic-mail-unavailable"].exists)
        XCTAssertTrue(app.staticTexts["diagnostic-notice"].label.contains("Email address copied"))
        capture(app, "diagnostics-mail-fallback-light")
        app.navigationBars["Send diagnostics"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 3))
    }

    @MainActor func testRoomFailureReportOpensAndCanCloseBeforeRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["room-sheet", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["Share room diagnostics"].waitForExistence(timeout: 5))
        app.buttons["Share room diagnostics"].tap()
        XCTAssertTrue(app.navigationBars["Send diagnostics"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["diagnostic-report-id"].label.contains("Report ID:"))
        XCTAssertFalse(app.staticTexts["App version, build, iPhone model, and iOS version. No scan report is attached."].exists)
        capture(app, "diagnostics-room-dark")
        app.navigationBars["Send diagnostics"].buttons["Done"].tap()
        app.buttons["Start new scan"].tap()
        XCTAssertTrue(app.staticTexts["Room scan needs another try"].waitForExistence(timeout: 5))
    }

    @MainActor func testRoomReviewShareSheetCancellationKeepsNoteAndReportIdentity() {
        let app = XCUIApplication()
        app.launchArguments = ["room-review", "light"]
        app.launch()
        reveal(app.buttons["Diagnostics"], in: app)
        app.buttons["Diagnostics"].tap()
        XCTAssertTrue(app.navigationBars["Send diagnostics"].waitForExistence(timeout: 3))
        let identifier = app.staticTexts["diagnostic-report-id"].label
        let note = app.textViews["diagnostic-note"]
        note.tap()
        note.typeText("The finished outline is missing a wall.")
        app.buttons["diagnostic-note-done"].tap()
        reveal(app.buttons["diagnostic-share"], in: app)
        app.buttons["diagnostic-share"].tap()
        let shareSheet = app.otherElements["ShareSheet.RemoteContainerView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 5), "System sharing must open without an automatic send")
        XCTAssertTrue(app.cells["Save to Files"].exists, "The file must remain exportable without an email account")
        capture(app, "diagnostics-file-share")
        // iOS 27 uses a compact share popover without a Close button. Tapping
        // the visible navigation bar outside it cancels the share operation.
        app.navigationBars["Send diagnostics"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Send diagnostics"].waitForExistence(timeout: 3))
        for _ in 0..<8 where !app.staticTexts["diagnostic-report-id"].isHittable { app.swipeDown() }
        XCTAssertEqual(app.staticTexts["diagnostic-report-id"].label, identifier)
        XCTAssertEqual(app.textViews["diagnostic-note"].value as? String, "The finished outline is missing a wall.")
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
