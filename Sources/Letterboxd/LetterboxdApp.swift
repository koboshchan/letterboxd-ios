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
    /// Clears read-data and image caches. UI-test host injects a counting stub.
    var clearCaches: @MainActor () async -> Void = {}
    private var models: [String: FilmActionsModel] = [:]
    private var modelsGeneration = -1
    /// One shared action model per film so the poster menus and the film screen show and update the same server-confirmed
    /// state. Dropped whenever the auth generation changes (sign-out / account switch), so one account never sees another's.
    func actionModel(slug: String) -> FilmActionsModel {
        if modelsGeneration != auth.generation { models = [:]; modelsGeneration = auth.generation }
        if let m = models[slug] { return m }
        if models.count >= 200 { models = [:] }
        let m = FilmActionsModel(client: actions, auth: auth, slug: slug); models[slug] = m; return m
    }
    /// Number of pushed screens (film detail and its children) that want the bottom nav hidden; nav shows only at 0.
    var bottomNavHiders = 0
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
        let svc = e.service as? PublicWebService
        e.clearCaches = { await svc?.clearCaches(); await ImagePipeline.shared.clearAll() }
        return e
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(AccountModel.self) private var account
    @State private var browsePath: NavigationPath = {
        var p = NavigationPath()
        if let slug = AppEnvironment.arg("-UIFilm") { p.append(FilmSummary(slug: slug, title: AppEnvironment.arg("-UIFilmTitle") ?? slug, year: nil)) }
        return p
    }()
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
            }.toolbarVisibility(.hidden, for: .tabBar) }
            Tab("Browse", systemImage: "film.stack", value: 1) { NavigationStack(path: $browsePath) { BrowseScreen().sharedDestinations() }.toolbarVisibility(.hidden, for: .tabBar) }
            Tab("Search", systemImage: "magnifyingglass", value: 2) { NavigationStack { SearchScreen().sharedDestinations() }.toolbarVisibility(.hidden, for: .tabBar) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if env.bottomNavHiders == 0 { BottomNav(selection: $selection).transition(.opacity) }
        }
    }
}

/// Profile + Browse in one glass pill on the left, Search as its own circular glass button on the right.
/// Drives the TabView selection, so each tab keeps its own NavigationStack and state.
struct BottomNav: View {
    @Binding var selection: Int
    var body: some View {
        GlassGroup {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    item("Profile", "person.crop.circle", 0)
                    item("Browse", "film.stack", 1)
                }
                .padding(4).glassSurface(Capsule())
                Spacer(minLength: 0)
                item("Search", "magnifyingglass", 2, iconOnly: true)
                    .padding(4).glassSurface(Circle())
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 4)
        .accessibilityElement(children: .contain).accessibilityIdentifier("bottom-nav")
    }
    private func item(_ title: String, _ symbol: String, _ tag: Int, iconOnly: Bool = false) -> some View {
        let on = selection == tag
        return Button { selection = tag } label: {
            Group {
                if iconOnly { Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).frame(width: 52, height: 52) }
                else { VStack(spacing: 2) { Image(systemName: symbol).font(.system(size: 20, weight: .semibold)); Text(title).font(.caption2) }.frame(minWidth: 84, minHeight: 52) }
            }
            .foregroundStyle(on ? Theme.green : .primary)
            .background(on ? Theme.green.opacity(0.16) : .clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityIdentifier("tab-\(title)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if #available(iOS 26, *) { GlassEffectContainer(spacing: 12) { content } } else { content }
    }
}
extension View {
    /// One glass surface per control (native Liquid Glass on iOS 26+, material before).
    @ViewBuilder func glassSurface<S: Shape>(_ s: S) -> some View {
        if #available(iOS 26, *) { glassEffect(.regular.interactive(), in: s) } else { background(.ultraThinMaterial, in: s) }
    }
    /// Hides the bottom nav while this screen is on screen (restored on pop, button or edge swipe).
    func hidesBottomNav() -> some View { modifier(HideBottomNav()) }
}
private struct HideBottomNav: ViewModifier {
    @Environment(AppEnvironment.self) private var env
    @State private var counted = false
    func body(content: Content) -> some View {
        content
            .onAppear { if !counted { counted = true; env.bottomNavHiders += 1 } }
            .onDisappear { if counted { counted = false; env.bottomNavHiders -= 1 } }
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
        navigationDestination(for: SettingsRoute.self) { _ in SettingsScreen() }
            .navigationDestination(for: NetworkRoute.self) { MemberListScreen(route: $0) }
            .navigationDestination(for: ListRoute.self) { ListDetailScreen(list: $0.list) }
            .navigationDestination(for: MemberRoute.self) { ProfileScreen(memberUsername: $0.username) }
            .navigationDestination(for: Credit.self) { PersonScreen(credit: $0) }
    }
}
