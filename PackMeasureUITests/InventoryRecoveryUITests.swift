import XCTest

final class InventoryRecoveryUITests: XCTestCase {
    @MainActor
    func testUnreadableInventoryBlocksChangesAndCanRetry() {
        let app = XCUIApplication()
        app.launchArguments = ["inventory-recovery", "dark"]
        app.launch()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["inventory-retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home-measure-item"].isEnabled)
        XCTAssertFalse(app.buttons["home-manual-entry"].isEnabled)
        XCTAssertTrue(app.buttons["home-measure-room"].isEnabled)
        app.tabBars.buttons["Load"].tap()
        XCTAssertTrue(app.buttons["inventory-retry"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved pieces"].exists)
        app.buttons["fixture-repair-inventory"].tap()
        app.buttons["inventory-retry"].tap()
        let saved = savedRow(in: app)
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists)
        XCTAssertFalse(app.buttons["inventory-retry"].exists)
        app.tabBars.buttons["Measure"].tap()
        XCTAssertTrue(app.buttons["home-manual-entry"].isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "inventory-recovered"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testFailedManualSaveKeepsTheDraftAndSavedInventory() {
        let app = XCUIApplication()
        app.launchArguments = ["inventory-write-failure", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["home-manual-entry"].waitForExistence(timeout: 5))
        app.buttons["home-manual-entry"].tap()
        let fields = [("Item name", "Unsaved fixture box"), ("manual-length", "24"),
                      ("manual-width", "12"), ("manual-height", "18")]
        for (label, value) in fields {
            let field = app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            for _ in 0..<4 where !field.isHittable { app.swipeUp() }
            field.tap()
            field.typeText(value)
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        }
        app.navigationBars["Enter dimensions"].buttons["Save"].tap()
        XCTAssertTrue(app.alerts["Inventory not saved"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "not been saved")).firstMatch.exists)
        app.alerts["Inventory not saved"].buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Enter dimensions"].exists)
        XCTAssertEqual(app.textFields["Item name"].value as? String, "Unsaved fixture box")
        app.navigationBars["Enter dimensions"].buttons["Cancel"].tap()
        app.tabBars.buttons["Load"].tap()
        let saved = savedRow(in: app)
        reveal(saved, in: app)
        XCTAssertTrue(saved.exists)
        XCTAssertFalse(app.staticTexts["Unsaved fixture box"].exists)
    }

    @MainActor
    func testFailedPackingEditKeepsTheDraftAndCommittedName() {
        let app = XCUIApplication()
        app.launchArguments = ["inventory-write-failure", "light"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Load"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Load"].tap()
        let saved = savedRow(in: app)
        reveal(saved, in: app)
        saved.tap()
        let name = app.textFields["Item name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Saved fixture box".count) + "Edited fixture box")
        app.navigationBars["Packing details"].buttons["Save"].tap()
        XCTAssertTrue(app.alerts["Inventory not saved"].waitForExistence(timeout: 5))
        app.alerts["Inventory not saved"].buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Packing details"].exists)
        XCTAssertEqual(name.value as? String, "Edited fixture box")
        app.navigationBars["Packing details"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(savedRow(in: app).waitForExistence(timeout: 5))
    }

    @MainActor
    private func savedRow(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Saved fixture box")).firstMatch
    }

    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5))
    }
}
