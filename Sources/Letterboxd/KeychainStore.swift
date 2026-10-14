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
    private func check(_ st: OSStatus) throws { guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) } }
    func save(_ s: Session) throws {
        let data = try JSONEncoder().encode(s)
        let st = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if st == errSecItemNotFound {
            try check(SecItemAdd(q.merging([kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]) { $1 } as CFDictionary, nil))
        } else { try check(st) }
    }
    func clear() throws { let st = SecItemDelete(q as CFDictionary); if st != errSecItemNotFound { try check(st) } }
}
