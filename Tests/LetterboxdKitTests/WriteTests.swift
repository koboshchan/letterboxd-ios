import XCTest
@testable import LetterboxdKit

actor Rec { var reqs: [WriteRequest] = []; func add(_ r: WriteRequest) { reqs.append(r) }; func all() -> [WriteRequest] { reqs } }
struct WT: HTTPTransport {
    let rec: Rec; let status: Int; let likeJSON: String
    func get(_ url: URL, accept: String) async throws -> HTTPResult {
        HTTPResult(data: Data(#"{"result":true,"csrf":"TOK+/=","lid":"2a9q","id":51568,"slug":"x"}"#.utf8), status: 200)
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
