import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LetterboxdKit

func fixture(_ n: String, _ e: String) throws -> Data {
    let u = Bundle.module.url(forResource: n, withExtension: e, subdirectory: "Fixtures") ?? Bundle.module.url(forResource: n, withExtension: e, subdirectory: "Fixtures/capture")!
    return try Data(contentsOf: u)
}
func fixtureText(_ n: String, _ e: String) throws -> String { String(decoding: try fixture(n, e), as: UTF8.self) }

struct StubTransport: HTTPTransport {
    let handler: @Sendable (URL) async throws -> HTTPResult
    func get(_ url: URL, accept: String) async throws -> HTTPResult { try await handler(url) }
}
actor Counter { var n = 0; func inc() { n += 1 }; func value() -> Int { n } }

final class KitTests: XCTestCase {
    func testGridParsesSkipsInvalidAndDuplicates() throws {
        let p = try Parsers.filmGrid(html: try fixtureText("grid", "html"), page: 1)
        XCTAssertEqual(p.items.map(\.slug), ["a-minecraft-movie", "your-name"])
        XCTAssertEqual(p.items[0].title, "A Minecraft Movie"); XCTAssertEqual(p.items[0].year, 2025)
        XCTAssertNil(p.items[0].posterURL); XCTAssertNotNil(p.items[1].posterURL)
        XCTAssertTrue(p.hasNext)
    }
    func testFilmDetailJSONLD() throws {
        let d = try Parsers.filmDetail(html: try fixtureText("film", "html"), slug: "parasite-2019")
        XCTAssertEqual(d.title, "Parasite"); XCTAssertEqual(d.year, 2019); XCTAssertEqual(d.runtimeMinutes, 133)
        XCTAssertEqual(d.directors.first?.name, "Bong Joon Ho")
        XCTAssertNil(d.cast.last?.url, "off-site person links are dropped")
        XCTAssertEqual(d.averageRating, 4.52); XCTAssertEqual(d.tagline, "Act like you own the place.")
    }
    func testFilmDetailMissingJSONLDThrows() {
        XCTAssertThrowsError(try Parsers.filmDetail(html: "<html></html>", slug: "x"))
    }
    func testRSSDiaryAndReviews() throws {
        let e = try RSSParser.parse(try fixture("rss", "xml"))
        XCTAssertEqual(e.count, 2, "off-site link item dropped")
        XCTAssertEqual(e[0].filmTitle, "Your Name."); XCTAssertEqual(e[0].rating, 4.5); XCTAssertTrue(e[0].rewatch)
        XCTAssertEqual(e[0].review, "Beautiful and sad."); XCTAssertNotNil(e[0].posterURL)
        XCTAssertNil(e[1].review); XCTAssertNotNil(e[1].watchedDate)
    }
    func testEmptyRSSIsGenuinelyEmpty() throws {
        XCTAssertEqual(try RSSParser.parse(try fixture("empty-channel", "xml")).count, 0)
    }
    func testProfile() throws {
        let p = try Parsers.profile(html: try fixtureText("profile", "html"), username: "koboshchan")
        XCTAssertEqual(p.displayName, "kobosh"); XCTAssertEqual(p.filmCount, 8)
        XCTAssertEqual(p.followingCount, 1); XCTAssertEqual(p.followersCount, 1); XCTAssertNotNil(p.avatarURL)
    }
    func testValidation() throws {
        XCTAssertEqual(try Validate.username(" KoboshChan "), "koboshchan")
        XCTAssertThrowsError(try Validate.username("a/../b")); XCTAssertThrowsError(try Validate.username("x"))
        XCTAssertThrowsError(try Validate.slug("../etc")); XCTAssertNoThrow(try Validate.slug("parasite-2019"))
        XCTAssertThrowsError(try Validate.url(URL(string: "http://letterboxd.com/")!))
        XCTAssertThrowsError(try Validate.url(URL(string: "https://letterboxd.com.evil.com/")!))
        XCTAssertThrowsError(try Validate.url(URL(string: "https://user@letterboxd.com/")!))
        XCTAssertNoThrow(try Validate.url(URL(string: "https://a.ltrbxd.com/x.jpg")!))
        XCTAssertNil(Validate.resolve("https://evil.example/x"))
        XCTAssertNotNil(Validate.resolve("/film/x/"))
    }
    func testBlockDetection() {
        for s in [403, 429, 503] { XCTAssertThrowsError(try BlockDetector.check(HTTPResult(data: Data(), status: s))) { XCTAssertEqual($0 as? LetterboxdError, .blocked(status: s)) } }
        XCTAssertThrowsError(try BlockDetector.check(HTTPResult(data: Data(), status: 404))) { XCTAssertEqual($0 as? LetterboxdError, .notFound) }
        XCTAssertThrowsError(try BlockDetector.check(HTTPResult(data: Data("<title>Just a moment...</title>".utf8), status: 200))) { XCTAssertEqual($0 as? LetterboxdError, .blocked(status: 200)) }
        XCTAssertNoThrow(try BlockDetector.check(HTTPResult(data: Data("ok".utf8), status: 200)))
    }
    func testCacheAvoidsRepeatRequestsAndRefreshBypasses() async throws {
        let c = Counter()
        let f = Fetcher(transport: StubTransport { _ in await c.inc(); return HTTPResult(data: Data("hi".utf8), status: 200) })
        let u = URL(string: "https://letterboxd.com/a/")!
        _ = try await f.text(u); _ = try await f.text(u)
        let n1 = await c.value(); XCTAssertEqual(n1, 1)
        _ = try await f.text(u, forceRefresh: true)
        let n2 = await c.value(); XCTAssertEqual(n2, 2)
    }
    func testCacheExpires() async {
        let box = Counter()
        let cache = ResponseCache(ttl: 10, now: { Date(timeIntervalSinceNow: 0) })
        let u = URL(string: "https://letterboxd.com/a/")!
        await cache.set(u, Data("x".utf8)); let hit = await cache.get(u); XCTAssertNotNil(hit)
        let expired = ResponseCache(ttl: -1); await expired.set(u, Data("x".utf8)); let miss = await expired.get(u); XCTAssertNil(miss)
        _ = box
    }
    func testBlockedIsNotCached() async {
        let c = Counter()
        let f = Fetcher(transport: StubTransport { _ in await c.inc(); return HTTPResult(data: Data(), status: 403) })
        let u = URL(string: "https://letterboxd.com/a/")!
        for _ in 0..<2 { do { _ = try await f.text(u); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .blocked(status: 403)) } }
        let n = await c.value(); XCTAssertEqual(n, 2)
    }
    func testRejectsNonLetterboxdHostBeforeNetwork() async {
        let c = Counter()
        let f = Fetcher(transport: StubTransport { _ in await c.inc(); return HTTPResult(data: Data(), status: 200) })
        do { _ = try await f.text(URL(string: "https://evil.example/")!); XCTFail() } catch {}
        let n = await c.value(); XCTAssertEqual(n, 0)
    }
    func testCancellation() async {
        let f = Fetcher(transport: StubTransport { _ in try await Task.sleep(nanoseconds: 5_000_000_000); return HTTPResult(data: Data(), status: 200) })
        let t = Task { try await f.text(URL(string: "https://letterboxd.com/a/")!) }
        t.cancel()
        do { _ = try await t.value; XCTFail() } catch { /* cancelled */ }
    }
    func testServicePaginationURLAndFilmsPath() async throws {
        let seen = SeenURLs()
        let svc = PublicWebService(fetcher: Fetcher(transport: StubTransport { u in await seen.add(u); return HTTPResult(data: try fixture("grid", "html"), status: 200) }))
        let p2 = try await svc.films(username: "koboshchan", page: 2, refresh: false)
        XCTAssertEqual(p2.page, 2); XCTAssertTrue(p2.hasNext)
        let urls = await seen.all
        XCTAssertEqual(urls.first?.absoluteString, "https://letterboxd.com/koboshchan/films/page/2/")
    }
    func testServiceSearchRejectsBadQuery() async {
        let svc = PublicWebService(fetcher: Fetcher(transport: StubTransport { _ in HTTPResult(data: Data(), status: 200) }))
        do { _ = try await svc.searchFilms(query: "a/b", page: 1); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .invalidInput("query")) }
    }
    func testDiaryFiltersToWatchedEntries() async throws {
        let svc = PublicWebService(fetcher: Fetcher(transport: StubTransport { _ in HTTPResult(data: try fixture("rss", "xml"), status: 200) }))
        let d = try await svc.diary(username: "example-member", refresh: false); XCTAssertEqual(d.count, 2)
        let r = try await svc.reviews(username: "example-member", refresh: false); XCTAssertEqual(r.count, 1)
    }
}
final class RecordedTests: XCTestCase {
    func rec(_ n: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: n, withExtension: "json", subdirectory: "Fixtures/recorded")!) }
    func html(_ n: String) throws -> String { String(decoding: try Data(contentsOf: Bundle.module.url(forResource: "real-" + n, withExtension: "html", subdirectory: "Fixtures/recorded")!), as: UTF8.self) }
    func testRealProfile() throws { let p = try Parsers.profile(html: try html("profile"), username: "example-member"); XCTAssertFalse(p.displayName.isEmpty) }
    func testRealListsAndSearchParse() throws {
        _ = try Parsers.lists(html: try html("lists"), page: 1)
        _ = try Parsers.filmGrid(html: try html("search"), page: 1)
    }
    func testFilmJSON() throws {
        let f = try FilmJSON.decode(try rec("film-detail"))
        XCTAssertEqual(f.slug, "fight-club"); XCTAssertEqual(f.releaseYear, 1999); XCTAssertEqual(f.directors.first?.name, "David Fincher")
    }
    func testPosterJSON() throws {
        let p = try PosterJSON.decode(try rec("film-poster-230")); XCTAssertEqual(p.url.host, "a.ltrbxd.com"); XCTAssertFalse(p.shouldObfuscate)
    }
    func testPosterRejectsForeignHost() {
        let d = Data(#"{"url":"https://evil.example/x.jpg","url2x":"https://evil.example/y.jpg","shouldObfuscate":false}"#.utf8)
        XCTAssertThrowsError(try PosterJSON.decode(d))
    }
    func testLoginResponse() throws { XCTAssertTrue(try LoginResponse.decode(try rec("login-success")).succeeded) }
    func testRecordedFilesHaveNoSecrets() throws {
        for n in ["film-detail", "login-success"] {
            let s = String(decoding: try rec(n), as: UTF8.self)
            if s.contains("csrf") { XCTAssertTrue(s.contains("REDACTED")) }
        }
    }
}
final class AuthTests: XCTestCase {
    func testStoreRoundTripAndClear() throws {
        let s = InMemorySessionStore(); XCTAssertNil(try s.load())
        try s.save(Session(username: "u", cookies: [WebCookie(name: "a", value: "b", domain: "letterboxd.com")])); XCTAssertEqual(try s.load()?.username, "u")
        try s.clear(); XCTAssertNil(try s.load())
    }
    func testUnavailableServiceIsHonest() async {
        do { _ = try await UnavailableAccountService().createList(name: "x", isPrivate: true); XCTFail() } catch { if case AuthError.unsupported = error {} else { XCTFail() } }
    }
}
final class SignInTests: XCTestCase {
    func html(_ n: String) throws -> String { String(decoding: try Data(contentsOf: Bundle.module.url(forResource: "real-" + n, withExtension: "html", subdirectory: "Fixtures/recorded")!), as: UTF8.self) }
    let good: [(name: String, value: String, domain: String)] = [("letterboxd.user.CURRENT", "c", "letterboxd.com"), ("com.xk72.webparts.csrf", "t", ".letterboxd.com"), ("evil", "x", "evil.example"), ("sneaky", "y", "letterboxd.com.evil.example")]
    func testNativeSignInReportsChallengeBlockerWithoutNetwork() async {
        do { _ = try await LiveAccountService(store: InMemorySessionStore()).signIn(email: "u", password: "p"); XCTFail() } catch { XCTAssertEqual(error as? AuthError, .verificationRequired) }
    }
    func wc(_ n: String, _ d: String = "letterboxd.com", path: String = "/", exp: Date? = nil, secure: Bool = true) -> WebCookie { WebCookie(name: n, value: "v", domain: d, path: path, expires: exp, secure: secure) }
    var signedIn: String { String(decoding: try! Data(contentsOf: Bundle.module.url(forResource: "authenticated-identity.sanitized", withExtension: "html", subdirectory: "Fixtures/recorded")!), as: UTF8.self) }
    let guest = "<script>person = {\n username: \"\"\n , loggedIn: false\n , role: \"guest\" }</script>"
    func fetcher(_ status: Int, _ html: String) -> HomepageFetcher { { _ in (status, html) } }
    func testCookieFiltering() {
        let jar = SessionCookies.accept([wc("letterboxd.user.CURRENT"), wc("a", ".letterboxd.com"), wc("b", "evil.example"), wc("c", "letterboxd.com.evil.example"), wc("d", "x.letterboxd.com"), wc("e", path: "/x"), wc("f", secure: false), wc("g", exp: Date(timeIntervalSince1970: 1))])
        XCTAssertEqual(Set(jar!.map(\.name)), ["letterboxd.user.CURRENT", "a"])
    }
    func testIdentityParsesExplicitAssignmentsOnly() {
        XCTAssertEqual(IdentityCheck.username(fromHomepage: signedIn), "example-member")
        let guestThenAuth = guest + "<script>person.username = \"abc\"; person.loggedIn = true</script>"
        XCTAssertEqual(IdentityCheck.username(fromHomepage: guestThenAuth), "abc")
        XCTAssertNil(IdentityCheck.username(fromHomepage: guest))
        XCTAssertNil(IdentityCheck.username(fromHomepage: "<script>person.username = \"a\"; person.username = \"b\"; person.loggedIn = true</script>"))
        XCTAssertNil(IdentityCheck.username(fromHomepage: "<script>person.username = \"a\"; person.loggedIn = true; person.loggedIn = false</script>"))
        XCTAssertNil(IdentityCheck.username(fromHomepage: "<script>person.username = \"a b\"; person.loggedIn = true</script>"))
        XCTAssertNil(IdentityCheck.username(fromHomepage: "<script>x = { username: \"a\", loggedIn: true }</script>"))
        XCTAssertNil(IdentityCheck.username(fromHomepage: "<script>person.username = \"\"; person.loggedIn = true</script>"))
    }
    func testCookieScopingHostOnlyAndAmbiguity() {
        let n = "letterboxd.user.CURRENT"
        XCTAssertNil(SessionCookies.accept([WebCookie(name: n, value: "v", domain: "www.letterboxd.com")]))
        XCTAssertNil(SessionCookies.accept([WebCookie(name: n, value: "v", domain: ".www.letterboxd.com")]))
        XCTAssertNil(SessionCookies.accept([WebCookie(name: n, value: "a", domain: "letterboxd.com"), WebCookie(name: n, value: "b", domain: ".letterboxd.com")]))
        XCTAssertEqual(SessionCookies.accept([WebCookie(name: n, value: "a", domain: "letterboxd.com"), WebCookie(name: n, value: "a", domain: ".letterboxd.com")])?.count, 1)
        XCTAssertNil(SessionCookies.accept([WebCookie(name: n, value: "a", domain: "letterboxd.com", path: "/x")]))
    }
    func testSessionCookieLifetimeBounded() {
        let n = "letterboxd.user.CURRENT", c = WebCookie(name: n, value: "v", domain: "letterboxd.com")
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNotNil(SessionCookies.accept([c], now: t0.addingTimeInterval(86400), storedAt: t0))
        XCTAssertNil(SessionCookies.accept([c], now: t0.addingTimeInterval(31 * 86400), storedAt: t0))
        XCTAssertFalse(Session(username: "u", cookies: [c], storedAt: t0).header(now: t0.addingTimeInterval(86400)).isEmpty)
        XCTAssertTrue(Session(username: "u", cookies: [c], storedAt: t0).header(now: t0.addingTimeInterval(31 * 86400)).isEmpty)
    }
    func testEmptySessionValueAndDuplicatesCollapse() {
        XCTAssertNil(SessionCookies.accept([WebCookie(name: "letterboxd.user.CURRENT", value: "", domain: "letterboxd.com")]))
        let jar = SessionCookies.accept([WebCookie(name: "letterboxd.user.CURRENT", value: "apex", domain: ".letterboxd.com"), WebCookie(name: "letterboxd.user.CURRENT", value: "apex", domain: ".letterboxd.com"), wc("z")])!
        XCTAssertEqual(jar.count, 2)
    }
    func testSessionRoundTripKeepsAttributes() throws {
        let c = WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: ".letterboxd.com", path: "/", expires: Date(timeIntervalSince1970: 4_000_000_000), secure: true)
        let s = Session(username: "u", cookies: [c]); XCTAssertEqual(try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(s)), s)
    }
    func testRestoreRevalidatesAndClears() async throws {
        let far = Date().addingTimeInterval(86400)
        let ok = Session(username: "example-member", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com", expires: far)])
        var s: InMemorySessionStore! = InMemorySessionStore(); try s.save(ok)
        let r = try await LiveAccountService(store: s).restore(fetch: fetcher(200, signedIn)); XCTAssertEqual(r?.username, "example-member")
        for (st, h) in [(200, guest), (200, signedIn.replacingOccurrences(of: "example-member", with: "other")), (302, signedIn)] {
            s = InMemorySessionStore(); try s.save(ok)
            let r = try await LiveAccountService(store: s).restore(fetch: fetcher(st, h)); XCTAssertNil(r); XCTAssertNil(try s.load())
        }
        s = InMemorySessionStore(); try s.save(Session(username: "example-member", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com", expires: Date(timeIntervalSince1970: 1))]))
        let rr = try await LiveAccountService(store: s).restore(fetch: fetcher(200, signedIn)); XCTAssertNil(rr); XCTAssertNil(try s.load())
        s = InMemorySessionStore(); try s.save(ok)
        do { _ = try await LiveAccountService(store: s).restore(fetch: { _ in throw LetterboxdError.network("x") }); XCTFail() } catch {}
        XCTAssertNotNil(try s.load())
    }
    func testExpiredOrInsecureSessionCookieRejected() {
        XCTAssertNil(SessionCookies.accept([wc("letterboxd.user.CURRENT", exp: Date(timeIntervalSince1970: 1))]))
        XCTAssertNil(SessionCookies.accept([wc("letterboxd.user.CURRENT", secure: false)]))
        XCTAssertNil(SessionCookies.accept([wc("letterboxd.user.CURRENT", "x.letterboxd.com")]))
    }
    func testServerConfirmedIdentityStoresServerUsername() async throws {
        let s = InMemorySessionStore()
        let sess = try await LiveAccountService(store: s).complete(cookies: [wc("letterboxd.user.CURRENT")], fetch: fetcher(200, signedIn))
        XCTAssertEqual(sess.username, "example-member"); XCTAssertEqual(try s.load(), sess)
    }
    func testCookiePresenceAloneIsNotSignedIn() async {
        for (st, h) in [(200, guest), (302, signedIn), (200, "<html>sign in</html>"), (403, "")] {
            let s = InMemorySessionStore()
            do { _ = try await LiveAccountService(store: s).complete(cookies: [wc("letterboxd.user.CURRENT")], fetch: fetcher(st, h)); XCTFail("\(st)") } catch { XCTAssertEqual(error as? AuthError, .notSignedIn) }
            XCTAssertNil(try? s.load())
        }
    }
    func testFetchErrorStoresNothing() async {
        let s = InMemorySessionStore()
        do { _ = try await LiveAccountService(store: s).complete(cookies: [wc("letterboxd.user.CURRENT")], fetch: { _ in throw LetterboxdError.network("x") }); XCTFail() } catch {}
        XCTAssertNil(try? s.load())
    }
    func testNavigationPolicy() {
        let ok = ["https://letterboxd.com/", "https://www.letterboxd.com/sign-in/"]
        let bad = ["http://letterboxd.com/", "https://evil.letterboxd.com/", "https://letterboxd.com.evil.example/", "https://x@letterboxd.com/", "https://letterboxd.com:8443/", "javascript:alert(1)", "file:///etc/passwd", "https://challenges.cloudflare.com/"]
        for u in ok { XCTAssertTrue(NavigationPolicy.allows(URL(string: u), mainFrame: true), u) }
        for u in bad { XCTAssertFalse(NavigationPolicy.allows(URL(string: u), mainFrame: true), u) }
        XCTAssertTrue(NavigationPolicy.allows(URL(string: "https://challenges.cloudflare.com/x"), mainFrame: false))
        XCTAssertFalse(NavigationPolicy.allows(URL(string: "http://challenges.cloudflare.com/x"), mainFrame: false))
        XCTAssertFalse(NavigationPolicy.allows(nil, mainFrame: true))
    }
    func testRealPopularGridParsesFilms() throws {
        let p = try Parsers.filmGrid(html: try html("popular-grid"), page: 1)
        XCTAssertGreaterThan(p.items.count, 40); XCTAssertTrue(p.items.allSatisfy { !$0.slug.isEmpty && !$0.title.isEmpty })
    }
    func testSignOutClears() async throws {
        let s = InMemorySessionStore(); try s.save(Session(username: "u", cookies: []))
        try await LiveAccountService(store: s).signOut(); XCTAssertNil(try s.load())
    }
    func testLoginTemplateRecordsCaptchaRequirement() throws {
        let u = Bundle.module.url(forResource: "login-request-template.sanitized", withExtension: "json", subdirectory: "Fixtures/recorded")!
        XCTAssertTrue(String(decoding: try Data(contentsOf: u), as: UTF8.self).contains("captchaResponse"))
    }
    func testInitial403CaptureRegression() throws {
        let u = Bundle.module.url(forResource: "endpoint-report", withExtension: "json", subdirectory: "Fixtures/initial-403")!
        let j = try JSONSerialization.jsonObject(with: Data(contentsOf: u)) as! [String: Any]
        XCTAssertEqual(j["result"] as? String, "blocked_security_verification")
        XCTAssertThrowsError(try BlockDetector.check(HTTPResult(data: Data("<title>Just a moment...</title>".utf8), status: 403)))
    }
}
actor SeenURLs { var all: [URL] = []; func add(_ u: URL) { all.append(u) } }

final class AuthTransportTests: XCTestCase {
    func testAuthGenerationIsolatesCacheAndDropsInflight() async throws {
        let auth = AuthAuthority(); let u = URL(string: "https://letterboxd.com/a/")!
        let seenCookies = SeenBox()
        let tr = StubTransport { _ in await seenCookies.add(auth.cookieHeader() ?? "none"); return HTTPResult(data: Data((auth.username ?? "guest").utf8), status: 200) }
        let f = Fetcher(transport: tr, auth: auth)
        let c = WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com", expires: Date().addingTimeInterval(9999))
        let r0 = try await f.text(u); XCTAssertEqual(r0, "guest")
        auth.setValidated(Session(username: "A", cookies: [c]))
        let r1 = try await f.text(u); XCTAssertEqual(r1, "A")            // not the cached guest page
        auth.setValidated(Session(username: "B", cookies: [c]))
        let r2 = try await f.text(u); XCTAssertEqual(r2, "B")            // not A's page
        auth.revoke()
        let r3 = try await f.text(u); XCTAssertEqual(r3, "guest")        // logout: no private data, no cookie
        let seen = await seenCookies.all
        XCTAssertEqual(seen.last, "none"); XCTAssertNil(auth.cookieHeader())
    }
    func testResponseStartedBeforeLogoutIsDiscardedAndNotCached() async throws {
        let auth = AuthAuthority(); let u = URL(string: "https://letterboxd.com/p/")!
        let c = WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com", expires: Date().addingTimeInterval(9999))
        auth.setValidated(Session(username: "A", cookies: [c]))
        let f = Fetcher(transport: StubTransport { _ in auth.revoke(); return HTTPResult(data: Data("private-A".utf8), status: 200) }, auth: auth)
        do { _ = try await f.text(u); XCTFail("should be discarded") } catch LetterboxdError.cancelled {} 
        let cached = await f.cache.get(u, partition: auth.generation); XCTAssertNil(cached)
        let cachedOld = await f.cache.get(u, partition: auth.generation - 1); XCTAssertNil(cachedOld)
    }
    func testRevokeWithoutSessionDoesNotBumpGeneration() {
        let a = AuthAuthority(); let g = a.generation; a.revoke(); XCTAssertEqual(a.generation, g)
    }
    func testNoCookieWithoutValidation() {
        let auth = AuthAuthority()
        XCTAssertNil(auth.cookieHeader())   // fresh/offline-unvalidated: nothing is sent
        let c = WebCookie(name: "a", value: "b", domain: "letterboxd.com", expires: Date(timeIntervalSince1970: 1))
        auth.setValidated(Session(username: "u", cookies: [c])); XCTAssertNil(auth.cookieHeader())   // expired cookies excluded
    }
    func testRedirectPolicyCases() {
        let ok = URL(string: "https://letterboxd.com/a/")!
        XCTAssertTrue(RedirectPolicy.mayCarryCredentials(ok))
        for s in ["https://www.letterboxd.com/", "http://letterboxd.com/", "https://letterboxd.com:8443/", "https://evil.com/", "https://letterboxd.com.evil.com/", "https://u:p@letterboxd.com/", "https://sub.letterboxd.com/"] {
            XCTAssertFalse(RedirectPolicy.mayCarryCredentials(URL(string: s)!), s)
        }
        for s in [ok.absoluteString, "https://www.letterboxd.com/x", "https://letterboxd.com:443/x"] {
            XCTAssertFalse(RedirectPolicy.allows(to: URL(string: s)!, authenticated: true), s)
            XCTAssertTrue(RedirectPolicy.allows(to: URL(string: s)!, authenticated: false), s)
        }
        for s in ["http://letterboxd.com/", "https://letterboxd.com:8443/", "https://evil.com/", "https://letterboxd.com.evil.com/", "https://u:p@letterboxd.com/"] {
            XCTAssertFalse(RedirectPolicy.allows(to: URL(string: s)!, authenticated: false), s)
        }
    }
    /// Real URLSession with a local URLProtocol that answers with a redirect; checks cookie never reaches the target.
    func testRedirectGuardDelegateDirect() async {
        let task = URLSession.shared.dataTask(with: URL(string: "https://letterboxd.com/start/")!)
        for code in [301, 302, 303, 307, 308] {
            let resp = HTTPURLResponse(url: URL(string: "https://letterboxd.com/start/")!, statusCode: code, httpVersion: nil, headerFields: nil)!
            var n = URLRequest(url: URL(string: "https://letterboxd.com/other/")!); n.setValue("letterboxd.user.CURRENT=s", forHTTPHeaderField: "Cookie"); n.setValue("Bearer x", forHTTPHeaderField: "Authorization")
            let auth = await RedirectGuard(authenticated: true).urlSession(.shared, task: task, willPerformHTTPRedirection: resp, newRequest: n)
            XCTAssertNil(auth, "authenticated \(code) must be refused even same-site")
            let anon = await RedirectGuard(authenticated: false).urlSession(.shared, task: task, willPerformHTTPRedirection: resp, newRequest: n)
            XCTAssertNotNil(anon); XCTAssertNil(anon?.value(forHTTPHeaderField: "Cookie")); XCTAssertNil(anon?.value(forHTTPHeaderField: "Authorization"))
            for bad in ["https://evil.com/", "http://letterboxd.com/", "https://letterboxd.com:8443/", "https://letterboxd.com.evil.com/"] {
                let x = await RedirectGuard(authenticated: false).urlSession(.shared, task: task, willPerformHTTPRedirection: resp, newRequest: URLRequest(url: URL(string: bad)!))
                XCTAssertNil(x, bad)
            }
        }
    }
    #if !canImport(FoundationNetworking)
    func testAuthenticatedRequestNeverFollowsRedirects() async throws {
        for code in [301, 302, 307, 308] {
            RedirectStub.seen = []; RedirectStub.code = code
            let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [RedirectStub.self]
            let t = URLSessionTransport(configuration: c, cookieHeader: { "letterboxd.user.CURRENT=secret" })
            let r = try await t.get(URL(string: "https://letterboxd.com/start/")!, accept: "text/html")
            XCTAssertEqual(r.status, code)
            XCTAssertEqual(RedirectStub.seen.map { $0.url!.absoluteString }, ["https://letterboxd.com/start/"])
            XCTAssertEqual(RedirectStub.seen.first?.value(forHTTPHeaderField: "Cookie"), "letterboxd.user.CURRENT=secret")
        }
        // Unauthenticated redirect to another host is refused too; same-site exact host is followed without cookies.
        RedirectStub.seen = []; RedirectStub.code = 302; RedirectStub.target = "https://evil.com/x"
        let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [RedirectStub.self]
        let r = try await URLSessionTransport(configuration: c).get(URL(string: "https://letterboxd.com/start/")!, accept: "text/html")
        XCTAssertEqual(r.status, 302); XCTAssertEqual(RedirectStub.seen.count, 1)
        RedirectStub.target = "https://letterboxd.com/other/"
    }
    #endif
}

actor SeenBox { var all: [String] = []; func add(_ s: String) { all.append(s) } }

final class RedirectStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [URLRequest] = []
    nonisolated(unsafe) static var code = 302
    nonisolated(unsafe) static var target = "https://evil.com/steal"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.seen.append(request)
        if request.url!.host == "letterboxd.com", request.url!.path == "/start/" {
            let resp = HTTPURLResponse(url: request.url!, statusCode: Self.code, httpVersion: nil, headerFields: ["Location": Self.target])!
            var n = URLRequest(url: URL(string: Self.target)!); n.httpMethod = "GET"
            for (k, v) in request.allHTTPHeaderFields ?? [:] { n.setValue(v, forHTTPHeaderField: k) }
            client?.urlProtocol(self, wasRedirectedTo: n, redirectResponse: resp)
        } else {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data()); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
