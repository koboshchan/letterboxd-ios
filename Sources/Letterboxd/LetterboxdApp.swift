import SwiftUI
import LetterboxdKit

@main
struct LetterboxdApp: App {
    @State private var env = AppEnvironment.make()
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
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
    init(service: LetterboxdService, fixture: Bool) { self.service = service; self.isFixtureMode = fixture }
    static func make() -> AppEnvironment {
        if ProcessInfo.processInfo.arguments.contains("-UIFixtureMode") { return AppEnvironment(service: FixtureService(), fixture: true) }
        return AppEnvironment(service: PublicWebService(), fixture: false)
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        TabView {
            Tab("Profile", systemImage: "person.crop.circle") { NavigationStack { ProfileScreen() }.fixtureBanner(env.isFixtureMode) }
            Tab("Browse", systemImage: "film.stack") { NavigationStack { BrowseScreen() }.fixtureBanner(env.isFixtureMode) }
            Tab("Search", systemImage: "magnifyingglass", role: .search) { NavigationStack { SearchScreen() }.fixtureBanner(env.isFixtureMode) }
            Tab("About", systemImage: "info.circle") { NavigationStack { AboutScreen() } }
        }
        .background(Color.black)
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
