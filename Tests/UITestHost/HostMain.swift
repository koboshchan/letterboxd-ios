import SwiftUI
import LetterboxdKit

/// UI-test host ONLY (separate target, never shipped). Same views as the app; data comes from MockService and an
/// injected homepage fetcher, so no network write and no shipped demo/guest mode exists.
@main
struct HostApp: App {
    @State private var env: AppEnvironment
    @State private var account: AccountModel
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue
    init() {
        let sc = Scenario(ProcessInfo.processInfo.arguments)
        let auth = AuthAuthority()
        let e = AppEnvironment(service: MockService(sc), auth: auth)
        let a = ProcessInfo.processInfo.arguments
        let wm = a.firstIndex(of: "-WriteMode").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil }.flatMap(MockFilmActions.Mode.init(rawValue:)) ?? .ok
        e.actions = MockFilmActions(mode: wm, auth: auth)
        e.account = MockAccountEditing(mode: wm, auth: auth)
        e.clearCaches = { await HostCacheProbe.shared.clear() }
        let store = InMemorySessionStore()
        if sc.storedSession { try? store.save(Session(username: "tester", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")])) }
        let counter = Counter()
        let m = AccountModel(store: store) { _ in
            let n = counter.next()
            if sc.offlineFirst && n == 1 { throw URLError(.notConnectedToInternet) }
            if sc.guestHomepage { return (200, "<script>person.loggedIn = false</script>") }
            return (200, "<script>person.username = \"tester\";\nperson.loggedIn = true;</script>")
        }
        m.auth = auth
        m.onUsernameChange = { [e] u in e.bind(username: u) }
        _env = State(initialValue: e); _account = State(initialValue: m)
    }
    var body: some Scene {
        WindowGroup {
            RootView().environment(env).environment(account).tint(Theme.green)
                .preferredColorScheme(AppearanceChoice.resolve(appearance).scheme)
                .task { await account.restore() }
        }
    }
}

final class Counter: @unchecked Sendable { private let l = NSLock(); private var n = 0; func next() -> Int { l.lock(); defer { l.unlock() }; n += 1; return n } }

struct Scenario: Sendable {
    let storedSession: Bool, offlineFirst: Bool, guestHomepage: Bool, empty: Bool, failFirst: Bool
    init(_ a: [String]) {
        let s = a.firstIndex(of: "-Scenario").flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } ?? "ready"
        storedSession = s != "signedOut"
        offlineFirst = s == "offline"; guestHomepage = s == "guest"; empty = s == "empty"; failFirst = s == "failFirst"
    }
}

actor HostCacheProbe { static let shared = HostCacheProbe(); private(set) var clears = 0; func clear() async { try? await Task.sleep(nanoseconds: 300_000_000); clears += 1 } }
