import XCTest

final class InteriorUITests: XCTestCase {
    @MainActor func testFrozenCornerPlacementCorrectionAndSaveReopen() {
        let app=XCUIApplication();app.launchArguments=["interior"];app.launch()
        let picker=app.descendants(matching:.any).matching(identifier:"interior-frozen-photo").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout:5))
        for (x,y) in [(0.2,0.2),(0.8,0.2),(0.8,0.8),(0.2,0.8)] {tapImage(app,picker,x,y)}
        XCTAssertTrue(app.buttons["interior-next-height"].exists)
        screenshot(app,"frozen-corners")
        app.buttons["Move corner 2"].tap();tapImage(app,picker,0.79,0.2)
        XCTAssertFalse(app.staticTexts["interior-error"].exists)
        app.buttons["interior-next-height"].tap()
        enterHeight(app,"3.5")
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout:4))
        XCTAssertTrue(app.staticTexts["Height entered by you"].exists)
        screenshot(app,"interior-review")
        save(app)
        XCTAssertTrue(app.staticTexts["saved-interior"].waitForExistence(timeout:4))
        XCTAssertTrue(app.staticTexts["saved-interior"].label.contains("4 corners"))
        app.terminate();app.launchArguments=["interior","reopen"];app.launch()
        XCTAssertTrue(app.staticTexts["Height entered by you"].waitForExistence(timeout:4))
        // The chosen unit is remembered across launches; set it explicitly, check both, restore.
        app.buttons["Inches"].tap()
        let height=app.textFields.matching(NSPredicate(format:"value == %@","3.50")).firstMatch
        XCTAssertTrue(height.waitForExistence(timeout:3))
        // Uncommitted text would be read in the new unit, so units lock while a value is edited.
        height.tap()
        XCTAssertFalse(app.buttons["Centimeters"].isEnabled)
        app.buttons["Done"].tap()
        app.swipeDown()   // editing scrolled the form; lazy rows above leave the hierarchy
        let centimeters=app.buttons["Centimeters"]
        XCTAssertTrue(centimeters.waitForExistence(timeout:3) && centimeters.isEnabled)
        centimeters.tap()
        XCTAssertTrue(app.textFields.matching(NSPredicate(format:"value == %@","8.89")).firstMatch.waitForExistence(timeout:3))
        app.buttons["Both"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format:"label CONTAINS %@ AND label CONTAINS %@", " in", " cm")).firstMatch.exists)
        app.buttons["Inches"].tap()
    }
    @MainActor func testCentimeterHeightEntryConvertsBeforeApplyingExactMillimeters() {
        let app=XCUIApplication();app.launchArguments=["interior"];app.launch()
        let picker=app.descendants(matching:.any).matching(identifier:"interior-frozen-photo").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout:5))
        for (x,y) in [(0.2,0.2),(0.8,0.2),(0.8,0.8),(0.2,0.8)] {tapImage(app,picker,x,y)}
        app.buttons["interior-next-height"].tap()
        app.buttons["enter-interior-height"].tap()
        XCTAssertTrue(app.buttons["Centimeters"].waitForExistence(timeout:3))
        app.buttons["Centimeters"].tap()
        let field=app.textFields["interior-height-value"]
        field.tap();field.typeText("8.89")
        app.buttons["Inches"].tap()
        XCTAssertEqual(Double(field.value as? String ?? "") ?? 0, 3.5, accuracy:0.000001)
        app.buttons["Centimeters"].tap()
        XCTAssertEqual(Double(field.value as? String ?? "") ?? 0, 8.89, accuracy:0.000001)
        app.buttons["apply-interior-height"].tap()
        XCTAssertTrue(app.navigationBars["Review interior"].waitForExistence(timeout:4))
        XCTAssertTrue(app.textFields.matching(NSPredicate(format:"value == %@","8.89")).firstMatch.exists)
        save(app)
        XCTAssertTrue(app.staticTexts["saved-interior"].waitForExistence(timeout:4))
        XCTAssertTrue(app.staticTexts["saved-interior"].label.contains("88.9 mm"))
    }
    @MainActor func testPinnedOutlineCanAddObstacleWithoutLosingBase() {
        let app=XCUIApplication();app.launchArguments=["interior","pinned"];app.launch()
        XCTAssertTrue(app.buttons["interior-add-obstacle"].waitForExistence(timeout:4));app.buttons["interior-add-obstacle"].tap()
        let picker=app.descendants(matching:.any).matching(identifier:"interior-frozen-photo").firstMatch
        for (x,y) in [(0.4,0.4),(0.6,0.4),(0.6,0.6),(0.4,0.6)] {tapImage(app,picker,x,y)}
        screenshot(app,"obstacle-preserves-base")
        app.buttons["interior-next-height"].tap();enterHeight(app,"4")
        save(app)
        XCTAssertTrue(app.staticTexts["saved-interior"].waitForExistence(timeout:3))
        XCTAssertTrue(app.staticTexts["saved-interior"].label.contains("2 outlines · 4 corners"))
    }
    @MainActor func testAutomaticOutlineAdvancesDirectlyToHeightAndBack() {
        let app=XCUIApplication();app.launchArguments=["interior","automatic-outline"];app.launch()
        let use=app.buttons["use-interior-outline"];XCTAssertTrue(use.waitForExistence(timeout:4));use.tap()
        XCTAssertTrue(app.buttons["enter-interior-height"].waitForExistence(timeout:3))
        app.buttons["Edit outline"].tap()
        XCTAssertTrue(app.buttons["Move corner 1"].waitForExistence(timeout:3))
        XCTAssertTrue(app.buttons["interior-add-obstacle"].exists)
    }
    @MainActor func testUnreliablePhotoPixelDoesNotAddCornerAndZoomStillWorks() {
        let app=XCUIApplication();app.launchArguments=["interior","bad-depth"];app.launch()
        let picker=app.descendants(matching:.any).matching(identifier:"interior-frozen-photo").firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout:5));tapImage(app,picker,0.5,0.5)
        XCTAssertTrue(app.staticTexts["interior-error"].exists)
        XCTAssertTrue(app.staticTexts["0 corners"].exists)
        picker.pinch(withScale:2,velocity:1)
        picker.coordinate(withNormalizedOffset:CGVector(dx:0.7,dy:0.7)).tap()
        XCTAssertTrue(app.staticTexts["1 corners"].exists)
        screenshot(app,"zoomed-exact-corner")
        app.buttons["Undo"].tap();XCTAssertTrue(app.staticTexts["0 corners"].exists)
    }
    @MainActor private func enterHeight(_ app:XCUIApplication,_ value:String) {
        let b=app.buttons["enter-interior-height"];XCTAssertTrue(b.waitForExistence(timeout:3));b.tap()
        let inches=app.buttons["Inches"];XCTAssertTrue(inches.waitForExistence(timeout:3));inches.tap()
        let field=app.textFields["interior-height-value"];XCTAssertTrue(field.waitForExistence(timeout:3));field.tap();field.typeText(value)
        app.buttons["apply-interior-height"].tap()
    }
    @MainActor private func save(_ app:XCUIApplication) {
        let button=app.buttons["save-interior-review"]
        XCTAssertTrue(button.waitForExistence(timeout:3));XCTAssertTrue(button.isHittable);button.tap()
    }
    @MainActor private func tapImage(_ app:XCUIApplication,_ picker:XCUIElement,_ x:Double,_ y:Double) {
        let frame=picker.frame, side=min(frame.width,frame.height)
        let p=CGVector(dx:frame.midX+(x-0.5)*side,dy:frame.midY+(y-0.5)*side)
        app.coordinate(withNormalizedOffset:.zero).withOffset(p).tap()
    }
    @MainActor private func screenshot(_ app:XCUIApplication,_ name:String) {
        let a=XCTAttachment(screenshot:app.screenshot());a.name=name;a.lifetime = .keepAlways;add(a)
    }
}
