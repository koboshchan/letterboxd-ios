import XCTest

final class PersonLayoutTests: XCTestCase {
    private func capture(_ appearance: XCUIDevice.Appearance, name: String) {
        XCUIDevice.shared.appearance = appearance
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready"]
        app.launch()
        let browse = app.buttons["tab-Browse"]
        XCTAssertTrue(browse.waitForExistence(timeout: 8)); browse.tap()
        let film = app.buttons["poster-popular-2"].firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 8)); film.tap()
        let actor = app.buttons["Cam Cast, actor"]
        XCTAssertTrue(actor.waitForExistence(timeout: 8)); actor.tap()
        XCTAssertTrue(app.staticTexts["About"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["More"].waitForExistence(timeout: 8))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "person-\(name)"; shot.lifetime = .keepAlways; add(shot)
        app.swipeUp()
        let card = app.buttons["poster-found-film"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        let grid = XCTAttachment(screenshot: app.screenshot())
        grid.name = "person-grid-\(name)"; grid.lifetime = .keepAlways; add(grid)
    }
    func testLightPersonLayout() { capture(.light, name: "light") }
    func testDarkPersonLayout() { capture(.dark, name: "dark") }
}
