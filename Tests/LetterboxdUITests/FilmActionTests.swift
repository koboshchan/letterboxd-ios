import XCTest

/// Film watchlist/like controls against the SAME views the app ships; only the client behind them is the mock
/// FilmActionsClient (-WriteMode). Sources of truth are the mock server state, never the tap itself.
final class FilmActionTests: XCTestCase {
    func open(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready", "-WriteMode", mode]
        continueAfterFailure = false
        app.launch()
        app.buttons["Logged 1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synopsis for logged-1"].waitForExistence(timeout: 8))
        return app
    }
    func wl(_ a: XCUIApplication) -> XCUIElement { a.buttons["watchlist-button"] }
    func like(_ a: XCUIApplication) -> XCUIElement { a.buttons["like-button"] }
    func waitLabel(_ e: XCUIElement, _ l: String, line: UInt = #line) {
        let p = NSPredicate(format: "label == %@", l)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: 8), .completed, "expected \(l), got \(e.label)", line: line)
    }

    func testBothDirectionsServerConfirmed() {
        let app = open("ok")
        waitLabel(wl(app), "Add to Watchlist"); waitLabel(like(app), "Like")
        wl(app).tap(); waitLabel(wl(app), "Remove from Watchlist")
        wl(app).tap(); waitLabel(wl(app), "Add to Watchlist")
        like(app).tap(); waitLabel(like(app), "Unlike")
        like(app).tap(); waitLabel(like(app), "Like")
    }
    func testPendingDisablesButtonsThenSettles() {
        let app = open("slow")
        wl(app).tap()
        XCTAssertTrue(app.activityIndicators["film-action-progress"].waitForExistence(timeout: 3) || !wl(app).isEnabled)
        XCTAssertFalse(like(app).isEnabled, "other controls disabled while a write is pending")
        waitLabel(wl(app), "Remove from Watchlist")
        XCTAssertTrue(like(app).isEnabled)
    }
    func testDefiniteFailureShowsErrorAndRefreshRecovers() {
        let app = open("fail")
        wl(app).tap()
        let n = app.staticTexts["film-action-notice"]; XCTAssertTrue(n.waitForExistence(timeout: 8))
        XCTAssertEqual(n.label, "Couldn’t confirm the change. Refresh to check.")
        XCTAssertFalse(n.label.contains("Nothing was changed"))
        XCTAssertTrue(app.buttons["film-action-refresh"].exists)
    }
    func testTimeoutAfterCommitNeverClaimsUnchangedAndRefreshShowsTruth() {
        let app = open("timeout")
        wl(app).tap()
        let n = app.staticTexts["film-action-notice"]; XCTAssertTrue(n.waitForExistence(timeout: 8))
        XCTAssertEqual(n.label, "Couldn’t confirm the change. Refresh to check.")
        waitLabel(wl(app), "Add to Watchlist")                 // unknown again, offers Add rather than a guessed state
        app.buttons["film-action-refresh"].tap()
        waitLabel(wl(app), "Remove from Watchlist")            // server DID commit; refresh reveals it
        XCTAssertFalse(n.exists)
    }
    func testReadbackMismatchIsNotShownAsSuccess() {
        let app = open("mismatch")
        wl(app).tap()
        XCTAssertTrue(app.staticTexts["film-action-notice"].waitForExistence(timeout: 8))
        waitLabel(wl(app), "Add to Watchlist")
    }
    func testStateLoadFailureOffersExplicitActionsAndRefresh() {
        let app = open("loadfail")
        XCTAssertTrue(app.buttons["film-action-refresh"].waitForExistence(timeout: 8))
        waitLabel(wl(app), "Add to Watchlist"); waitLabel(like(app), "Like")   // explicit actions, not ambiguous toggles
    }
    func testLogoutDuringWriteDropsStaleResult() {
        let app = open("logout")
        wl(app).tap()
        XCTAssertTrue(app.buttons["Sign in on letterboxd.com"].waitForExistence(timeout: 8) || !wl(app).exists || wl(app).label == "Add to Watchlist",
                      "stale result must not render as confirmed state")
        XCTAssertFalse(app.buttons["Remove from Watchlist"].exists)
    }
}
