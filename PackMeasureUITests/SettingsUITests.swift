import XCTest

final class SettingsUITests: XCTestCase {
    @MainActor func testSettingsApplyToSavedRoomsAndSurviveRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["settings-room"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Practice room"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        choose("settings-units", value: "Centimeters", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "25.40 cm")).firstMatch.exists)
        choose("settings-appearance", value: "Dark", in: app)
        choose("settings-room-guidance", value: "Tight closet", in: app)
        choose("settings-floorplan-labels", value: "Wall IDs", in: app)
        capture(app, name: "settings-dark-centimeters")
        app.tabBars.buttons["Rooms"].tap()
        app.staticTexts["Practice room"].tap()
        reveal(app.staticTexts["500.0 cm"], in: app)
        XCTAssertTrue(app.staticTexts["500.0 cm"].isHittable)
        capture(app, name: "room-centimeters-from-settings")
        app.terminate()

        app.launchArguments = ["settings-room", "settings-preserve"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        assertChoice("settings-appearance", contains: "Dark", in: app)
        assertChoice("settings-units", contains: "Centimeters", in: app)
        assertChoice("settings-room-guidance", contains: "Tight closet", in: app)
        assertChoice("settings-floorplan-labels", contains: "Wall IDs", in: app)
        choose("settings-appearance", value: "Light", in: app)
        choose("settings-units", value: "Both", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "10.00 in · 25.40 cm")).firstMatch.exists)
        capture(app, name: "settings-light-both")
    }

    @MainActor func testSettingsAtLargestAccessibilitySize() {
        let app = XCUIApplication()
        app.launchArguments = ["home", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["settings-appearance"].waitForExistence(timeout: 5))
        choose("settings-units", value: "Centimeters", in: app)
        capture(app, name: "settings-accessibility-light")
        reveal(app.buttons["settings-floorplan-labels"], in: app)
        XCTAssertTrue(app.buttons["settings-floorplan-labels"].isHittable)
    }

    @MainActor private func choose(_ identifier: String, value: String, in app: XCUIApplication) {
        let picker = app.buttons[identifier]
        reveal(picker, in: app)
        picker.tap()
        let option = app.buttons[value]
        XCTAssertTrue(option.waitForExistence(timeout: 3))
        option.tap()
    }

    @MainActor private func assertChoice(_ identifier: String, contains choice: String, in app: XCUIApplication) {
        let picker = app.buttons[identifier]
        XCTAssertTrue((picker.label + " " + (picker.value as? String ?? "")).contains(choice))
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
