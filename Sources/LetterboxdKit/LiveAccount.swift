import Foundation

/// Cookies carried from an interactive web sign-in. Strict origin validation; values never logged or put in URLs.
public enum SessionCookies {
    public static let sessionCookieName = "letterboxd.user.CURRENT"
    /// Keeps only cookies for letterboxd.com / *.letterboxd.com. Returns nil unless the signed-in session cookie is present.
    public static func accept(_ cookies: [(name: String, value: String, domain: String)], username: String) -> Session? {
        var jar: [String: String] = [:]
        for c in cookies {
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            guard d == "letterboxd.com" || d.hasSuffix(".letterboxd.com") else { continue }
            jar[c.name] = c.value
        }
        guard jar[sessionCookieName] != nil, (try? Validate.username(username)) != nil else { return nil }
        return Session(username: username, cookies: jar)
    }
}

/// Native sign-in is NOT implemented: the current form appends a Turnstile captchaResponse/captchaAction that only the
/// site's own page can produce, and we never bypass or fabricate it. Sign-in happens in an interactive web view; this
/// service stores the resulting session and reports the typed blocker otherwise. Writes are unverified and unsupported.
public final class LiveAccountService: AccountService, @unchecked Sendable {
    let store: SessionStore
    public init(store: SessionStore) { self.store = store }
    public func signIn(email: String, password: String) async throws -> Session { throw AuthError.verificationRequired }
    public func complete(username: String, cookies: [(name: String, value: String, domain: String)]) throws -> Session {
        guard let s = SessionCookies.accept(cookies, username: username) else { throw AuthError.notSignedIn }
        try store.save(s); return s
    }
    public func signOut() async throws { try store.clear() }
    public func setWatchlist(slug: String, on: Bool) async throws { throw AuthError.unsupported("Watchlist writes are not verified.") }
    public func createList(name: String, isPrivate: Bool) async throws -> URL { throw AuthError.unsupported("List writes are not verified.") }
    public func deleteList(_ url: URL) async throws { throw AuthError.unsupported("List writes are not verified.") }
}
