import XCTest

final class HomeUITests: XCTestCase {
    @MainActor func testLightHomeOpensRoomLibrary() { checkHome(appearance: "light") }
    @MainActor func testDarkHomeOpensRoomLibrary() { checkHome(appearance: "dark") }

    @MainActor private func checkHome(appearance: String) {
        let app = XCUIApplication()
        app.launchArguments = ["home", appearance]
        app.launch()
        let room = app.buttons["home-measure-room"]
        XCTAssertTrue(room.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home-measure-interior"].isHittable)
        XCTAssertTrue(app.buttons["home-measure-item"].isHittable)
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "home-\(appearance)"
        home.lifetime = .keepAlways
        add(home)
        room.tap()
        XCTAssertTrue(app.buttons["Scan a room"].waitForExistence(timeout: 5))
        let rooms = XCTAttachment(screenshot: app.screenshot())
        rooms.name = "rooms-\(appearance)"
        rooms.lifetime = .keepAlways
        add(rooms)
    }

    @MainActor
    func testAssignedVehicleVerificationChecksDoorAndProvenance() {
        let app = XCUIApplication()
        app.launchArguments = ["home", "dark"]
        app.launch()

        let manualEntry = app.buttons["home-manual-entry"]
        XCTAssertTrue(manualEntry.waitForExistence(timeout: 5))
        manualEntry.tap()

        let itemFields = [
            ("Item name", "Tall bookcase"),
            ("manual-length", "30"),
            ("manual-width", "15"),
            ("manual-height", "55")
        ]
        for (label, value) in itemFields {
            let field = app.textFields[label]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            for _ in 0..<4 where !field.isHittable { app.swipeUp() }
            field.tap()
            field.typeText(value)
        }
        app.navigationBars["Enter dimensions"].buttons["Save"].tap()

        XCTAssertTrue(app.tabBars.buttons["Load"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Load"].tap()

        let configure = app.buttons["assigned-vehicle-configure"]
        for _ in 0..<6 where !configure.isHittable { app.swipeUp() }
        XCTAssertTrue(configure.waitForExistence(timeout: 5))
        configure.tap()

        // 1. Pre-fill from Ram ProMaster high-roof van (catalog interior, unmeasured rear door)
        let catalogMenu = app.buttons["assigned-vehicle-catalog-menu"]
        XCTAssertTrue(catalogMenu.waitForExistence(timeout: 5))
        catalogMenu.tap()
        let proMaster = app.buttons["Ram ProMaster high-roof van"]
        XCTAssertTrue(proMaster.waitForExistence(timeout: 5))
        proMaster.tap()
        app.buttons["assigned-vehicle-save"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Does not pass listed dimensional checks")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Interior (Catalog profile)")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Rear door (Not measured)")).firstMatch.exists)

        // 2. Enter a measured 61 × 48 in rear door so the 55 in upright bookcase fails door clearance
        let editVehicle = app.buttons["assigned-vehicle-edit"]
        for _ in 0..<4 where !editVehicle.isHittable { app.swipeUp() }
        editVehicle.tap()

        let doorToggle = app.switches["assigned-vehicle-door-measured"]
        for _ in 0..<4 where !doorToggle.isHittable { app.swipeUp() }
        XCTAssertTrue(doorToggle.waitForExistence(timeout: 5))
        doorToggle.switches.firstMatch.tap()

        let doorWidth = app.textFields["assigned-vehicle-door-width"]
        for _ in 0..<4 where !doorWidth.isHittable { app.swipeUp() }
        XCTAssertTrue(doorWidth.waitForExistence(timeout: 5))
        doorWidth.tap()
        doorWidth.typeText("61")

        let doorHeight = app.textFields["assigned-vehicle-door-height"]
        for _ in 0..<4 where !doorHeight.isHittable { app.swipeUp() }
        XCTAssertTrue(doorHeight.waitForExistence(timeout: 5))
        doorHeight.tap()
        doorHeight.typeText("48")

        app.buttons["assigned-vehicle-save"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Interior (Catalog profile)")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Rear door (Entered measurements)")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Tall bookcase")).firstMatch.exists)

        // 3. Switch to U-Haul 10 ft truck (71 × 67 in door) so all dimensional checks pass
        for _ in 0..<4 where !editVehicle.isHittable { app.swipeUp() }
        editVehicle.tap()
        XCTAssertTrue(catalogMenu.waitForExistence(timeout: 5))
        catalogMenu.tap()
        let tenFootTruck = app.buttons["U-Haul 10 ft truck"]
        XCTAssertTrue(tenFootTruck.waitForExistence(timeout: 5))
        tenFootTruck.tap()
        app.buttons["assigned-vehicle-save"].tap()

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Passes listed dimensional checks")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Payload capacity, 3D arrangement, and maneuvering path remain unverified.")).firstMatch.exists)
    }
}
