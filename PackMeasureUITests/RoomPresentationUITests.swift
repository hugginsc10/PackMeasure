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
        let longSpan = app.staticTexts["5.00 m · 16.4 ft"]
        reveal(longSpan, in: app)
        XCTAssertTrue(isFullyVisible(longSpan, in: app))
        capture(app, name: "room-review-accessibility-long-span-light")
        let shortSpan = app.staticTexts["4.00 m · 13.1 ft"]
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
