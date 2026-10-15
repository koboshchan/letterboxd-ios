import XCTest
@testable import LetterboxdKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Explicit barriers, no sleeps: pause exactly before a request consumes its supplied credentials.
private actor WriteBarrier {
    private var entered = false
    private var reached: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    var cookies: [String] = []
    var mutations = 0
    func pause() async {
        entered = true; reached?.resume(); reached = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { reached = $0 }
    }
    func resume() { release?.resume(); release = nil }
    func record(_ c: RequestCredentials, mutation: Bool) {
        cookies.append(c.cookie)
        if mutation { mutations += 1 }
    }
}

private struct PinnedTransport: HTTPTransport {
    let barrier: WriteBarrier
    let pauseAt: String
    func get(_ u: URL, accept: String) async throws -> HTTPResult { XCTFail("Unbound GET"); throw AuthError.notSignedIn }
    func send(_ r: WriteRequest) async throws -> HTTPResult { XCTFail("Unbound write"); throw AuthError.notSignedIn }
    func get(_ u: URL, accept: String, credentials: RequestCredentials) async throws -> HTTPResult {
        let phase = u.path.hasSuffix("/json") ? "handle" : "readback"
        if phase == pauseAt { await barrier.pause() }
        await barrier.record(credentials, mutation: false)
        if phase == "handle" {
            return HTTPResult(data: Data(#"{"result":true,"csrf":"token","lid":"Ab1","id":7}"#.utf8), status: 200)
        }
        return HTTPResult(data: Data(#"{"result":true,"liked":true,"isInWatchlist":true}"#.utf8), status: 200)
    }
    func send(_ r: WriteRequest, credentials: RequestCredentials) async throws -> HTTPResult {
        if pauseAt == "write" { await barrier.pause() }
        await barrier.record(credentials, mutation: true)
        return HTTPResult(data: Data((r.method == "PATCH" ? "{}" : #"{"result":true,"liked":true}"#).utf8), status: 200)
    }
}

final class SessionWriteFenceTests: XCTestCase {
    private func session(_ name: String) -> Session {
        Session(username: name, cookies: [WebCookie(name: SessionCookies.sessionCookieName, value: name, domain: "letterboxd.com")])
    }
    func testAccountSwitchNeverSubstitutesNewCookiesAtAnyStage() async throws {
        for phase in ["handle", "write", "readback"] {
            for like in [false, true] {
                let a = AuthAuthority(); a.setValidated(session("alice"))
                let b = WriteBarrier()
                let f = FilmActions(transport: PinnedTransport(barrier: b, pauseAt: phase), auth: a)
                let t = Task { if like { return try await f.setLike(slug: "x", liked: true) }
                    else { return try await f.setWatchlist(slug: "x", on: true) } }
                await b.wait()
                a.setValidated(session("bob"))
                await b.resume()
                do { _ = try await t.value; XCTFail("Old operation must not succeed") }
                catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
                let cookies = await b.cookies
                XCTAssertFalse(cookies.isEmpty)
                XCTAssertTrue(cookies.allSatisfy { $0 == "letterboxd.user.CURRENT=alice" }, "\(phase): \(cookies)")
                let mutations = await b.mutations
                if phase == "handle" { XCTAssertEqual(mutations, 0) }
            }
        }
    }
    func testOldHandleRejectedBeforeMutationOrReadback() async throws {
        let a = AuthAuthority(); a.setValidated(session("alice"))
        let b = WriteBarrier()
        let f = FilmActions(transport: PinnedTransport(barrier: b, pauseAt: "never"), auth: a)
        let h = try await f.handle(slug: "x")
        a.setValidated(session("bob"))
        do { try await f.setWatchlist(h, on: true); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
        do { _ = try await f.setLike(h, liked: true); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
        do { _ = try await f.relation(h); XCTFail() } catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
        let mutations = await b.mutations; XCTAssertEqual(mutations, 0)
        let cookies = await b.cookies; XCTAssertEqual(cookies.count, 1)
    }
}

private final class OriginCookieProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "letterboxd.user.CURRENT=alice")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let r = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension SessionWriteFenceTests {
    func testProductionTransportUsesSnapshotNotLiveCookieForGetAndSend() async throws {
        let a = AuthAuthority(); a.setValidated(session("alice"))
        let origin = try a.requestCredentials()
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [OriginCookieProtocol.self]
        let transport = URLSessionTransport(configuration: c, cookieHeader: {
            XCTFail("Pinned operations must never consult live cookies")
            return a.cookieHeader()
        })
        a.setValidated(session("bob"))
        let u = URL(string: "https://letterboxd.com/film/x/json/")!
        _ = try await transport.get(u, accept: "application/json", credentials: origin)
        _ = try await transport.send(WriteRequest(method: "PATCH", url: u, contentType: "application/json", body: Data("{}".utf8),
            headers: ["Cookie": "bob", "Authorization": "bob"]), credentials: origin)
        XCTAssertEqual(origin.generation, 1)
        XCTAssertEqual(a.generation, 2)
    }
}
