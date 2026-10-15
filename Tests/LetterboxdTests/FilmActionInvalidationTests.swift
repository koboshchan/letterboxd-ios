import XCTest
@testable import Letterboxd
import LetterboxdKit

private struct ImmediateActions: FilmActionsClient {
    var supportsRating: Bool { true }
    func ratingState(slug: String) async throws -> RatingState { RatingState(rating: nil, watched: false) }
    func setRating(slug: String, rating: Double?) async throws -> RatingState { RatingState(rating: rating, watched: true) }
    func setWatched(slug: String, watched: Bool) async throws -> RatingState { RatingState(rating: nil, watched: watched) }

    func state(slug: String) async throws -> FilmState { FilmState(watchlist: false, liked: false) }
    func setWatchlist(slug: String, on: Bool) async throws -> FilmState { FilmState(watchlist: on, liked: false) }
    func setLike(slug: String, liked: Bool) async throws -> FilmState { FilmState(watchlist: false, liked: liked) }
}
@MainActor
private final class InvalidationBarrier {
    var entered = false
    private var reached: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; reached?.resume(); reached = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async {
        if entered { return }
        await withCheckedContinuation { reached = $0 }
    }
    func resume() { release?.resume(); release = nil }
}
@MainActor
final class FilmActionInvalidationTests: XCTestCase {
    func testConfirmedStateNotPublishedUntilInvalidationCompletes() async {
        let a = AuthAuthority()
        a.setValidated(Session(username: "alice", cookies: [WebCookie(name: SessionCookies.sessionCookieName, value: "a", domain: "letterboxd.com")]))
        let m = FilmActionsModel(client: ImmediateActions(), auth: a, slug: "x")
        let barrier = InvalidationBarrier()
        m.onConfirmed = { await barrier.pause() }
        await m.refresh()
        XCTAssertFalse(barrier.entered, "Plain state refresh must not invalidate caches")
        XCTAssertEqual(m.watchlist, .off)
        let t = Task { await m.toggleWatchlist() }
        await barrier.wait()
        XCTAssertTrue(m.busy)
        XCTAssertEqual(m.watchlist, .off, "Do not publish success before both caches are fenced")
        barrier.resume()
        await t.value
        XCTAssertEqual(m.watchlist, .on)
        XCTAssertFalse(m.busy)
    }
    func testAccountSwitchDuringInvalidationNeverPublishesOldState() async {
        let a = AuthAuthority()
        a.setValidated(Session(username: "alice", cookies: [WebCookie(name: SessionCookies.sessionCookieName, value: "a", domain: "letterboxd.com")]))
        let m = FilmActionsModel(client: ImmediateActions(), auth: a, slug: "x")
        await m.refresh()
        let barrier = InvalidationBarrier()
        m.onConfirmed = { await barrier.pause() }
        let t = Task { await m.toggleLike() }
        await barrier.wait()
        a.revoke()
        barrier.resume()
        await t.value
        XCTAssertEqual(m.liked, .off)
        XCTAssertFalse(m.busy)
    }
}

private struct UncertainRatingActions: FilmActionsClient {
    var supportsRating: Bool { true }
    func state(slug: String) async throws -> FilmState { FilmState(watchlist: false, liked: false) }
    func setWatchlist(slug: String, on: Bool) async throws -> FilmState { try await state(slug: slug) }
    func setLike(slug: String, liked: Bool) async throws -> FilmState { try await state(slug: slug) }
    func ratingState(slug: String) async throws -> RatingState { RatingState(rating: 2, watched: true) }
    func setRating(slug: String, rating: Double?) async throws -> RatingState { throw LetterboxdError.network("timeout after commit") }
    func setWatched(slug: String, watched: Bool) async throws -> RatingState { throw LetterboxdError.parse("watched readback mismatch") }
}

@MainActor
final class RatingInvalidationTests: XCTestCase {
    private func auth() -> AuthAuthority {
        let a = AuthAuthority()
        a.setValidated(Session(username: "alice", cookies: [WebCookie(name: SessionCookies.sessionCookieName, value: "a", domain: "letterboxd.com")]))
        return a
    }
    func testRatingNotPublishedUntilCacheInvalidationCompletes() async {
        let a = auth(), barrier = InvalidationBarrier()
        let m = FilmActionsModel(client: ImmediateActions(), auth: a, slug: "x")
        m.onConfirmed = { await barrier.pause() }
        await m.refresh()
        XCTAssertFalse(barrier.entered)
        let t = Task { await m.setRating(0.5) }
        await barrier.wait()
        XCTAssertNil(m.rating); XCTAssertTrue(m.busy)
        barrier.resume(); await t.value
        XCTAssertEqual(m.rating, 0.5); XCTAssertEqual(m.watched, .on)
    }
    func testAccountSwitchDuringRatingInvalidationDropsResult() async {
        let a = auth(), barrier = InvalidationBarrier()
        let m = FilmActionsModel(client: ImmediateActions(), auth: a, slug: "x")
        await m.refresh()
        m.onConfirmed = { await barrier.pause() }
        let t = Task { await m.setRating(5) }
        await barrier.wait(); a.revoke(); barrier.resume(); await t.value
        XCTAssertNil(m.rating); XCTAssertEqual(m.watched, .off)
    }
    func testUncertainRatingAndWatchedWritesInvalidateBeforeUnknownPublication() async {
        for rating in [true, false] {
            let a = auth(), barrier = InvalidationBarrier()
            let m = FilmActionsModel(client: UncertainRatingActions(), auth: a, slug: "x")
            await m.refresh()
            m.onConfirmed = { await barrier.pause() }
            let t = Task { if rating { await m.setRating(5) } else { await m.toggleWatched() } }
            await barrier.wait()
            XCTAssertEqual(m.rating, 2); XCTAssertTrue(m.busy)
            barrier.resume(); await t.value
            XCTAssertFalse(m.ratingKnown); XCTAssertEqual(m.watched, .unknown)
            XCTAssertEqual(m.notice, .unconfirmed)
        }
    }
}
