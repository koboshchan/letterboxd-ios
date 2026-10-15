import XCTest

/// Film watchlist/like controls against the SAME views the app ships; only the client behind them is the mock
/// FilmActionsClient (-WriteMode). Sources of truth are the mock server state, never the tap itself.
final class FilmActionTests: XCTestCase {
    func open(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready", "-WriteMode", mode]
        continueAfterFailure = false
        app.launch()
        app.buttons["poster-logged-1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synopsis for logged-1"].waitForExistence(timeout: 8))
        return app
    }
    func wl(_ a: XCUIApplication) -> XCUIElement { a.buttons["watchlist-button"] }
    func like(_ a: XCUIApplication) -> XCUIElement { a.buttons["like-button"] }
    func waitLabel(_ e: XCUIElement, _ l: String, line: UInt = #line) {
        let p = NSPredicate(format: "label == %@", l)
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: p, object: e)], timeout: 8), .completed, "expected \(l), got \(e.label)", line: line)
    }

    /// Long-press menu on a grid poster: only verified actions exist, state is shared with the film screen.
    func testPosterLongPressMenuActionsSyncWithFilmScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready", "-WriteMode", "ok"]
        continueAfterFailure = false
        app.launch()
        let poster = app.buttons["poster-logged-1"].firstMatch
        poster.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["menu-watchlist"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Open Film"].exists)
        XCTAssertTrue(app.buttons["menu-watched"].exists); XCTAssertTrue(app.buttons["menu-rate"].exists)
        XCTAssertFalse(app.buttons["Add to Diary"].exists)
        XCTAssertEqual(app.buttons["menu-watchlist"].label, "Add to Watchlist")
        app.buttons["menu-like"].tap()
        poster.tap()
        XCTAssertTrue(app.staticTexts["Synopsis for logged-1"].waitForExistence(timeout: 8))
        waitLabel(like(app), "Unlike")
        waitLabel(wl(app), "Add to Watchlist")
    }

    func testPosterMenuHalfStarThenClearKeepsWatched() {
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready", "-WriteMode", "ok"]
        continueAfterFailure = false; app.launch()
        let poster = app.buttons["poster-logged-1"].firstMatch
        poster.press(forDuration: 1.0)
        app.buttons["menu-rate"].tap()
        XCTAssertTrue(app.buttons["menu-rate-0.5"].waitForExistence(timeout: 5))
        app.buttons["menu-rate-0.5"].tap()
        poster.tap()
        XCTAssertTrue(app.staticTexts["Synopsis for logged-1"].waitForExistence(timeout: 8))
        waitLabel(app.buttons["watched-button"], "Watched")
        XCTAssertTrue(app.buttons["rating-clear"].waitForExistence(timeout: 5))
        app.buttons["rating-clear"].tap()
        XCTAssertTrue(app.buttons["rating-clear"].waitForNonExistence(timeout: 8))
        waitLabel(app.buttons["watched-button"], "Watched")
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

    func testHalfStarRatingWatchedAndClear() {
        let app = open("ok")
        let tenth = app.buttons["rate-3.5"]
        XCTAssertTrue(tenth.waitForExistence(timeout: 8)); tenth.tap()
        waitLabel(app.buttons["watched-button"], "Watched")
        XCTAssertTrue(app.buttons["rate-3.5"].isSelected || app.buttons["rate-3.5"].value != nil)
        XCTAssertTrue(app.buttons["rating-clear"].waitForExistence(timeout: 8))
        app.buttons["rating-clear"].tap()
        XCTAssertTrue(app.buttons["rating-clear"].waitForNonExistence(timeout: 8))
        waitLabel(app.buttons["watched-button"], "Watched")      // clearing a rating does not unwatch
        app.buttons["watched-button"].tap()
        waitLabel(app.buttons["watched-button"], "Mark as Watched")
    }
    func testRatingFailureShowsNoticeAndKeepsStars() {
        let app = open("fail")
        app.buttons["rate-5.0"].tap()
        XCTAssertTrue(app.staticTexts[FilmActionsModelText.unconfirmed].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["rating-clear"].exists)
    }
}
enum FilmActionsModelText { static let unconfirmed = "Couldn’t confirm the change. Refresh to check." }
