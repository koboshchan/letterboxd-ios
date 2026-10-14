import SwiftUI
import LetterboxdKit

@main
struct LetterboxdApp: App {
    @State private var env = AppEnvironment.make()
    @State private var account = AccountModel()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(account)
                .preferredColorScheme(.dark)
                .tint(Theme.green)
        }
    }
}

enum Theme {
    static let green = Color(red: 0, green: 0.878, blue: 0.329)       // #00E054
    static let orange = Color(red: 1, green: 0.5, blue: 0.0)
    static let blue = Color(red: 0.25, green: 0.74, blue: 0.96)
    static let card = Color(white: 0.09)
    static let hairline = Color.white.opacity(0.1)
}

/// Holds the replaceable data layer. Live is the default; fixtures only via the explicit launch argument.
@Observable @MainActor
final class AppEnvironment {
    let service: LetterboxdService
    let isFixtureMode: Bool
    var username = "koboshchan"
    /// Launch-argument hooks for deterministic screenshots only (-UITab N, -UISegment N, -UIFilm slug).
    static func arg(_ k: String) -> String? { let a = ProcessInfo.processInfo.arguments; return a.firstIndex(of: k).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } }
    init(service: LetterboxdService, fixture: Bool) { self.service = service; self.isFixtureMode = fixture }
    static func make() -> AppEnvironment {
        if ProcessInfo.processInfo.arguments.contains("-UIFixtureMode") { return AppEnvironment(service: FixtureService(), fixture: true) }
        return AppEnvironment(service: PublicWebService(), fixture: false)
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var browsePath: [FilmSummary] = AppEnvironment.arg("-UIFilm").map { [FilmSummary(slug: $0, title: AppEnvironment.arg("-UIFilmTitle") ?? $0, year: nil)] } ?? []
    @State private var showSignIn = ProcessInfo.processInfo.arguments.contains("-UISignIn")
    @State private var selection = Int(AppEnvironment.arg("-UITab") ?? "0") ?? 0
    var body: some View {
        TabView(selection: $selection) {
            Tab("Profile", systemImage: "person.crop.circle", value: 0) { NavigationStack { ProfileScreen().fixtureBanner(env.isFixtureMode).toolbar { AccountButton(showSignIn: $showSignIn) } } }
            Tab("Browse", systemImage: "film.stack", value: 1) { NavigationStack(path: $browsePath) { BrowseScreen().fixtureBanner(env.isFixtureMode) } }
            Tab("Search", systemImage: "magnifyingglass", value: 2, role: .search) { NavigationStack { SearchScreen().fixtureBanner(env.isFixtureMode) } }
            Tab("About", systemImage: "info.circle", value: 3) { NavigationStack { AboutScreen() } }
        }
        .background(Color.black)
        .sheet(isPresented: $showSignIn) { SignInScreen() }
    }
}

extension View {
    func fixtureBanner(_ on: Bool) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            if on {
                Text("FIXTURE DATA - UI TEST MODE, NOT LIVE")
                    .font(.caption2.weight(.bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 3).background(Theme.orange)
            }
        }
    }
}
