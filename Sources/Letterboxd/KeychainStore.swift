import Foundation
import Security
import LetterboxdKit

/// Session lives only in the Keychain (this-device-only), never UserDefaults.
struct KeychainSessionStore: SessionStore {
    private let service = "com.koboshchan.letterboxdreader.session"
    private var q: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "session"] }
    func load() throws -> Session? {
        var r: CFTypeRef?
        let st = SecItemCopyMatching(q.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &r)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = r as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        return try JSONDecoder().decode(Session.self, from: d)
    }
    func save(_ s: Session) throws {
        try clear()
        let st = SecItemAdd(q.merging([kSecValueData as String: try JSONEncoder().encode(s), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 } as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
    }
    func clear() throws { SecItemDelete(q as CFDictionary) }
}
