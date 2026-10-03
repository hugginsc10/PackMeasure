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
}
