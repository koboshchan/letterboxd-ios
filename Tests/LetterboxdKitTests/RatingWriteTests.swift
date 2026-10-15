import XCTest
@testable import LetterboxdKit

actor RState { var rating: Int? = nil; var watched = false; var reqs: [WriteRequest] = []; var dropRating = false
    func apply(_ r: WriteRequest) -> HTTPResult {
        reqs.append(r); let b = String(decoding: r.body, as: UTF8.self)
        if r.method == "PATCH" {
            if dropRating { return HTTPResult(data: Data(), status: 204) }
            if b.contains("null") { rating = nil } else { rating = Int((Double(b.filter { "0123456789.".contains($0) })! * 2).rounded()); watched = true }
            return HTTPResult(data: Data(), status: 204)
        }
        if r.url.path.hasSuffix("/watch") { watched = b.contains("watched=true"); return HTTPResult(data: Data("{\"result\":true,\"watched\":\(watched)}".utf8), status: 200) }
        let w = watched ? "\"watched\":[\"film:7\"]," : ""
        let rt = rating.map { n in "\"ratings\":[{\"uid\":\"film:7\",\"rating\":\(n)}]," } ?? ""
        return HTTPResult(data: Data("{\"result\":true,\(w)\(rt)\"csrf\":\"n\"}".utf8), status: 200)
    }
    func setDrop() { dropRating = true }
    func all() -> [WriteRequest] { reqs } }
struct RT: HTTPTransport {
    let st: RState
    func get(_ url: URL, accept: String) async throws -> HTTPResult { HTTPResult(data: Data(#"{"result":true,"csrf":"T+K","lid":"Ab1","id":7,"slug":"x"}"#.utf8), status: 200) }
    func send(_ r: WriteRequest) async throws -> HTTPResult { await st.apply(r) }
}
final class RatingWriteTests: XCTestCase {
    func make() -> (FilmActions, RState, AuthAuthority) {
        let a = AuthAuthority(); a.setValidated(Session(username: "tester", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")]))
        let s = RState(); return (FilmActions(transport: RT(st: s), auth: a), s, a)
    }
    func testRatingWireFormatAndSideEffect() async throws {
        let (f, s, _) = make()
        let r = try await f.setRating(slug: "x", rating: 0.5)
        XCTAssertEqual(r, RatingState(rating: 0.5, watched: true))   // rating marks watched
        let q = await s.all()[0]
        XCTAssertEqual(q.method, "PATCH"); XCTAssertEqual(q.url.absoluteString, "https://letterboxd.com/api/v0/me/rate/Ab1")
        XCTAssertEqual(q.headers["x-csrf-token"], "T+K"); XCTAssertEqual(String(decoding: q.body, as: UTF8.self), #"{"rating":0.5}"#)
        let c = try await f.setRating(slug: "x", rating: nil)
        XCTAssertEqual(c, RatingState(rating: nil, watched: true))   // clearing does NOT unwatch
        let last = await s.all().last(where: { $0.method == "PATCH" })!; XCTAssertEqual(String(decoding: last.body, as: UTF8.self), #"{"rating":null}"#)
    }
    func testWatchedWireFormat() async throws {
        let (f, s, _) = make()
        _ = try await f.setWatched(slug: "x", watched: true)
        let q = await s.all()[0]
        XCTAssertEqual(q.url.absoluteString, "https://letterboxd.com/s/film:7/watch/")
        XCTAssertEqual(String(decoding: q.body, as: UTF8.self), "watched=true&__csrf=T%2BK")
        let off = try await f.setWatched(slug: "x", watched: false); XCTAssertFalse(off.watched)
    }
    func testInvalidRatingsNeverSent() async throws {
        let (f, s, _) = make()
        for bad in [0.0, 0.4, 5.5, 3.3, -1] { do { _ = try await f.setRating(slug: "x", rating: bad); XCTFail("(bad)") } catch {} }
        let n = await s.all().count; XCTAssertEqual(n, 0)
    }
    func testReadbackMismatchFails() async throws {
        let (f, s, _) = make(); await s.setDrop()
        do { _ = try await f.setRating(slug: "x", rating: 3); XCTFail() } catch { XCTAssertTrue("\(error)".contains("readback")) }
    }
    func testSignedOutSendsNothing() async throws {
        let (f, s, a) = make(); a.revoke()
        do { _ = try await f.setWatched(slug: "x", watched: true); XCTFail() } catch {}
        let n = await s.all().count; XCTAssertEqual(n, 0)
    }
}
