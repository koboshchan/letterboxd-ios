import SwiftUI
import LetterboxdKit

/// Watchlist and like for one film. Every flag is what the server last confirmed (relation read after each write).
/// Until it is known the buttons say Add to Watchlist / Like and will add. A write whose outcome cannot be confirmed
/// (timeout after the server may have committed, 200 with a different state) never claims "unchanged": the flag goes
/// back to unknown and the notice asks for a refresh.
@Observable @MainActor
final class FilmActionsModel {
    enum Flag: Equatable { case unknown, on, off }
    enum Notice: Equatable { case none, signIn, blocked, unconfirmed, loadFailed }
    private(set) var watchlist = Flag.unknown
    private(set) var liked = Flag.unknown
    private(set) var busy = false
    private(set) var notice = Notice.none
    private let client: FilmActionsClient?, auth: AuthAuthority, slug: String
    init(client: FilmActionsClient?, auth: AuthAuthority, slug: String) { self.client = client; self.auth = auth; self.slug = slug }
    var available: Bool { client != nil }
    var signedOut: Bool { auth.cookieHeader() == nil }

    static let unconfirmedText = "Couldn’t confirm the change. Refresh to check."
    var noticeText: String? {
        switch notice {
        case .none: nil
        case .signIn: "Sign in again to do this."
        case .blocked: "Letterboxd asked for a human check. Open the film on letterboxd.com."
        case .unconfirmed: Self.unconfirmedText
        case .loadFailed: "Couldn’t check your current status. Refresh to try again."
        }
    }
    var canRefresh: Bool { notice == .unconfirmed || notice == .loadFailed }

    private func apply(_ s: FilmState) { watchlist = s.watchlist ? .on : .off; liked = s.liked ? .on : .off }

    /// uncertain: which flags become unknown if this fails after the request may have been sent.
    private func run(sent: Bool, _ body: @escaping (FilmActionsClient) async throws -> FilmState, onFail: Notice) async {
        guard let client, !busy else { return }
        busy = true; notice = .none
        let g = auth.generation
        defer { busy = false }
        do {
            let s = try await body(client)
            guard auth.generation == g else { return }          // sign-out / account switch: never publish
            apply(s)
        } catch is CancellationError { return }
        catch LetterboxdError.cancelled { return }
        catch AuthError.notSignedIn { guard auth.generation == g else { return }; notice = .signIn }
        catch LetterboxdError.blocked { guard auth.generation == g else { return }; notice = .blocked }
        catch {
            guard auth.generation == g else { return }
            if sent { watchlist = .unknown; liked = .unknown }
            notice = onFail
        }
    }
    func refresh() async { await run(sent: false, { [slug] c in try await c.state(slug: slug) }, onFail: .loadFailed) }
    func toggleWatchlist() async {
        let target = watchlist != .on
        await run(sent: true, { [slug] c in try await c.setWatchlist(slug: slug, on: target) }, onFail: .unconfirmed)
    }
    func toggleLike() async {
        let target = liked != .on
        await run(sent: true, { [slug] c in try await c.setLike(slug: slug, liked: target) }, onFail: .unconfirmed)
    }
}

struct FilmActionBar: View {
    @State var model: FilmActionsModel
    var body: some View {
        if model.available {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Button { Task { await model.toggleWatchlist() } } label: {
                        Label(model.watchlist == .on ? "Remove from Watchlist" : "Add to Watchlist", systemImage: model.watchlist == .on ? "checkmark.circle.fill" : "plus.circle")
                    }.accessibilityIdentifier("watchlist-button")
                    Button { Task { await model.toggleLike() } } label: {
                        Label(model.liked == .on ? "Unlike" : "Like", systemImage: model.liked == .on ? "heart.fill" : "heart")
                    }.accessibilityIdentifier("like-button")
                    if model.busy { ProgressView().accessibilityIdentifier("film-action-progress") }
                }.buttonStyle(.bordered).disabled(model.busy || model.signedOut)
                if let t = model.noticeText {
                    Text(t).font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("film-action-notice")
                    if model.canRefresh {
                        Button("Refresh") { Task { await model.refresh() } }.buttonStyle(.bordered).disabled(model.busy)
                            .accessibilityIdentifier("film-action-refresh")
                    }
                }
            }
            .task { await model.refresh() }
        }
    }
}


/// Long-press menu shared by every poster (profile, browse, lists, person grids): Open film, Add/Remove Watchlist, Like/Unlike.
/// Only the two verified writes are offered; rating and watched are not shown until their requests are captured.
/// Labels are explicit (Add/Like) until the server state is known; state is the same shared model the film screen uses.
struct FilmContextMenu: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    let film: FilmSummary
    func body(content: Content) -> some View {
        if env.actions == nil { content } else {
            let m = env.actionModel(slug: film.slug)
            content.contextMenu {
                NavigationLink(value: film) { Label("Open Film", systemImage: "film") }
                Button { Task { await m.toggleWatchlist() } } label: {
                    Label(m.watchlist == .on ? "Remove from Watchlist" : "Add to Watchlist", systemImage: m.watchlist == .on ? "checkmark.circle.fill" : "plus.circle")
                }.disabled(m.busy || m.signedOut).accessibilityIdentifier("menu-watchlist")
                Button { Task { await m.toggleLike() } } label: {
                    Label(m.liked == .on ? "Unlike" : "Like", systemImage: m.liked == .on ? "heart.fill" : "heart")
                }.disabled(m.busy || m.signedOut).accessibilityIdentifier("menu-like")
            }
        }
    }
}
extension View { func filmContextMenu(_ f: FilmSummary) -> some View { modifier(FilmContextMenu(film: f)) } }
