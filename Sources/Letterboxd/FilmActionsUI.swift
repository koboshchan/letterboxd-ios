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
    /// Watched flag and star rating, as the server last confirmed them (only when the client supports rating).
    private(set) var watched = Flag.unknown
    private(set) var rating: Double? = nil
    private(set) var ratingKnown = false
    private(set) var busy = false
    private(set) var notice = Notice.none
    private let client: FilmActionsClient?, auth: AuthAuthority, slug: String
    init(client: FilmActionsClient?, auth: AuthAuthority, slug: String) { self.client = client; self.auth = auth; self.slug = slug }
    var available: Bool { client != nil }
    var supportsRating: Bool { client?.supportsRating ?? false }
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

    /// Set by the app: drops cached reads after a confirmed or uncertain rating/watched write.
    var onConfirmed: (() async -> Void)?
    private func applyState(_ s: FilmState) { watchlist = s.watchlist ? .on : .off; liked = s.liked ? .on : .off }

    /// uncertain: which flags become unknown if this fails after the request may have been sent.
    private func run(sent: Bool, _ body: @escaping (FilmActionsClient) async throws -> FilmState, onFail: Notice) async {
        guard let client, !busy else { return }
        busy = true; notice = .none
        let g = auth.generation
        defer { busy = false }
        do {
            let s = try await body(client)
            guard auth.generation == g else { return }          // sign-out / account switch: never publish
            if sent { await onConfirmed?() }
            guard auth.generation == g else { return }
            applyState(s)
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
    func refresh() async {
        await run(sent: false, { [slug] c in try await c.state(slug: slug) }, onFail: .loadFailed)
        if supportsRating && notice == .none { await runRating(sent: false, { [slug] c in try await c.ratingState(slug: slug) }, onFail: .loadFailed) }
    }
    /// Same fences as run(): never publish across an account change, confirm via readback, and fall back to unknown when a
    /// write's outcome could not be confirmed.
    private func runRating(sent: Bool, _ body: @escaping (FilmActionsClient) async throws -> RatingState, onFail: Notice) async {
        guard let client, !busy else { return }
        busy = true; notice = .none
        let g = auth.generation
        defer { busy = false }
        do {
            let s = try await body(client)
            guard auth.generation == g else { return }
            if sent { await onConfirmed?() }
            guard auth.generation == g else { return }
            rating = s.rating; ratingKnown = true; watched = s.watched ? .on : .off
        } catch is CancellationError { return }
        catch LetterboxdError.cancelled { return }
        catch AuthError.notSignedIn { guard auth.generation == g else { return }; notice = .signIn }
        catch LetterboxdError.blocked { guard auth.generation == g else { return }; notice = .blocked }
        catch {
            guard auth.generation == g else { return }
            if sent { await onConfirmed?() }
            guard auth.generation == g else { return }
            if sent { rating = nil; ratingKnown = false; watched = .unknown }
            notice = onFail
        }
    }
    /// nil clears the rating. Explicit set: never a toggle, so a stale view cannot flip the wrong way.
    func setRating(_ value: Double?) async {
        guard supportsRating, value.map(FilmActions.validRating) ?? true else { return }
        await runRating(sent: true, { [slug] c in try await c.setRating(slug: slug, rating: value) }, onFail: .unconfirmed)
    }
    func toggleWatched() async {
        guard supportsRating else { return }
        let wasUnknown = watched == .unknown
        if wasUnknown { await refresh(); guard watched != .unknown else { return } }
        if wasUnknown && watched == .on { return }
        let target = wasUnknown ? true : watched != .on
        await runRating(sent: true, { [slug] c in try await c.setWatched(slug: slug, watched: target) }, onFail: .unconfirmed)
    }
    func toggleWatchlist() async {
        // Unknown state: read the server first. Add is an explicit set-true, never a blind toggle; a failed read sends nothing.
        // The button said "Add" while unknown, so the intent is set-true; an already-watchlisted film must NOT be removed.
        let wasUnknown = watchlist == .unknown
        if wasUnknown { await refresh(); guard watchlist != .unknown else { return } }
        let target = wasUnknown ? true : watchlist != .on
        if wasUnknown && watchlist == .on { return }
        await run(sent: true, { [slug] c in try await c.setWatchlist(slug: slug, on: target) }, onFail: .unconfirmed)
    }
    func toggleLike() async {
        let wasUnknown = liked == .unknown
        if wasUnknown { await refresh(); guard liked != .unknown else { return } }
        let target = wasUnknown ? true : liked != .on
        if wasUnknown && liked == .on { return }
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
                if model.supportsRating { RatingControl(model: model) }
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
/// Only captured, readback-verified writes are offered: watchlist, like, watched/unwatched and half-star rating.
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
                if m.supportsRating {
                    Button { Task { await m.toggleWatched() } } label: {
                        Label(m.watched == .on ? "Mark as Unwatched" : "Mark as Watched", systemImage: m.watched == .on ? "eye.slash" : "eye")
                    }.disabled(m.busy || m.signedOut).accessibilityIdentifier("menu-watched")
                    Menu {
                        ForEach(Array(stride(from: 5.0, through: 0.5, by: -0.5)), id: \.self) { v in
                            Button(RatingControl.describe(v)) { Task { await m.setRating(v) } }.accessibilityIdentifier("menu-rate-\(v)")
                        }
                        Button("Clear Rating", role: .destructive) { Task { await m.setRating(nil) } }.accessibilityIdentifier("menu-rate-clear")
                    } label: { Label("Rate", systemImage: "star") }
                        .disabled(m.busy || m.signedOut).accessibilityIdentifier("menu-rate")
                }
            }
        }
    }
}
extension View { func filmContextMenu(_ f: FilmSummary) -> some View { modifier(FilmContextMenu(film: f)) } }


/// Five stars with half-star hit areas, a watched toggle and Clear. Stars show only what the server confirmed; tapping sends
/// an explicit value (never a toggle) and the stars change only after the readback.
struct RatingControl: View {
    let model: FilmActionsModel
    static func describe(_ v: Double) -> String { v == 1 ? "1 star" : (v.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(v)) stars" : "\(v) stars") }
    private func symbol(_ star: Int) -> String {
        guard let r = model.rating else { return "star" }
        return r >= Double(star) ? "star.fill" : (r >= Double(star) - 0.5 ? "star.leadinghalf.filled" : "star")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { i in
                    Image(systemName: symbol(i)).font(.system(size: 28)).foregroundStyle(Theme.green).frame(width: 42, height: 44)
                        .overlay {
                            HStack(spacing: 0) {
                                half(Double(i) - 0.5, leading: true)
                                half(Double(i), leading: false)
                            }
                        }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("rating-control")
            HStack(spacing: 10) {
                Button { Task { await model.toggleWatched() } } label: {
                    Label(model.watched == .on ? "Watched" : "Mark as Watched", systemImage: model.watched == .on ? "eye.fill" : "eye")
                }.accessibilityIdentifier("watched-button")
                if model.rating != nil {
                    Button { Task { await model.setRating(nil) } } label: { Label("Clear Rating", systemImage: "xmark.circle") }
                        .accessibilityIdentifier("rating-clear")
                }
            }.buttonStyle(.bordered)
        }
        .disabled(model.busy || model.signedOut)
    }
    private func half(_ v: Double, leading: Bool) -> some View {
        Button { Task { await model.setRating(v) } } label: { Color.clear.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .accessibilityLabel(Self.describe(v)).accessibilityIdentifier("rate-\(v)")
            .accessibilityAddTraits(model.rating == v ? [.isSelected] : [])
    }
}
