import XCTest

/// Film detail regressions, run against the UI-test host (mock data only).
final class FilmDetailTests: XCTestCase {
    func open() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready", "-UIExposeBackdrop", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["poster-logged-1"].firstMatch.waitForExistence(timeout: 8))
        app.buttons["poster-logged-1"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Synopsis for logged-1"].waitForExistence(timeout: 8))
        return app
    }

    func testBackdropFillsScreenWidthAndTop() {
        let app = open()
        let backdrop = app.otherElements["film-backdrop"].firstMatch
        XCTAssertTrue(backdrop.waitForExistence(timeout: 5))
        let screen = app.windows.firstMatch.frame
        XCTAssertEqual(backdrop.frame.minX, screen.minX, accuracy: 1)
        XCTAssertEqual(backdrop.frame.width, screen.width, accuracy: 1)
        XCTAssertLessThanOrEqual(backdrop.frame.minY, screen.minY + 1)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Full-width film backdrop"
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testBackdropScrollsAwayWithContent() {
        let app = open()
        let b = app.otherElements["film-backdrop"].firstMatch
        XCTAssertTrue(b.waitForExistence(timeout: 5))
        let before = b.frame
        app.swipeUp(); app.swipeUp()
        XCTAssertLessThan(b.frame.minY, before.minY - 100, "backdrop must move up with the content, not stay pinned")
        XCTAssertFalse(b.isHittable && b.frame.maxY > 120, "backdrop should have scrolled off the top")
    }

    func testTabBarVisibleOnDetailNestedRoutesAndPop() {
        let app = open()
        XCTAssertTrue(app.buttons["tab-Browse"].isHittable); XCTAssertTrue(app.buttons["tab-Search"].isHittable)
        app.buttons["Lists featuring this film"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tab-Browse"].isHittable, "visible on nested route")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["tab-Browse"].isHittable, "visible after popping to film")
        app.navigationBars.buttons["Back"].firstMatch.tap()
        XCTAssertTrue(app.buttons["tab-Browse"].waitForExistence(timeout: 5), "tab bar restored on pop")
    }

    func testBottomNavLayoutAndRoots() {
        let app = XCUIApplication(); app.launchArguments = ["-Scenario", "ready"]; app.launch()
        let p = app.buttons["tab-Profile"], b = app.buttons["tab-Browse"], s = app.buttons["tab-Search"]
        XCTAssertTrue(p.waitForExistence(timeout: 8))
        XCTAssertLessThan(p.frame.maxX, s.frame.minX); XCTAssertLessThan(p.frame.minX, b.frame.minX)
        XCTAssertGreaterThan(s.frame.minX, app.windows.firstMatch.frame.width * 0.7, "search sits right")
        for e in [p, b, s] { XCTAssertGreaterThanOrEqual(e.frame.height, 44); XCTAssertGreaterThanOrEqual(e.frame.width, 44) }
        XCTAssertTrue(p.isSelected)
        b.tap(); XCTAssertTrue(b.isSelected); XCTAssertFalse(p.isSelected)
        s.tap(); XCTAssertTrue(s.isSelected)
        p.tap(); XCTAssertTrue(app.buttons["count-followers"].waitForExistence(timeout: 5))
    }

    func testActionsAboveSynopsisInInitialViewport() {
        let app = open()
        let wl = app.buttons["watchlist-button"], like = app.buttons["like-button"], syn = app.staticTexts["Synopsis for logged-1"]
        XCTAssertTrue(wl.waitForExistence(timeout: 8))
        XCTAssertLessThan(wl.frame.maxY, syn.frame.minY); XCTAssertLessThan(like.frame.maxY, syn.frame.minY)
        XCTAssertTrue(wl.isHittable && like.isHittable)
        wl.tap(); like.tap()
        let pred = NSPredicate(format: "label != %@", "Add to Watchlist")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: pred, object: wl)], timeout: 8), .completed)
    }

    func testShortSynopsisHasNoMoreButton() {
        let app = open()
        XCTAssertTrue(app.staticTexts["Synopsis for logged-1"].exists)
        XCTAssertFalse(app.buttons["synopsis-more"].exists, "short text must not offer more")
    }

    func testLongSynopsisCollapsesAndExpands() {
        let app = XCUIApplication()
        app.launchArguments = ["-Scenario", "ready", "-UILongSynopsis", "1"]
        app.launch()
        app.buttons["poster-logged-1"].firstMatch.tap()
        let more = app.buttons["synopsis-more"]
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        let text = app.staticTexts["synopsis-text"]
        let collapsed = text.frame.height
        XCTAssertGreaterThanOrEqual(more.frame.height, 44)
        more.tap()
        XCTAssertGreaterThan(text.frame.height, collapsed + 20, "expands to full text")
        app.buttons["synopsis-more"].tap()
        XCTAssertLessThan(text.frame.height, collapsed + 2)
    }

    func testCreditsAreTilesWithNameAndRoleAndNavigate() {
        let app = open()
        for id in ["credit-director-dana-director", "credit-actor-cam-cast", "credit-writer-wes-writer"] {
            var tries = 0
            while !app.buttons[id].exists && tries < 6 { app.swipeUp(); tries += 1 }
            XCTAssertTrue(app.buttons[id].exists, id)
        }
        let cast = app.buttons["credit-actor-cam-cast"]
        XCTAssertTrue(cast.staticTexts["Cam Cast"].exists); XCTAssertTrue(cast.staticTexts["Actor"].exists)
        XCTAssertGreaterThanOrEqual(cast.frame.height, 90)
        cast.tap()
        XCTAssertTrue(app.navigationBars["Cam Cast"].waitForExistence(timeout: 8))
    }

    func testEdgeSwipePopsToParent() {
        let app = open()
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.buttons["poster-logged-1"].firstMatch.waitForExistence(timeout: 5), "edge swipe returns to profile")
        XCTAssertFalse(app.staticTexts["Synopsis for logged-1"].exists)
    }

    func testBottomReachableAbovePersistentTabBar() {
        let app = open()
        for _ in 0..<6 { app.swipeUp() }
        let last = app.buttons["Lists featuring this film"].firstMatch
        XCTAssertTrue(last.isHittable)
        let h = app.windows.firstMatch.frame.height
        XCTAssertGreaterThan(last.frame.maxY, h - 230)
        XCTAssertLessThanOrEqual(last.frame.maxY, app.buttons["tab-Browse"].frame.minY, "content stays above the persistent nav")
    }
}
