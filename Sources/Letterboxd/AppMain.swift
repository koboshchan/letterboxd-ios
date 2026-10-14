import SwiftUI
import LetterboxdKit

@main
struct LetterboxdApp: App {
    @State private var env = AppEnvironment.make()
    @State private var account = AccountModel()
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system.rawValue
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(env)
                .environment(account)
                .tint(Theme.green)
                .preferredColorScheme(AppearanceChoice.resolve(appearance).scheme)
                .task { account.auth = env.auth; account.onUsernameChange = { [env] u in env.bind(username: u) }; await account.restore() }
        }
    }
}
