import XCTest

final class WireUITests: XCTestCase {
    @MainActor func testAutoChangesToWireMethodWhenInitialSurfaceCannotLock() {
        let app=XCUIApplication();app.launchArguments=["auto-failure"];app.launch()
        XCTAssertTrue(app.navigationBars["Measure wire shelf"].waitForExistence(timeout:5))
        screenshot(app,"auto-wire-fallback-simulator")
        app.buttons["Method"].tap()
        XCTAssertTrue(app.buttons["Auto"].exists)
        app.buttons["Solid shelf"].tap()
        XCTAssertTrue(app.navigationBars["Measure shelf"].waitForExistence(timeout:5))
        app.buttons["Method"].tap();app.buttons["Wire shelf"].tap()
        XCTAssertTrue(app.navigationBars["Measure wire shelf"].waitForExistence(timeout:5))
    }
    @MainActor func testPhotoPointSelectionStaysInOriginalImageCoordinatesAfterZoom() {
        let app=XCUIApplication();app.launchArguments=["picker"];app.launch()
        let use=app.buttons["confirm-picker"]
        XCTAssertTrue(use.waitForExistence(timeout:5));XCTAssertFalse(use.isEnabled)
        let picker=app.descendants(matching:.any).matching(identifier:"photo-picker").firstMatch
        picker.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        XCTAssertTrue(use.isEnabled)
        assertCentered(app)
        picker.pinch(withScale:2,velocity:1)
        picker.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        assertCentered(app)
        picker.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.5)).tap()
        let values=app.staticTexts["point-coordinate"].label.split(separator:" ").compactMap {Float($0.split(separator:"=").last ?? "")}
        XCTAssertEqual(values.count,2)
        if values.count==2 {XCTAssertEqual(values[0],0.6,accuracy:0.025);XCTAssertEqual(values[1],0.5,accuracy:0.025)}
        screenshot(app,"zoomed-wire-photo-point")
        use.tap();XCTAssertTrue(app.staticTexts["accepted"].exists)
    }
    @MainActor func testMatchedPointReviewShowsDimensionsAndCorrectSource() {
        let app=XCUIApplication();app.launchArguments=["result"];app.launch()
        XCTAssertTrue(app.buttons["use-wire-shelf"].waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Matched-point estimate"].exists)
        for value in ["12.00 in","48.00 in","15.00 in"] {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@",value)).firstMatch.exists)
        }
        screenshot(app,"synthetic-wire-measurement-review")
        app.buttons["use-wire-shelf"].tap();XCTAssertTrue(app.staticTexts["accepted"].waitForExistence(timeout:3))
    }
    @MainActor private func assertCentered(_ app:XCUIApplication) {
        let label=app.staticTexts["point-coordinate"].label
        let values=label.split(separator:" ").compactMap {Float($0.split(separator:"=").last ?? "")}
        XCTAssertEqual(values.count,2)
        if values.count==2 {XCTAssertEqual(values[0],0.5,accuracy:0.025);XCTAssertEqual(values[1],0.5,accuracy:0.025)}
    }
    @MainActor private func screenshot(_ app:XCUIApplication,_ name:String) {
        let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)
    }
}
