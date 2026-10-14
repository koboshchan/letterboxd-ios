import XCTest

/// Screenshot capture against the UI-test host (mock data, NOT real user data). Attachments are exported from the xcresult.
final class ShotTests: XCTestCase {
    func run(_ mode: XCUIDevice.Appearance, _ tag: String) {
        XCUIDevice.shared.appearance = mode
        continueAfterFailure = true
        func shot(_ app: XCUIApplication, _ n: String) { sleep(1); let a = XCTAttachment(screenshot: app.screenshot()); a.name = "\(tag)-\(n)"; a.lifetime = .keepAlways; add(a) }
        func w(_ e: XCUIElement) { _ = e.waitForExistence(timeout: 8) }
        func back(_ app: XCUIApplication) { app.navigationBars.buttons.firstMatch.tap() }
        var app = XCUIApplication(); app.launchArguments = ["-Scenario", "signedOut"]; app.launch()
        w(app.buttons["Sign in on letterboxd.com"]); shot(app, "01-gate")
        app.terminate()
        app = XCUIApplication(); app.launchArguments = ["-Scenario", "ready"]; app.launch()
        w(app.buttons["poster-logged-0"].firstMatch); shot(app, "02-profile-films")
        let seg = app.segmentedControls.firstMatch
        seg.buttons["Diary"].tap(); w(app.staticTexts["Diary Film"]); shot(app, "03-profile-diary")
        app.staticTexts["Diary Film"].tap(); w(app.buttons["Open on Letterboxd"]); shot(app, "04-diary-entry-review"); back(app)
        seg.buttons["Reviews"].tap(); w(app.staticTexts["Great mock review text"]); shot(app, "05-profile-reviews")
        seg.buttons["Lists"].tap(); w(app.staticTexts["Mock List"]); shot(app, "06-profile-lists")
        app.staticTexts["Mock List"].tap(); sleep(2); shot(app, "07-list-detail"); back(app)
        seg.buttons["Films"].tap()
        app.buttons["count-followers"].tap(); w(app.staticTexts["fan 0"]); shot(app, "08-followers")
        app.staticTexts["fan 1"].tap(); w(app.navigationBars["fan-1"]); shot(app, "09-member-profile")
        app.tabBars.buttons["Browse"].tap(); app.tabBars.buttons["Profile"].tap(); app.tabBars.buttons["Profile"].tap()
        app.tabBars.buttons["Browse"].tap(); w(app.buttons["poster-popular-2"].firstMatch); shot(app, "10-browse")
        app.buttons["poster-popular-2"].firstMatch.tap(); w(app.staticTexts["Synopsis for popular-2"]); shot(app, "11-film-detail-actions")
        app.swipeUp(); shot(app, "12-film-detail-credits")
        app.buttons["Cam Cast, actor"].tap(); w(app.navigationBars["Cam Cast"]); shot(app, "13-person")
        back(app)
        if app.buttons["Reviews"].exists { app.buttons["Reviews"].tap(); sleep(2); shot(app, "14-film-reviews"); back(app) }
        if app.buttons["Lists featuring this film"].exists { app.buttons["Lists featuring this film"].tap(); sleep(2); shot(app, "15-film-lists") }
    }
    func testBottoms() {
        XCUIDevice.shared.appearance = .light
        func shot(_ app: XCUIApplication, _ n: String) { sleep(1); let a = XCTAttachment(screenshot: app.screenshot()); a.name = "bottom-\(n)"; a.lifetime = .keepAlways; add(a) }
        let app = XCUIApplication(); app.launchArguments = ["-Scenario", "ready"]; app.launch()
        app.buttons["count-followers"].tap(); _ = app.staticTexts["fan 0"].waitForExistence(timeout: 8)
        for _ in 0..<10 { app.swipeUp() }; shot(app, "followers")
        app.navigationBars.buttons.firstMatch.tap()
        app.tabBars.buttons["Browse"].tap(); _ = app.buttons["poster-popular-2"].firstMatch.waitForExistence(timeout: 8)
        for _ in 0..<6 { app.swipeUp() }; shot(app, "browse")
        app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown(); app.swipeDown()
        app.buttons["poster-popular-2"].firstMatch.tap(); _ = app.staticTexts["Synopsis for popular-2"].waitForExistence(timeout: 8)
        for _ in 0..<6 { app.swipeUp() }; shot(app, "film")
    }
    func testLight() { run(.light, "light") }
    func testDark() { run(.dark, "dark") }
}
