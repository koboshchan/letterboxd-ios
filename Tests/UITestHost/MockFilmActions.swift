import Foundation
import LetterboxdKit

/// Mock of the production FilmActionsClient for the UI-test host. Holds a pretend server state so the same buttons
/// and the same FilmActionsModel run in both directions and through failure modes. No network.
final class MockFilmActions: FilmActionsClient, @unchecked Sendable {
    enum Mode: String { case ok, fail, timeout, slow, logout, mismatch, loadfail }
    let mode: Mode, auth: AuthAuthority
    private let l = NSLock(); private var server = FilmState(watchlist: false, liked: false)
    private var rs = RatingState(rating: nil, watched: false)
    var supportsRating: Bool { true }
    func ratingState(slug: String) async throws -> RatingState { if mode == .loadfail { throw LetterboxdError.http(status: 500) }; return l.withLock { rs } }
    private func writeRating(_ next: RatingState) async throws -> RatingState {
        switch mode {
        case .fail: throw LetterboxdError.http(status: 500)
        case .timeout: l.withLock { rs = next }; throw LetterboxdError.network("timed out")
        case .mismatch: throw LetterboxdError.parse("rating readback mismatch")
        case .slow: try await Task.sleep(nanoseconds: 1_500_000_000)
        case .logout: auth.revoke()
        default: break
        }
        l.withLock { rs = next }; return next
    }
    func setRating(slug: String, rating: Double?) async throws -> RatingState {
        let cur = l.withLock { rs }
        return try await writeRating(RatingState(rating: rating, watched: rating != nil ? true : cur.watched))
    }
    func setWatched(slug: String, watched: Bool) async throws -> RatingState {
        let cur = l.withLock { rs }
        return try await writeRating(RatingState(rating: cur.rating, watched: watched))
    }
    init(mode: Mode, auth: AuthAuthority) { self.mode = mode; self.auth = auth }
    private func get() -> FilmState { l.lock(); defer { l.unlock() }; return server }
    private func set(_ s: FilmState) { l.lock(); server = s; l.unlock() }

    func state(slug: String) async throws -> FilmState {
        if mode == .loadfail { throw LetterboxdError.http(status: 500) }
        return get()
    }
    private func write(_ next: FilmState) async throws -> FilmState {
        switch mode {
        case .fail: throw LetterboxdError.http(status: 500)                  // nothing committed
        case .timeout: set(next); throw LetterboxdError.network("timed out")  // committed, client never heard
        case .mismatch: throw LetterboxdError.parse("watchlist readback mismatch")
        case .slow: try await Task.sleep(nanoseconds: 1_500_000_000); set(next); return next
        case .logout: auth.revoke(); set(next); return next                   // account changes mid-request
        default: set(next); return next
        }
    }
    func setWatchlist(slug: String, on: Bool) async throws -> FilmState { let s = get(); return try await write(FilmState(watchlist: on, liked: s.liked)) }
    func setLike(slug: String, liked: Bool) async throws -> FilmState { let s = get(); return try await write(FilmState(watchlist: s.watchlist, liked: liked)) }
}
