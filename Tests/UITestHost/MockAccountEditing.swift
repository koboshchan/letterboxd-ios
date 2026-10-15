import Foundation
import LetterboxdKit

/// UI-test mock of the production AccountEditingClient. Holds a pretend server; no network. The mode reuses -WriteMode.
final class MockAccountEditing: AccountEditingClient, @unchecked Sendable {
    let mode: MockFilmActions.Mode, auth: AuthAuthority
    private let l = NSLock()
    private var profile = ProfileFields(givenName: "Tester", familyName: "", location: "Vancouver", website: "", bio: "Hello bio")
    private(set) var lists: [String] = []
    init(mode: MockFilmActions.Mode, auth: AuthAuthority) { self.mode = mode; self.auth = auth }
    func loadProfile() async throws -> ProfileFields {
        if mode == .loadfail { throw LetterboxdError.http(status: 500) }
        return l.withLock { profile }
    }
    func saveProfile(_ f: ProfileFields) async throws -> ProfileFields {
        switch mode {
        case .fail: throw LetterboxdError.http(status: 500)
        case .mismatch: throw LetterboxdError.parse("profile readback mismatch")
        case .slow: try await Task.sleep(nanoseconds: 1_500_000_000)
        case .logout: auth.revoke()
        default: break
        }
        l.withLock { profile = f }; return f
    }
    func createPrivateList(name: String, description: String) async throws -> CreatedList {
        switch mode {
        case .fail: throw LetterboxdError.http(status: 500)
        case .slow: try await Task.sleep(nanoseconds: 1_500_000_000)
        case .logout: auth.revoke()
        default: break
        }
        l.withLock { lists.append(name) }
        return CreatedList(id: "Mock1", name: name.trimmingCharacters(in: .whitespacesAndNewlines), isPrivate: true)
    }
}
