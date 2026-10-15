import XCTest
@testable import LetterboxdKit

private actor HTMLBarrier {
    var calls = 0
    var html = "<html></html>"
    private var reached: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var entered = false
    let paused: Bool
    init(paused: Bool = false) { self.paused = paused }
    func get() async -> HTTPResult {
        calls += 1
        let captured = html
        if paused {
            entered = true; reached?.resume(); reached = nil
            await withCheckedContinuation { release = $0 }
        }
        return HTTPResult(data: Data(captured.utf8), status: 200)
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { reached = $0 }
    }
    func resume() { release?.resume(); release = nil }
    func update(_ h: String) { html = h }
}
private struct HTMLTransport: HTTPTransport {
    let state: HTMLBarrier
    func get(_ u: URL, accept: String) async throws -> HTTPResult { await state.get() }
}
final class WriteCacheInvalidationTests: XCTestCase {
    func testConfirmedWriteInvalidationDropsHTMLAndDecodedReadsBeforeReturning() async throws {
        let a = AuthAuthority(); a.setValidated(Session(username: "alice", cookies: []))
        let reads = ReadStore(directory: nil)
        let server = HTMLBarrier()
        let fetcher = Fetcher(transport: HTMLTransport(state: server), auth: a)
        let svc = PublicWebService(fetcher: fetcher, reads: reads)
        let first = try await svc.watchlist(username: "alice", page: 1, refresh: false)
        XCTAssertTrue(first.items.isEmpty)
        await server.update(try fixtureText("grid", "html"))
        await svc.invalidateReads() // awaited write-completion boundary
        let second = try await svc.watchlist(username: "alice", page: 1, refresh: false)
        XCTAssertEqual(second.items.map(\.slug), ["a-minecraft-movie", "your-name"])
        let calls = await server.calls; XCTAssertEqual(calls, 2)
    }
    func testInFlightPreWriteHTMLCannotReturnOrRefillEitherCache() async throws {
        let a = AuthAuthority(); a.setValidated(Session(username: "alice", cookies: []))
        let reads = ReadStore(directory: nil), cache = ResponseCache()
        let server = HTMLBarrier(paused: true)
        let fetcher = Fetcher(transport: HTMLTransport(state: server), cache: cache, auth: a)
        let svc = PublicWebService(fetcher: fetcher, reads: reads)
        let t = Task { try await svc.watchlist(username: "alice", page: 1, refresh: false) }
        await server.wait()
        await svc.invalidateReads()
        await server.resume()
        do { _ = try await t.value; XCTFail("Late pre-write read must be cancelled") }
        catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
        let u = URL(string: "https://letterboxd.com/alice/watchlist/")!
        let html = await cache.get(u, partition: a.generation)
        XCTAssertNil(html)
        XCTAssertNil(reads.get(CachedPage<FilmSummary>.self, ns: "alice", key: "watchlist-alice-1"))
    }
    func testFetcherDirectlyFencesLateReturnEvenWithoutDecodedStore() async throws {
        let server = HTMLBarrier(paused: true)
        let f = Fetcher(transport: HTMLTransport(state: server))
        let t = Task { try await f.text(URL(string: "https://letterboxd.com/film/x/")!) }
        await server.wait()
        await f.clearCache()
        await server.resume()
        do { _ = try await t.value; XCTFail("Fetcher must not return pre-clear HTML") }
        catch { XCTAssertEqual(error as? LetterboxdError, .cancelled) }
    }
}
