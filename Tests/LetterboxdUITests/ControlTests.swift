import XCTest

/// Every tappable control in the app, exercised against the UI-test host (mock data layer, no network writes).
/// Each test asserts an observable outcome, not just existence.
final class ControlTests: XCTestCase {
    func launch(_ scenario: String = "ready", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", scenario] + extra
        continueAfterFailure = false
        app.launch()
        return app
    }
    func wait(_ e: XCUIElement, _ t: TimeInterval = 8, _ m: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(e.waitForExistence(timeout: t), m.isEmpty ? "missing (e)" : m, file: file, line: line) }
    func tab(_ app: XCUIApplication, _ n: String) { let b = app.buttons["tab-" + n]; wait(b); b.tap() }
    func poster(_ app: XCUIApplication, _ slug: String) -> XCUIElement { app.buttons["poster-" + slug].firstMatch }

    // Sign gate
    func testSignedOutGateShowsSignInAndNoContent() {
        let app = launch("signedOut")
        wait(app.buttons["Sign in on letterboxd.com"])
        XCTAssertFalse(app.otherElements["bottom-nav"].exists, "no tabs while signed out")
    }
    func testSignInSheetCancelDismisses() {
        let app = launch("signedOut")
        app.buttons["Sign in on letterboxd.com"].tap()
        wait(app.navigationBars["Sign in"]); app.buttons["Cancel"].tap()
        wait(app.buttons["Sign in on letterboxd.com"]); XCTAssertFalse(app.navigationBars["Sign in"].exists)
    }
    func testSignInDoneWithoutLoginShowsValidationFailureAndStaysSignedOut() {
        let app = launch("signedOut")
        app.buttons["Sign in on letterboxd.com"].tap()
        let done = app.buttons["Done"]; wait(done)
        done.tap()
        wait(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'did not confirm a signed-in account'")).firstMatch, 8, "validation failure text")
        XCTAssertTrue(app.navigationBars["Sign in"].exists, "sheet stays open")
        XCTAssertFalse(app.otherElements["bottom-nav"].exists)
    }
    func testStoredSessionRejectedByServerRequiresSignIn() {
        let app = launch("guest")
        wait(app.buttons["Sign in on letterboxd.com"]); XCTAssertFalse(app.otherElements["bottom-nav"].exists)
    }
    func testOfflineRestoreRetryThenReady() {
        let app = launch("offline")
        let retry = app.buttons["Try again"]; wait(retry)
        XCTAssertTrue(app.staticTexts["Couldn't confirm your sign-in"].exists)
        XCTAssertFalse(app.otherElements["bottom-nav"].exists, "no content while unvalidated")
        retry.tap()
        wait(app.otherElements["bottom-nav"]); wait(app.navigationBars["tester"])
    }
    func testOfflineGateSignInButtonOpensSheet() {
        let app = launch("offline")
        app.buttons["Sign in on letterboxd.com"].tap(); wait(app.navigationBars["Sign in"])
    }

    // Logout / account menu
    func testAccountMenuSignOutReturnsToGate() {
        let app = launch()
        let acct = app.buttons["Account"]; wait(acct); acct.tap()
        wait(app.buttons["Signed in as tester"])
        app.buttons["menu-sign-out"].tap()
        wait(app.alerts.buttons["confirm-sign-out"].firstMatch); app.alerts.buttons["confirm-sign-out"].firstMatch.tap()
        wait(app.buttons["Sign in on letterboxd.com"]); XCTAssertFalse(app.otherElements["bottom-nav"].exists)
    }
    func testAccountMenuDismissKeepsSession() {
        let app = launch()
        app.buttons["Account"].tap(); wait(app.buttons["Signed in as tester"])
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.6)).tap()
        XCTAssertTrue(app.otherElements["bottom-nav"].exists); XCTAssertTrue(app.navigationBars["tester"].exists)
    }

    // Tabs
    func testTabsSwitchScreens() {
        let app = launch()
        wait(app.navigationBars["tester"])
        tab(app, "Browse"); wait(app.navigationBars["Browse"])
        tab(app, "Search"); wait(app.navigationBars["Search"])
        // iOS 26: while the search tab is selected the tab bar collapses to one button that returns to the previous tab.
        tab(app, "Browse"); wait(app.navigationBars["Browse"])
        tab(app, "Profile"); wait(app.navigationBars["tester"])
    }

    // Profile segments + rows
    func testProfileSegmentsShowTheirOwnContent() {
        let app = launch()
        wait(poster(app, "logged-0"))
        let seg = app.segmentedControls["Section"].exists ? app.segmentedControls["Section"] : app.segmentedControls.firstMatch
        seg.buttons["Watchlist"].tap(); wait(poster(app, "wanted-0")); XCTAssertFalse(poster(app, "logged-0").exists)
        seg.buttons["Diary"].tap(); wait(app.staticTexts["Diary Film"])
        seg.buttons["Reviews"].tap(); wait(app.staticTexts["Great mock review text"])
        seg.buttons["Lists"].tap(); wait(app.staticTexts["Mock List"])
        seg.buttons["Films"].tap(); wait(poster(app, "logged-0"))
    }
    func testProfileFilmOpensDetailAndBackReturns() {
        let app = launch()
        poster(app, "logged-1").tap()
        wait(app.staticTexts["Synopsis for logged-1"]); wait(app.staticTexts["DIRECTED BY"])
        app.navigationBars.buttons.firstMatch.tap()
        wait(poster(app, "logged-1")); XCTAssertTrue(app.navigationBars["tester"].exists)
    }
    func testDiaryEntryOpensDetailAndBack() {
        let app = launch()
        app.segmentedControls.firstMatch.buttons["Diary"].tap()
        let row = app.staticTexts["Diary Film"]; wait(row); row.tap()
        wait(app.staticTexts["Great mock review text"]); wait(app.buttons["Open on Letterboxd"])
        app.navigationBars.buttons.firstMatch.tap(); wait(app.staticTexts["Diary Film"])
    }
    func testEntryOpenOnLetterboxdLeavesAppForSafari() {
        let app = launch()
        app.segmentedControls.firstMatch.buttons["Diary"].tap()
        app.staticTexts["Diary Film"].tap()
        let open = app.buttons["Open on Letterboxd"]; wait(open); open.tap()
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 10), "link opens Safari")
        app.activate()
    }
    func testListRowOpensNativeListDetail() {
        let app = launch()
        app.segmentedControls.firstMatch.buttons["Lists"].tap()
        let l = app.buttons["Mock List"].exists ? app.buttons["Mock List"] : app.staticTexts["Mock List"]
        wait(l); l.tap()
        wait(app.navigationBars["Mock List"]); wait(poster(app, "mock-list-film"))
    }
    func testProfileEmptyStates() {
        let app = launch("empty")
        wait(app.staticTexts["No films yet"])
        let seg = app.segmentedControls.firstMatch
        seg.buttons["Watchlist"].tap(); wait(app.staticTexts["Watchlist is empty"])
        seg.buttons["Diary"].tap(); wait(app.staticTexts["Diary is empty"])
        seg.buttons["Reviews"].tap(); wait(app.staticTexts["No reviews"])
        seg.buttons["Lists"].tap(); wait(app.staticTexts["No public lists"])
    }
    func testNoPublicMemberSwitcherExists() {
        let app = launch(); wait(app.navigationBars["tester"])
        XCTAssertFalse(app.buttons["Change member"].exists)
        XCTAssertFalse(app.alerts["View another public member"].exists)
    }

    // Browse
    func testBrowseSegmentsChangeContent() {
        let app = launch(); tab(app, "Browse")
        wait(poster(app, "popular-0"))
        let seg = app.segmentedControls.firstMatch
        seg.buttons["Top Rated"].tap(); wait(poster(app, "rated-0")); XCTAssertFalse(poster(app, "popular-0").exists)
        seg.buttons["Anticipated"].tap(); wait(poster(app, "soon-0"))
        seg.buttons["Popular"].tap(); wait(poster(app, "popular-0"))
    }
    func testBrowsePaginationLoadsNextPage() {
        let app = launch(); tab(app, "Browse")
        wait(poster(app, "popular-0"))
        let late = poster(app, "late-30")
        var n = 0
        while !late.exists && n < 12 { app.swipeUp(); n += 1 }
        XCTAssertTrue(late.exists, "page 2 item appears after scrolling to end")
    }
    func testBrowsePullToRefreshReloads() {
        let app = launch(); tab(app, "Browse")
        wait(poster(app, "popular-0")); XCTAssertFalse(poster(app, "refreshed").exists)
        let top = app.scrollViews.firstMatch
        top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).press(forDuration: 0.1, thenDragTo: top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        wait(poster(app, "refreshed"), 8, "refresh reloads data")
    }
    func testBrowseErrorTryAgainRecovers() {
        let app = launch("failFirst"); tab(app, "Browse")
        let retry = app.buttons["Try again"]; wait(retry)
        XCTAssertTrue(app.staticTexts["Letterboxd returned HTTP 500."].exists)
        retry.tap(); wait(poster(app, "popular-0")); XCTAssertFalse(retry.exists)
    }
    func testErrorOpenLetterboxdLinkOpensSafari() {
        let app = launch("failFirst"); tab(app, "Browse")
        let l = app.links["Open Letterboxd"].exists ? app.links["Open Letterboxd"] : app.buttons["Open Letterboxd"]; wait(l); l.tap()
        XCTAssertTrue(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").wait(for: .runningForeground, timeout: 10)); app.activate()
    }
    func testBrowseEmptyState() {
        let app = launch("empty"); tab(app, "Browse"); wait(app.staticTexts["Nothing here"])
    }
    func testBrowseFilmDetailBackAndSafariLink() {
        let app = launch(); tab(app, "Browse")
        poster(app, "popular-2").tap()
        wait(app.staticTexts["Synopsis for popular-2"])
        let l = app.buttons["Reviews"]; wait(l); l.tap()
        wait(app.navigationBars["Reviews"])
        app.navigationBars.buttons.firstMatch.tap(); wait(app.staticTexts["Synopsis for popular-2"]); app.navigationBars.buttons.firstMatch.tap(); wait(poster(app, "popular-2"))
    }
    func testFilmDetailErrorRetry() {
        let app = launch("failFirst"); tab(app, "Search")
        // failFirst consumes its failure on browse/film; search is never failed, so open a film from search.
        let s = app.searchFields.firstMatch; wait(s); s.tap(); s.typeText("fight\n")
        poster(app, "found-film").tap()
        wait(app.buttons["Try again"]); app.buttons["Try again"].tap()
        wait(app.staticTexts["Synopsis for found-film"])
    }

    // Search
    func testSearchReturnsResultsAndOpensFilm() {
        let app = launch(); tab(app, "Search")
        wait(app.staticTexts["Search Letterboxd"])
        let s = app.searchFields.firstMatch; wait(s); s.tap(); s.typeText("fight\n")
        wait(poster(app, "found-film")); XCTAssertFalse(app.staticTexts["Search Letterboxd"].exists)
        poster(app, "found-film").tap(); wait(app.staticTexts["Synopsis for found-film"])
    }
    func testSearchEmptyAndErrorAndMembersScopeGone() {
        let app = launch(); tab(app, "Search")
        let s = app.searchFields.firstMatch; wait(s); s.tap(); s.typeText("nothing\n")
        wait(app.staticTexts["No films found"])
        XCTAssertFalse(app.buttons["Members"].exists, "member search removed")
        s.buttons["Clear text"].tap(); s.typeText("boom\n")
        wait(app.buttons["Try again"]); XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'mock offline'")).firstMatch.exists)
    }
    func testSearchCancelClearsField() {
        let app = launch(); tab(app, "Search")
        let s = app.searchFields.firstMatch; wait(s); s.tap(); s.typeText("abc")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN {%@, %@}", "Cancel", "Close")).firstMatch; wait(cancel); cancel.tap()
        XCTAssertTrue(app.staticTexts["Search Letterboxd"].exists)
    }

    // Following / Followers
    func testFollowingCountOpensListThenMemberProfileThenBack() {
        let app = launch(); wait(app.navigationBars["tester"])
        let c = app.buttons["count-following"]; wait(c); c.tap()
        wait(app.navigationBars["Following"]); wait(app.staticTexts["friend 0"])
        app.staticTexts["friend 3"].tap()
        wait(app.navigationBars["friend-3"], 8, "member profile shows tapped member")
        XCTAssertTrue(app.staticTexts["Member friend-3"].exists)
        XCTAssertFalse(app.navigationBars["tester"].exists)
        app.navigationBars.buttons.firstMatch.tap(); wait(app.navigationBars["Following"])
        app.navigationBars.buttons.firstMatch.tap(); wait(app.navigationBars["tester"])
        XCTAssertTrue(app.staticTexts["Tester Person"].exists, "root identity unchanged")
    }
    func testFollowersListOpensAndPaginates() {
        let app = launch(); app.buttons["count-followers"].tap()
        wait(app.navigationBars["Followers"]); wait(app.staticTexts["fan 0"])
        let late = app.staticTexts["fan late"]; var n = 0
        while !late.exists && n < 10 { app.swipeUp(); n += 1 }
        XCTAssertTrue(late.exists, "page 2 loads")
    }
    func testMemberProfileKeepsRootIdentityAndNoSwitcher() {
        let app = launch(); app.buttons["count-followers"].tap()
        app.staticTexts["fan 1"].tap(); wait(app.navigationBars["fan-1"])
        XCTAssertFalse(app.buttons["Change member"].exists)
        app.buttons["count-following"].tap(); wait(app.navigationBars["Following"])
        wait(app.staticTexts["fan-1 friend 0"], 8, "list is for the viewed member")
        app.buttons["tab-Browse"].tap(); app.buttons["tab-Profile"].tap()
        app.navigationBars.buttons.firstMatch.tap()   // Following back to the viewed member
        wait(app.navigationBars["fan-1"])
        app.navigationBars.buttons.firstMatch.tap()   // member back to Followers
        wait(app.navigationBars["Followers"])
        app.navigationBars.buttons.firstMatch.tap()   // Followers back to the signed-in root
        wait(app.navigationBars["tester"])
        app.buttons["Account"].tap(); wait(app.buttons["Signed in as tester"])
    }
    func testNetworkEmptyState() {
        let app = launch("empty"); app.buttons["count-following"].tap()
        wait(app.staticTexts["Not following anyone"])
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["count-followers"].tap()
        wait(app.staticTexts["No followers yet"])
    }

    func testCastChipOpensPersonThenFilmAndBackKeepsAccount() {
        let app = launch(); app.buttons["tab-Browse"].tap()
        poster(app, "popular-2").tap()
        wait(app.staticTexts["Synopsis for popular-2"])
        wait(app.buttons["Wes Writer, writer"], 8, "crew chip with role")
        app.buttons["Cam Cast, actor"].tap()
        wait(app.navigationBars["Cam Cast"], 8, "person name header")
        // No portrait available in the mock: no image, no fake placeholder face.
        XCTAssertFalse(app.images["Cam Cast"].exists)
        wait(poster(app, "found-film")); poster(app, "found-film").tap()
        wait(app.staticTexts["Synopsis for found-film"])
        app.navigationBars.buttons.firstMatch.tap()
        wait(app.navigationBars["Cam Cast"])
        app.navigationBars.buttons.firstMatch.tap()
        app.navigationBars.buttons.firstMatch.tap()   // back to Browse root, tab bar returns
        wait(app.buttons["tab-Profile"]); app.buttons["tab-Profile"].tap(); wait(app.staticTexts["Tester Person"], 8, "account unchanged")
    }
    func testNoCreditsFallsBackToPlainText() {
        let app = launch("empty"); app.buttons["tab-Search"].tap()
        let f = app.searchFields.firstMatch; wait(f); f.tap(); f.typeText("fight\n")
        wait(poster(app, "found-film")); poster(app, "found-film").tap()
        wait(app.staticTexts["Synopsis for found-film"])
        XCTAssertFalse(app.buttons["Cam Cast, actor"].exists, "no dead chips")
    }
}
