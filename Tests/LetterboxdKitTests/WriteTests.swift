import XCTest
@testable import LetterboxdKit

actor Rec { var reqs: [WriteRequest] = []; var onList = false; var liked = false; var ignorePatch = false
    func add(_ r: WriteRequest) { reqs.append(r); if r.method == "POST" { liked = String(decoding: r.body, as: UTF8.self).contains("liked=true") }; if r.method == "PATCH", !ignorePatch { onList = String(decoding: r.body, as: UTF8.self).contains("true") } }
    func all() -> [WriteRequest] { reqs }; func setIgnore() { ignorePatch = true } }
struct WT: HTTPTransport {
    let rec: Rec; let status: Int; let likeJSON: String
    func get(_ url: URL, accept: String) async throws -> HTTPResult {
        if url.path == "/s/check-viewingable-relation" {
            XCTAssertEqual(url.query, "viewingableUID=film:51568")
            let on = await rec.onList, lk = await rec.liked
            return HTTPResult(data: Data(#"{"result":true,"csrf":"n","liked":\#(lk),"rating":0,"isInWatchlist":\#(on),"isDerivedRating":false}"#.utf8), status: 200) }
        return HTTPResult(data: Data(#"{"result":true,"csrf":"TOK+/=","lid":"2a9q","id":51568,"slug":"x"}"#.utf8), status: 200)
    }
    func send(_ r: WriteRequest) async throws -> HTTPResult { await rec.add(r); return HTTPResult(data: Data((r.method == "PATCH" ? "{}" : likeJSON).utf8), status: status) }
}
final class WriteTests: XCTestCase {
    func auth() -> AuthAuthority {
        let a = AuthAuthority()
        a.setValidated(Session(username: "tester", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")]))
        return a
    }
    func actions(_ a: AuthAuthority, status: Int = 200, like: String = #"{"result":true,"csrf":"n","count":3,"liked":true}"#) -> (FilmActions, Rec) {
        let r = Rec(); return (FilmActions(transport: WT(rec: r, status: status, likeJSON: like), auth: a), r)
    }
    func testWatchlistWireFormat() async throws {
        let (f, rec) = actions(auth()); let h = try await f.handle(slug: "fight-club")
        XCTAssertEqual(h.lid, "2a9q"); XCTAssertEqual(h.id, 51568)
        try await f.setWatchlist(h, on: true)
        let q = await rec.all()[0]
        XCTAssertEqual(q.method, "PATCH"); XCTAssertEqual(q.url.absoluteString, "https://letterboxd.com/api/v0/me/watchlist/2a9q")
        XCTAssertEqual(q.headers["x-csrf-token"], "TOK+/="); XCTAssertTrue(q.contentType.hasPrefix("application/json"))
        XCTAssertEqual(String(decoding: q.body, as: UTF8.self), #"{"inWatchlist":true}"#)
        try await f.setWatchlist(h, on: false)   // readback confirms removal too
    }
    func testWatchlistReadbackMismatchFails() async throws {
        let (f, rec) = actions(auth()); await rec.setIgnore()
        let h = FilmHandle(slug: "fight-club", lid: "2a9q", id: 51568, csrf: "c")
        do { try await f.setWatchlist(h, on: true); XCTFail("200 {} without server state must not count") } catch { XCTAssertTrue("\(error)".contains("readback")) }
    }
    func testClientProtocolReturnsServerState() async throws {
        let (f, _) = actions(auth()); let c: FilmActionsClient = f
        let r938 = try await c.state(slug: "fight-club"); XCTAssertEqual(r938, FilmState(watchlist: false, liked: false))
        let r874 = try await c.setWatchlist(slug: "fight-club", on: true); XCTAssertEqual(r874, FilmState(watchlist: true, liked: false))
        let r103 = try await c.setLike(slug: "fight-club", liked: true); XCTAssertEqual(r103, FilmState(watchlist: true, liked: true))
        let r240 = try await c.setWatchlist(slug: "fight-club", on: false); XCTAssertEqual(r240, FilmState(watchlist: false, liked: true))
    }
    func testRelationRejectsMalformed() async throws {
        struct Bad: HTTPTransport { func get(_ u: URL, accept: String) async throws -> HTTPResult { HTTPResult(data: Data(#"{"result":true}"#.utf8), status: 200) } }
        let f = FilmActions(transport: Bad(), auth: auth())
        do { _ = try await f.relation(FilmHandle(slug: "a", lid: "x", id: 1, csrf: "c")); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .parse("relation")) }
    }
    func testLikeWireFormatEncodesCSRF() async throws {
        let (f, rec) = actions(auth()); let h = try await f.handle(slug: "fight-club")
        let r = try await f.setLike(h, liked: true)
        XCTAssertEqual(r, LikeResult(liked: true, count: 3))
        let q = await rec.all()[0]
        XCTAssertEqual(q.method, "POST"); XCTAssertEqual(q.url.absoluteString, "https://letterboxd.com/s/film:51568/like/")
        XCTAssertEqual(String(decoding: q.body, as: UTF8.self), "liked=true&__csrf=TOK%2B/%3D")
    }
    func testSignedOutSendsNothing() async throws {
        let (f, rec) = actions(AuthAuthority())
        do { _ = try await f.handle(slug: "fight-club"); XCTFail() } catch { XCTAssertEqual(error as? AuthError, .notSignedIn) }
        let h = FilmHandle(slug: "a", lid: "x", id: 1, csrf: "c")
        do { try await f.setWatchlist(h, on: true); XCTFail() } catch { XCTAssertEqual(error as? AuthError, .notSignedIn) }
        let n = await rec.all().count; XCTAssertEqual(n, 0)
    }
    func testErrorsMismatchAndInvalidSlug() async throws {
        let h = FilmHandle(slug: "a", lid: "x", id: 1, csrf: "c")
        let (f403, _) = actions(auth(), status: 403)
        do { try await f403.setWatchlist(h, on: true); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .blocked(status: 403)) }
        let (f500, _) = actions(auth(), status: 500)
        do { try await f500.setWatchlist(h, on: false); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .http(status: 500)) }
        let (fm, _) = actions(auth(), like: #"{"result":true,"liked":false}"#)
        do { _ = try await fm.setLike(h, liked: true); XCTFail("server state mismatch must fail") } catch {}
        do { _ = try await fm.handle(slug: "../x"); XCTFail() } catch {}
    }
    func testAuthChangeDuringWriteDiscards() async throws {
        let a = auth()
        struct Rev: HTTPTransport { let a: AuthAuthority
            func get(_ url: URL, accept: String) async throws -> HTTPResult { HTTPResult(data: Data(), status: 200) }
            func send(_ r: WriteRequest) async throws -> HTTPResult { a.revoke(); return HTTPResult(data: Data("{}".utf8), status: 200) } }
        let f = FilmActions(transport: Rev(a: a), auth: a)
        do { try await f.setWatchlist(FilmHandle(slug: "a", lid: "x", id: 1, csrf: "c"), on: true); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
    }
    func testCancellationBeforeSend() async throws {
        let (f, rec) = actions(auth())
        let t = Task { try await Task.sleep(nanoseconds: 200_000_000); try await f.setWatchlist(FilmHandle(slug: "a", lid: "x", id: 1, csrf: "c"), on: true) }
        t.cancel(); _ = await t.result
        let n = await rec.all().count; XCTAssertEqual(n, 0)
    }
}

final class FullTextTests: XCTestCase {
    func testFullTextFragment() throws {
        let t = try Parsers.fullText(html: try fixtureText("real-full-text-shape", "html"))
        XCTAssertEqual(t.components(separatedBy: "\n\n").count, 5)
        XCTAssertTrue(t.contains("\"synthetic quotation\"")); XCTAssertTrue(t.contains("apostrophe's"))
        XCTAssertThrowsError(try Parsers.fullText(html: "<div></div>"))
    }
    func testFullTextPathValidation() async {
        let s = PublicWebService(fetcher: Fetcher(transport: StubTransport { _ in HTTPResult(data: Data("<p>x</p>".utf8), status: 200) }))
        for bad in ["/other/1/", "/s/full-text/../x", "/s/full-text/a?b=1"] { do { _ = try await s.fullReviewText(path: bad); XCTFail(bad) } catch {} }
        let ok = try? await s.fullReviewText(path: "/s/full-text/viewing:1/"); XCTAssertEqual(ok, "x")
    }
}

final class FullTextPathTests: XCTestCase {
    func testAcceptsOnlyCapturedShape() throws {
        XCTAssertEqual(try Validate.fullTextPath("/s/full-text/viewing:123456/"), "/s/full-text/viewing:123456/")
        for bad in ["/s/full-text/", "/s/full-text/viewing:1", "/s/full-text/viewing:1/?a=b", "/s/full-text/viewing:1/#x", "/s/full-text/viewing:1/../x/",
                    "/s/full-text/viewing:%31/", "/s/full-text/viewing:1%2F", "/s/full-text/viewing:1%252e%252e/", "/s/full-text/viewing:1/a/",
                    "//evil.com/s/full-text/viewing:1/", "/s/full-text/viewing:a/", "https://u:p@letterboxd.com/s/full-text/viewing:1/", "/s/full-text/viewing:1/\n", "/s/full-text/film:1/"] {
            XCTAssertThrowsError(try Validate.fullTextPath(bad), bad)
        }
    }
}

final class CapabilityTests: XCTestCase {
    func testOnlyCapturedWritesSupported() {
        let ok = Set(WriteFeature.allCases.filter { $0.status == .supported })
        XCTAssertEqual(ok, [.watchlist, .like])
        for f in WriteFeature.allCases where !ok.contains(f) { if case .unverified(let r) = f.status { XCTAssertFalse(r.isEmpty) } else { XCTFail() } }
    }
    func testRelationRequestIsSafeAndSameHost() async throws {
        actor R { var urls: [URL] = []; func add(_ u: URL) { urls.append(u) } }
        struct T: HTTPTransport { let r: R
            func get(_ u: URL, accept: String) async throws -> HTTPResult { await r.add(u); return HTTPResult(data: Data(#"{"result":true,"liked":false,"isInWatchlist":true}"#.utf8), status: 200) } }
        let r = R(); let f = FilmActions(transport: T(r: r), auth: { let a = AuthAuthority(); a.setValidated(Session(username: "tester", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")])); return a }())
        _ = try await f.relation(FilmHandle(slug: "a", lid: "x", id: 42, csrf: "c"))
        let u = await r.urls[0]
        XCTAssertEqual(u.absoluteString, "https://letterboxd.com/s/check-viewingable-relation?viewingableUID=film:42")
    }
}
