import XCTest
@testable import Letterboxd
import LetterboxdKit

@MainActor
final class GateTests: XCTestCase {
    nonisolated static let signedIn = String(decoding: try! Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("LetterboxdKitTests/Fixtures/recorded/authenticated-identity.sanitized.html")), as: UTF8.self)
    nonisolated static func session(_ u: String = "example-member") -> Session { Session(username: u, cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")]) }
    func model(store: SessionStore, fetch: @escaping HomepageFetcher) -> AccountModel { let m = AccountModel(store: store, fetch: fetch); m.auth = AuthAuthority(); return m }

    func testNoStoredSessionRequiresSignInAndNeverGuestBrowse() async {
        let m = model(store: InMemorySessionStore()) { _ in XCTFail("no network without a stored session"); return (200, "") }
        XCTAssertEqual(m.gate, .checking)
        await m.restore()
        XCTAssertEqual(m.gate, .signInRequired); XCTAssertNil(m.username)
    }
    func testUnvalidatedKeychainSessionNeverReady() async throws {
        let s = InMemorySessionStore(); try s.save(Self.session())
        let m = model(store: s) { _ in (200, "<html>person.loggedIn = false</html>") }
        XCTAssertEqual(m.gate, .checking)
        await m.restore()
        XCTAssertEqual(m.gate, .signInRequired); XCTAssertNil(try s.load())
    }
    func testValidatedSessionIsReadyOnlyAfterServerConfirms() async throws {
        let s = InMemorySessionStore(); try s.save(Self.session())
        let m = model(store: s) { _ in (200, Self.signedIn) }
        await m.restore()
        XCTAssertEqual(m.gate, .ready("example-member")); XCTAssertEqual(m.auth?.username, "example-member")
    }
    func testOfflineRestoreShowsErrorGateNotContent() async throws {
        let s = InMemorySessionStore(); try s.save(Self.session())
        let m = model(store: s) { _ in throw URLError(.notConnectedToInternet) }
        await m.restore()
        if case .restoreFailed = m.gate {} else { XCTFail("expected restoreFailed, got \(m.gate)") }
        XCTAssertNil(m.auth?.cookieHeader()); XCTAssertNotNil(try s.load(), "offline keeps the stored session for retry")
    }
    func testExpiredSessionRequiresSignIn() async throws {
        let s = InMemorySessionStore(); try s.save(Session(username: "example-member", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com", expires: Date(timeIntervalSince1970: 1))]))
        let m = model(store: s) { _ in XCTFail("expired cookies must not be sent"); return (200, "") }
        await m.restore()
        XCTAssertEqual(m.gate, .signInRequired)
    }
    func testSignOutReturnsToSignInAndResetsEnvironment() async throws {
        let s = InMemorySessionStore(); try s.save(Self.session())
        let m = model(store: s) { _ in (200, Self.signedIn) }
        let env = AppEnvironment.make()
        m.onUsernameChange = { env.bind(username: $0) }
        await m.restore(); XCTAssertEqual(env.username, "example-member")
        let epoch = m.epoch
        await m.signOut()
        XCTAssertEqual(m.gate, .signInRequired); XCTAssertEqual(env.username, ""); XCTAssertGreaterThan(m.epoch, epoch)
        XCTAssertNil(m.auth?.cookieHeader()); XCTAssertNil(try s.load())
    }
    func testAccountSwitchDoesNotKeepPreviousUsername() async throws {
        let s = InMemorySessionStore(); try s.save(Self.session("alice"))
        let m = model(store: s) { _ in (200, Self.signedIn.replacingOccurrences(of: "example-member", with: "alice")) }
        let env = AppEnvironment.make(); m.onUsernameChange = { env.bind(username: $0) }
        await m.restore(); XCTAssertEqual(env.username, "alice")
        await m.signOut(); XCTAssertEqual(env.username, "")
        try s.save(Self.session("bob")); let m2 = model(store: s) { _ in (200, Self.signedIn.replacingOccurrences(of: "example-member", with: "bob")) }
        m2.onUsernameChange = { env.bind(username: $0) }; await m2.restore(); XCTAssertEqual(env.username, "bob")
    }
    func testProductionHasNoDemoOrGuestDefaults() {
        let env = AppEnvironment.make()
        XCTAssertEqual(env.username, "", "no default/guest member before validation")
        XCTAssertTrue(env.service is PublicWebService)
    }

    // Profile identity is bound only to the validated session: switching/reset follows the account, no manual override.
    func testEnvironmentUsernameFollowsValidatedSessionOnly() async throws {
        let auth = AuthAuthority()
        let env = AppEnvironment(service: PublicWebService(fetcher: Fetcher(transport: URLSessionTransport(cookieHeader: { auth.cookieHeader() }), auth: auth)), auth: auth)
        XCTAssertEqual(env.username, "", "signed out: no identity")
        let s = InMemorySessionStore(); try s.save(Self.session("member-a"))
        let m = AccountModel(store: s) { _ in (200, Self.signedIn.replacingOccurrences(of: "example-member", with: "member-a")) }
        m.auth = auth; m.onUsernameChange = { [env] u in env.bind(username: u) }
        await m.restore()
        XCTAssertEqual(env.username, "member-a")
        // account switch A -> B through the real sign-in completion path
        let m2 = AccountModel(store: s) { _ in (200, Self.signedIn.replacingOccurrences(of: "example-member", with: "member-b")) }
        m2.auth = auth; m2.onUsernameChange = { [env] u in env.bind(username: u) }
        let c = HTTPCookie(properties: [.name: "letterboxd.user.CURRENT", .value: "v", .domain: "letterboxd.com", .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(3600)])!
        let ok = await m2.complete(with: [c])
        XCTAssertTrue(ok); XCTAssertEqual(env.username, "member-b"); XCTAssertEqual(auth.username, "member-b")
        await m2.signOut()
        XCTAssertEqual(env.username, "", "sign-out resets identity"); XCTAssertNil(auth.cookieHeader())
    }
}
