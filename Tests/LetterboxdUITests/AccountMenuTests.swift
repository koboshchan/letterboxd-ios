import XCTest

/// Account menu, Settings and sign-out confirmation against the mock host. No live sign-out and no network.
final class AccountMenuTests: XCTestCase {
    func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-Scenario", "ready"] + extra
        continueAfterFailure = false; app.launch()
        XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 8)); return app
    }
    func testMenuOrderSettingsBeforeSignOutLast() {
        let app = launch(); app.buttons["Account"].tap()
        let s = app.buttons["Settings"], o = app.buttons["menu-sign-out"]
        XCTAssertTrue(s.waitForExistence(timeout: 5)); XCTAssertTrue(o.exists)
        XCTAssertLessThan(s.frame.minY, o.frame.minY, "Sign Out must be last")
    }
    func testSignOutCancelKeepsSessionConfirmEndsIt() {
        let app = launch(); app.buttons["Account"].tap(); app.buttons["menu-sign-out"].tap()
        XCTAssertTrue(app.buttons["confirm-sign-out"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Account"].exists, "cancel must leave the session intact")
        app.buttons["Account"].tap(); app.buttons["menu-sign-out"].tap()
        app.buttons["confirm-sign-out"].tap()
        XCTAssertTrue(app.buttons["Account"].waitForNonExistence(timeout: 8))
    }
    func testSettingsAppearanceAndClearCache() {
        let app = launch(); app.buttons["Account"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.segmentedControls["appearance-picker"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["appearance-picker"].buttons["System"].isSelected)
        app.segmentedControls["appearance-picker"].buttons["Dark"].tap()
        XCTAssertTrue(app.segmentedControls["appearance-picker"].buttons["Dark"].isSelected)
        app.buttons["clear-cache"].tap()
        XCTAssertTrue(app.staticTexts["Cache cleared"].waitForExistence(timeout: 8))
    }
    func testAppearancePersistsAcrossRelaunch() {
        var app = launch(); app.buttons["Account"].tap(); app.buttons["Settings"].tap()
        app.segmentedControls["appearance-picker"].buttons["Light"].tap(); app.terminate()
        app = launch(); app.buttons["Account"].tap(); app.buttons["Settings"].tap()
        XCTAssertTrue(app.segmentedControls["appearance-picker"].buttons["Light"].isSelected)
        app.segmentedControls["appearance-picker"].buttons["System"].tap()   // restore default for other tests
    }
}
