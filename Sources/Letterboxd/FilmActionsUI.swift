import SwiftUI
import LetterboxdKit

/// Watchlist and like for one film. State is only what the server confirmed: the film JSON does not report current
/// watchlist/like state, so both start as unknown and change only after a 200 response (like echoes the server's value).
@Observable @MainActor
final class FilmActionsModel {
    enum Flag: Equatable { case unknown, on, off }
    private(set) var watchlist = Flag.unknown, liked = Flag.unknown
    private(set) var busy = false
    private(set) var error: String?
    private let actions: FilmActions?, auth: AuthAuthority, slug: String
    init(actions: FilmActions?, auth: AuthAuthority, slug: String) { self.actions = actions; self.auth = auth; self.slug = slug }
    var signedOut: Bool { auth.cookieHeader() == nil }
    var available: Bool { actions != nil }

    private func run(_ body: @escaping (FilmActions, FilmHandle, Int) async throws -> Void) async {
        guard let actions, !busy else { return }
        busy = true; error = nil
        let g = auth.generation
        defer { busy = false }
        do {
            let h: FilmHandle
            h = try await actions.handle(slug: slug)   // fresh each time: the csrf token rotates
            try await body(actions, h, g)
        } catch LetterboxdError.cancelled { /* auth changed: nothing is applied */ }
        catch AuthError.notSignedIn { error = "Sign in again to do this." }
        catch LetterboxdError.blocked { error = "Letterboxd asked for a human check. Open the film on letterboxd.com." }
        catch { error = "Couldn't confirm the change with Letterboxd." }
    }
    func toggleWatchlist() async {
        let target = watchlist != .on
        await run { [self] a, h, g in
            try await a.setWatchlist(h, on: target)
            guard auth.generation == g else { return }   // stale epoch: never publish
            watchlist = target ? .on : .off
        }
    }
    func toggleLike() async {
        let target = liked != .on
        await run { [self] a, h, g in
            let r = try await a.setLike(h, liked: target)
            guard auth.generation == g else { return }
            liked = r.liked ? .on : .off
        }
    }
}

struct FilmActionBar: View {
    @State var model: FilmActionsModel
    var body: some View {
        if model.available {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { Task { await model.toggleWatchlist() } } label: {
                        Label(model.watchlist == .on ? "On watchlist" : "Watchlist", systemImage: model.watchlist == .on ? "checkmark.circle.fill" : "plus.circle")
                    }.accessibilityIdentifier("watchlist-button")
                    Button { Task { await model.toggleLike() } } label: {
                        Label(model.liked == .on ? "Liked" : "Like", systemImage: model.liked == .on ? "heart.fill" : "heart")
                    }.accessibilityIdentifier("like-button")
                }.buttonStyle(.bordered).disabled(model.busy || model.signedOut)
                if let e = model.error { Text(e).font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }
}
