import XCTest
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
        let d = try await svc.diary(username: "kobosh", refresh: false); XCTAssertEqual(d.count, 2)
        let r = try await svc.reviews(username: "kobosh", refresh: false); XCTAssertEqual(r.count, 1)
    }
}
final class RecordedTests: XCTestCase {
    func rec(_ n: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: n, withExtension: "json", subdirectory: "Fixtures/recorded")!) }
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
        try s.save(Session(username: "u", cookies: ["a": "b"])); XCTAssertEqual(try s.load()?.username, "u")
        try s.clear(); XCTAssertNil(try s.load())
    }
    func testUnavailableServiceIsHonest() async {
        do { _ = try await UnavailableAccountService().createList(name: "x", isPrivate: true); XCTFail() } catch { if case AuthError.unsupported = error {} else { XCTFail() } }
    }
}
actor SeenURLs { var all: [URL] = []; func add(_ u: URL) { all.append(u) } }
