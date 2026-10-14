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
                .tint(Theme.green)
                .task { account.auth = env.auth; account.onUsernameChange = { [env] u in env.bind(username: u) }; await account.restore() }
        }
    }
}
