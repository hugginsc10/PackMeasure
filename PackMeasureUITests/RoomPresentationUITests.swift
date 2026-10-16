import XCTest

final class RoomPresentationUITests: XCTestCase {
    @MainActor func testRoomLibraryInLightAndDark() {
        for appearance in ["light", "dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["room-library", appearance]
            app.launch()
            XCTAssertTrue(app.buttons["start-room-scan"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Practice room"].exists)
            XCTAssertTrue(app.staticTexts["Partial room"].exists)
            XCTAssertTrue(app.staticTexts["Partial scan · 2 segments"].exists)
            capture(app, name: "room-library-\(appearance)")
            app.terminate()
        }
    }

    @MainActor func testPartialWallSelectionSavesAndReopens() {
        let app = XCUIApplication()
        app.launchArguments = ["room-review", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-walls-to-save"].waitForExistence(timeout: 5))
        capture(app, name: "room-review-light")
        app.buttons["choose-walls-to-save"].tap()
        app.buttons["Selection"].tap()
        app.buttons["Clear selection"].tap()
        app.buttons["Wall list"].tap()
        let firstWall = app.switches["keep-room-wall-1"]
        XCTAssertEqual(firstWall.value as? String, "0")
        // SwiftUI exposes the whole label row as the switch. Tap its trailing
        // control rather than the center of that row.
        firstWall.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertEqual(firstWall.value as? String, "1")
        app.buttons["finish-room-wall-list"].tap()
        app.buttons["finish-room-wall-selection"].tap()
        let save = app.buttons["save-reviewed-room"]
        XCTAssertEqual(save.label, "Save partial")
        save.tap()
        XCTAssertTrue(app.staticTexts["Practice room"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Partial scan · 1 segment"].exists)
        app.staticTexts["Practice room"].tap()
        XCTAssertTrue(app.staticTexts["Partial scan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "overall room size is not established")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Long span"].exists)
        capture(app, name: "room-partial-reopened-light")
    }

    @MainActor func testLiveOutlineProvenanceSurvivesSaveAndReopen() {
        let app = XCUIApplication()
        app.launchArguments = ["room-compare", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["review-live-outline"].waitForExistence(timeout: 5))
        capture(app, name: "room-outline-comparison-dark")
        app.buttons["review-live-outline"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-outline-warning"].waitForExistence(timeout: 5))
        app.buttons["save-reviewed-room"].tap()
        XCTAssertTrue(app.staticTexts["Practice room"].waitForExistence(timeout: 5))
        app.staticTexts["Practice room"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-outline-warning"].waitForExistence(timeout: 5))
        capture(app, name: "room-live-reopened-dark")
    }

    @MainActor func testRoomDimensionsAtLargestAccessibilityTextSize() {
        let app = XCUIApplication()
        app.launchArguments = ["room-review", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["choose-walls-to-save"].waitForExistence(timeout: 5))
        capture(app, name: "room-review-accessibility-header-light")
        let longSpan = app.staticTexts["16 ft 5 in"]
        reveal(longSpan, in: app)
        XCTAssertTrue(isFullyVisible(longSpan, in: app))
        capture(app, name: "room-review-accessibility-long-span-light")
        let shortSpan = app.staticTexts["13 ft 1 in"]
        reveal(shortSpan, in: app)
        XCTAssertTrue(isFullyVisible(shortSpan, in: app))
        capture(app, name: "room-review-accessibility-light")
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<24 where !isFullyVisible(element, in: app) {
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @MainActor func testBuild66GeometryLossPromptsComparisonDespiteMoreFinishedWalls() {
        let app = XCUIApplication()
        app.launchArguments = ["room-spatial-compare", "dark"]
        app.launch()
        XCTAssertTrue(app.buttons["review-live-outline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["review-finished-outline"].exists)
        XCTAssertTrue(app.staticTexts["The outline changed after Finish"].exists)
        XCTAssertFalse(app.buttons["compare-outlines"].exists, "Finished review must not open automatically")
        capture(app, name: "room-report-spatial-comparison-dark")
        app.buttons["review-finished-outline"].tap()
        XCTAssertTrue(app.buttons["compare-outlines"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["review-live-outline"].exists)
        app.buttons["compare-outlines"].tap()
        XCTAssertTrue(app.buttons["review-live-outline"].waitForExistence(timeout: 5))
        app.buttons["review-live-outline"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["live-outline-warning"].waitForExistence(timeout: 5))
    }

    @MainActor func testShelfBinFitChecksHeadroomAndPersistsOnSavedRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["room-library", "dark"]
        app.launch()

        let practiceRoom = app.staticTexts["Practice room"]
        XCTAssertTrue(practiceRoom.waitForExistence(timeout: 5))
        practiceRoom.tap()

        let extraGroup = app.buttons["Ceiling & shelves"]
        for _ in 0..<6 where !extraGroup.isHittable { app.swipeUp() }
        XCTAssertTrue(extraGroup.waitForExistence(timeout: 5))
        extraGroup.tap()

        let editMeasurements = app.buttons["Edit ceiling & shelves"]
        for _ in 0..<4 where !editMeasurements.isHittable { app.swipeUp() }
        XCTAssertTrue(editMeasurements.waitForExistence(timeout: 5))
        editMeasurements.tap()

        let addShelf = app.buttons["add-shelf"]
        XCTAssertTrue(addShelf.waitForExistence(timeout: 5))
        addShelf.tap()

        let shelfFields = [
            ("shelf-depth-total-inches", "16"),
            ("shelf-width-total-inches", "36"),
            ("shelf-height-total-inches", "48")
        ]
        for (id, value) in shelfFields {
            let field = app.textFields[id]
            for _ in 0..<6 where !field.isHittable { app.swipeUp() }
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(value)
        }

        let binToggle = app.switches["shelf-check-bin"]
        for _ in 0..<6 where !binToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(binToggle.waitForExistence(timeout: 5))
        binToggle.switches.firstMatch.tap()

        let binFields = [
            ("shelf-bin-width-total-inches", "11"),
            ("shelf-bin-depth-total-inches", "14"),
            ("shelf-bin-height-total-inches", "10")
        ]
        for (id, value) in binFields {
            let field = app.textFields[id]
            for _ in 0..<6 where !field.isHittable { app.swipeUp() }
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(value)
        }

        app.buttons["keep-shelf"].tap()

        // Without clear space above (headroom), floor height (48 in) must not substitute for headroom.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Insufficient information to verify Bin")).firstMatch.waitForExistence(timeout: 5))

        // Open the shelf and enter 12 in of clear space above so the bin passes listed checks.
        app.staticTexts["Shelf"].tap()
        let clearanceField = app.textFields["shelf-clearance-total-inches"]
        for _ in 0..<6 where !clearanceField.isHittable { app.swipeUp() }
        XCTAssertTrue(clearanceField.waitForExistence(timeout: 5))
        clearanceField.tap()
        clearanceField.typeText("12")
        app.buttons["keep-shelf"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Bin passes listed shelf envelope checks")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["apply-room-measurements"].tap()

        let passedLabel = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Bin passes listed shelf envelope checks")).firstMatch
        for _ in 0..<6 where !passedLabel.exists { app.swipeUp() }
        XCTAssertTrue(passedLabel.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "up to 3 side-by-side")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "shelf weight capacity are not certified")).firstMatch.exists)
    }

    @MainActor private func isFullyVisible(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let viewport = app.scrollViews.firstMatch.frame.insetBy(dx: 0, dy: 8)
        // Leave room for the native floating bottom toolbar.
        let unobscured = CGRect(x: viewport.minX, y: viewport.minY,
                                width: viewport.width, height: viewport.height - 70)
        return element.isHittable && unobscured.contains(element.frame)
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
