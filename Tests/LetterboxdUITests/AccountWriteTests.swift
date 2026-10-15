import XCTest

/// Edit Profile and New List against the mock host (no network).
final class AccountWriteTests: XCTestCase {
    func launch(_ mode: String = "ok") -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["-Scenario", "ready", "-WriteMode", mode]
        continueAfterFailure = false; app.launch()
        XCTAssertTrue(app.buttons["Account"].waitForExistence(timeout: 8)); return app
    }
    func testEditProfileSavesOnlyAfterReadback() {
        let app = launch(); app.buttons["Account"].tap(); app.buttons["menu-edit-profile"].tap()
        let bio = app.textFields["profile-bio"].exists ? app.textFields["profile-bio"] : app.textViews["profile-bio"]
        XCTAssertTrue(bio.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["profile-save"].isEnabled, "nothing changed yet")
        XCTAssertFalse(app.textFields["profile-given-name"].exists)
        XCTAssertFalse(app.textFields["profile-location"].exists)
        bio.tap(); bio.typeText(" more")
        XCTAssertTrue(app.buttons["profile-save"].isEnabled)
        app.buttons["profile-save"].tap()
        XCTAssertTrue(app.staticTexts["Saved on Letterboxd"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["profile-save"].isEnabled)
    }
    func testEditProfileFailureShowsNoticeNotSaved() {
        let app = launch("fail"); app.buttons["Account"].tap(); app.buttons["menu-edit-profile"].tap()
        let loc = app.textFields["profile-bio"].exists ? app.textFields["profile-bio"] : app.textViews["profile-bio"]; XCTAssertTrue(loc.waitForExistence(timeout: 8))
        loc.tap(); loc.typeText("x"); app.buttons["profile-save"].tap()
        XCTAssertTrue(app.staticTexts["profile-notice"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["Saved on Letterboxd"].exists)
    }
    func testEditProfileLoadFailureOffersRetry() {
        let app = launch("loadfail"); app.buttons["Account"].tap(); app.buttons["menu-edit-profile"].tap()
        XCTAssertTrue(app.buttons["edit-profile-retry"].waitForExistence(timeout: 8))
    }
    func testNewListCreatesPrivateListWithReadback() {
        let app = launch()
        app.segmentedControls.firstMatch.buttons["Lists"].tap()
        let b = app.buttons["new-list-button"]; XCTAssertTrue(b.waitForExistence(timeout: 8)); b.tap()
        XCTAssertFalse(app.buttons["list-create"].isEnabled)
        let n = app.textFields["list-name"]; XCTAssertTrue(n.waitForExistence(timeout: 5)); n.tap(); n.typeText("Rainy day films")
        XCTAssertTrue(app.staticTexts["list-privacy"].exists || app.staticTexts["Private, only you can see it"].exists)
        app.buttons["list-create"].tap()
        XCTAssertTrue(app.staticTexts["list-created"].waitForExistence(timeout: 8) || app.staticTexts["Created “Rainy day films”"].waitForExistence(timeout: 2))
    }
    func testNewListFailureKeepsFormAndShowsNotice() {
        let app = launch("fail")
        app.segmentedControls.firstMatch.buttons["Lists"].tap(); app.buttons["new-list-button"].tap()
        let n = app.textFields["list-name"]; XCTAssertTrue(n.waitForExistence(timeout: 5)); n.tap(); n.typeText("X")
        app.buttons["list-create"].tap()
        XCTAssertTrue(app.staticTexts["list-notice"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["list-create"].isEnabled, "can retry")
    }
}
