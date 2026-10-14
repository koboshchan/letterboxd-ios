import SwiftUI
import LetterboxdKit

enum Theme {
    static let green = Color(red: 0.0, green: 0.62, blue: 0.27)       // Letterboxd green, deepened so it reads on light and dark
    static let orange = Color.orange
    static let blue = Color(red: 0.25, green: 0.74, blue: 0.96)
    static let card = Color(.secondarySystemBackground)
    static let hairline = Color.primary.opacity(0.08)
    static func serif(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font { .system(size: size, weight: weight, design: .serif) }
}

/// Holds the live data layer. There is no demo, guest or fixture mode in the shipped app.
@Observable @MainActor
final class AppEnvironment {
    let service: LetterboxdService
    let auth: AuthAuthority
    /// Watchlist/like client. Production: FilmActions. UI-test host injects a mock of the same protocol.
    var actions: FilmActionsClient? = nil
    /// Member being viewed; set only from a server-validated session (empty while signed out, never shown then).
    private(set) var username = ""
    /// The only writer: bound to the validated session (see AccountModel.onUsernameChange). No manual override exists.
    func bind(username u: String?) { username = u ?? "" }
    /// Launch-argument hooks for deterministic screenshots, compiled into DEBUG builds only. They only pick a tab/segment
    /// inside the authenticated UI and cannot bypass the sign-in gate.
    static func arg(_ k: String) -> String? {
        #if DEBUG
        let a = ProcessInfo.processInfo.arguments; return a.firstIndex(of: k).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }
        #else
        return nil
        #endif
    }
    init(service: LetterboxdService, auth: AuthAuthority = AuthAuthority()) { self.service = service; self.auth = auth }
    static func make() -> AppEnvironment {
        // Credentials come only from the in-memory, server-validated AuthAuthority (never read raw from the Keychain).
        let auth = AuthAuthority()
        let transport = URLSessionTransport(cookieHeader: { auth.cookieHeader() })
        let e = AppEnvironment(service: PublicWebService(fetcher: Fetcher(transport: transport, auth: auth)), auth: auth)
        e.actions = FilmActions(transport: transport, auth: auth)
        return e
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AccountModel.self) private var account
    @State private var browsePath: [FilmSummary] = AppEnvironment.arg("-UIFilm").map { [FilmSummary(slug: $0, title: AppEnvironment.arg("-UIFilmTitle") ?? $0, year: nil)] } ?? []
    @State private var showSignIn = ProcessInfo.processInfo.arguments.contains("-UISignIn")
    @State private var selection = Int(AppEnvironment.arg("-UITab") ?? "0") ?? 0
    var body: some View {
        // Nothing but the gate renders until the server has validated a session in this launch.
        Group {
            switch account.gate {
            case .checking: GateScreen(title: "Checking your sign-in", detail: nil, busy: true)
            case .restoreFailed(let why): GateScreen(title: "Couldn't confirm your sign-in", detail: why, busy: false, retry: { Task { await account.restore() } }, signIn: { showSignIn = true })
            case .signInRequired: GateScreen(title: "Sign in to Letterboxd", detail: "This app needs your Letterboxd account. You sign in on letterboxd.com itself; the app never sees your password.", busy: false, signIn: { showSignIn = true })
            case .ready: tabs
            }
        }
        .id(account.epoch)   // every auth change rebuilds all tabs and their loaded models
        .sheet(isPresented: $showSignIn) { SignInScreen() }
    }
    private var tabs: some View {
        TabView(selection: $selection) {
            Tab("Profile", systemImage: "person.crop.circle", value: 0) { NavigationStack {
                ProfileScreen().toolbar { AccountButton() }.sharedDestinations()
            } }
            Tab("Browse", systemImage: "film.stack", value: 1) { NavigationStack(path: $browsePath) { BrowseScreen().sharedDestinations() } }
            Tab("Search", systemImage: "magnifyingglass", value: 2, role: .search) { NavigationStack { SearchScreen().sharedDestinations() } }
        }
    }
}

/// Full-screen state shown instead of any app content while signed out, validating, or when validation failed.
struct GateScreen: View {
    let title: String
    let detail: String?
    let busy: Bool
    var retry: (() -> Void)? = nil
    var signIn: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: "film.stack.fill").font(.system(size: 56)).foregroundStyle(Theme.green).accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Letterboxd").font(Theme.serif(44))
                Text(title).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if busy { ProgressView().controlSize(.large) }
            if let d = detail { Text(d).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            Spacer()
            if let retry { Button("Try again", action: retry).buttonStyle(.bordered).controlSize(.large) }
            if let signIn {
                Button(action: signIn) { Label("Sign in on letterboxd.com", systemImage: "person.badge.key").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            Text(Legal.notice).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Legal {
    /// Disclosures kept from the former About screen; shown on the sign-in gate.
    static let notice = "Unofficial client, not affiliated with Letterboxd and not using its API. Pages are fetched only when you open or refresh a screen and challenges or blocks are never bypassed. Letterboxd's terms prohibit automated gathering without authorization; use at your own discretion. Watchlist and like are supported; diary, review, list and profile edits are not."
}


extension View {
    /// Every tab's stack must resolve the same routes: a review author, a list row or a follower link can be
    /// reached from any tab (film -> reviews -> author), so registering them on one stack leaves dead taps.
    func sharedDestinations() -> some View {
        navigationDestination(for: NetworkRoute.self) { MemberListScreen(route: $0) }
            .navigationDestination(for: ListRoute.self) { ListDetailScreen(list: $0.list) }
            .navigationDestination(for: MemberRoute.self) { ProfileScreen(memberUsername: $0.username) }
    }
}
