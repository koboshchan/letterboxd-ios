import Foundation

/// Opaque authenticated session. Never logged, never persisted outside a SessionStore.
public struct Session: Codable, Sendable, Equatable {
    public let username: String
    public let cookies: [WebCookie]   // full attributes; secret values
    public let storedAt: Date
    public init(username: String, cookies: [WebCookie], storedAt: Date = Date()) { self.username = username; self.cookies = cookies; self.storedAt = storedAt }
    /// Cookie header for https://letterboxd.com/ from unexpired cookies only (session cookies bounded by storedAt + max age).
    public func header(now: Date = Date()) -> String {
        cookies.filter { ($0.expires ?? storedAt.addingTimeInterval(SessionCookies.maxSessionCookieAge)) > now }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Secure persistence abstraction. App provides a Keychain implementation; tests use memory.
public protocol SessionStore: Sendable {
    func load() throws -> Session?
    func save(_ s: Session) throws
    func clear() throws
}

public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock(); private var s: Session?
    public init() {}
    public func load() throws -> Session? { lock.lock(); defer { lock.unlock() }; return s }
    public func save(_ x: Session) throws { lock.lock(); s = x; lock.unlock() }
    public func clear() throws { lock.lock(); s = nil; lock.unlock() }
}

public enum AuthError: Error, Equatable, Sendable { case unsupported(String), badCredentials, verificationRequired, notSignedIn }

/// Authenticated capabilities. Sessions come only from the interactive web sign-in (see LiveAccountService); native
/// password sign-in, two-factor (TOTP) entry, and all writes are unsupported because their requests were never verified.
public protocol AccountService: Sendable {
    func signIn(email: String, password: String) async throws -> Session
    func signOut() async throws
    func setWatchlist(slug: String, on: Bool) async throws
    func createList(name: String, isPrivate: Bool) async throws -> URL
    func deleteList(_ url: URL) async throws
}

public struct UnavailableAccountService: AccountService {
    public init() {}
    private var err: AuthError {  AuthError.unsupported("Sign-in and editing are unavailable: Letterboxd's authenticated endpoints have not been verified.") }
    public func signIn(email: String, password: String) async throws -> Session { throw err }
    public func signOut() async throws {}
    public func setWatchlist(slug: String, on: Bool) async throws { throw err }
    public func createList(name: String, isPrivate: Bool) async throws -> URL { throw err }
    public func deleteList(_ url: URL) async throws { throw err }
}
