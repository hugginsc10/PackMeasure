import XCTest

final class SweepUITests: XCTestCase {
    @MainActor func testRectangleChoiceSurvivesCaptureSaveAndReopen() {
        let app=XCUIApplication(); app.launchArguments=["sweep","choose-model"]; app.launch()
        let models=app.segmentedControls["interior-footprint-model"]
        XCTAssertTrue(models.waitForExistence(timeout:5))
        XCTAssertTrue(models.buttons["Follow edges"].isSelected)
        models.buttons["Rectangle"].tap()
        app.buttons["sweep-select-base"].tap()
        let review=app.buttons["sweep-review"]
        XCTAssertTrue(review.waitForExistence(timeout:5))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:review); waitForExpectations(timeout:8)
        review.tap()
        XCTAssertTrue(app.staticTexts["interior-rectangular-fit"].waitForExistence(timeout:4))
        screenshot(app,"rectangular-fit-review")
        app.buttons["save-interior-review"].tap()
        XCTAssertTrue(app.staticTexts["saved-sweep"].waitForExistence(timeout:3))
        app.terminate(); app.launchArguments=["sweep","reopen"]; app.launch()
        XCTAssertTrue(app.staticTexts["interior-rectangular-fit"].waitForExistence(timeout:4))
    }
    @MainActor func testSweepToReviewSaveAndReopenWithoutCornerTaps() {
        let app=XCUIApplication(); app.launchArguments=["sweep"]; app.launch()
        let review=app.buttons["sweep-review"]
        XCTAssertTrue(review.waitForExistence(timeout:5))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:review)
        waitForExpectations(timeout:8)
        XCTAssertEqual(review.label,"Review dimensions")
        screenshot(app,"automatic-sweep-captured")
        review.tap()
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout:4))
        XCTAssertTrue(app.staticTexts["interior-boundary-variation"].waitForExistence(timeout:3))
        screenshot(app,"automatic-measurements-review")
        // The captured evidence extends the first section. Form creates the height
        // row lazily, so scroll to it just as a user would before checking its source.
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Captured height · verify available space"].waitForExistence(timeout:3))
        app.buttons["save-interior-review"].tap()
        XCTAssertTrue(app.staticTexts["saved-sweep"].waitForExistence(timeout:3))
        XCTAssertTrue(app.staticTexts["saved-sweep"].label.contains("4 corners"))
        app.terminate(); app.launchArguments=["sweep","reopen"]; app.launch()
        XCTAssertTrue(app.staticTexts["interior-boundary-variation"].waitForExistence(timeout:3))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Captured height · verify available space"].waitForExistence(timeout:3))
    }
    @MainActor func testCapturedOutlineOffersHeightFallbackWithoutRetracing() {
        let app=XCUIApplication(); app.launchArguments=["sweep","no-height"]; app.launch()
        let review=app.buttons["sweep-review"]
        XCTAssertTrue(review.waitForExistence(timeout:5))
        expectation(for:NSPredicate(format:"enabled == true"),evaluatedWith:review); waitForExpectations(timeout:8)
        XCTAssertEqual(review.label,"Use outline · set height"); review.tap()
        XCTAssertTrue(app.buttons["enter-interior-height"].waitForExistence(timeout:3))
        app.buttons["Edit outline"].tap()
        XCTAssertTrue(app.buttons["Move corner 1"].waitForExistence(timeout:3))
        XCTAssertTrue(app.buttons["Move corner 4"].exists)
    }
    @MainActor func testMissingFrontKeepsReviewDisabledAndGivesGuidance() {
        let app=XCUIApplication(); app.launchArguments=["sweep","missing-front"]; app.launch()
        let review=app.buttons["sweep-review"]; XCTAssertTrue(review.waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["Show the front edge and any unhighlighted sides."].waitForExistence(timeout:6))
        XCTAssertFalse(review.isEnabled)
        screenshot(app,"sweep-missing-front")
    }
    @MainActor private func screenshot(_ app:XCUIApplication,_ name:String) {
        let item=XCTAttachment(screenshot:app.screenshot()); item.name=name; item.lifetime = .keepAlways; add(item)
    }
}
