import Foundation

/// A cookie as reported by the web view's cookie store.
public struct WebCookie: Sendable, Equatable {
    public let name, value, domain, path: String
    public let expires: Date?     // nil = session cookie
    public let secure: Bool
    public init(name: String, value: String, domain: String, path: String = "/", expires: Date? = nil, secure: Bool = true) {
        self.name = name; self.value = value; self.domain = domain; self.path = path; self.expires = expires; self.secure = secure
    }
}

/// Which URLs the sign-in web view may load. Main frame: https, exactly letterboxd.com or www.letterboxd.com.
/// Subframes may additionally load the Turnstile challenge host. No http, no other subdomains, no other schemes.
public enum NavigationPolicy {
    static let mainHosts: Set<String> = ["letterboxd.com", "www.letterboxd.com"]
    static let frameHosts: Set<String> = mainHosts.union(["challenges.cloudflare.com"])
    public static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return (mainFrame ? mainHosts : frameHosts).contains(host)
    }
}

public enum SessionCookies {
    public static let sessionCookieName = "letterboxd.user.CURRENT"
    static func hostMatches(_ domain: String) -> Bool {
        let d = domain.lowercased(); return d == "letterboxd.com" || d == ".letterboxd.com" || d == "www.letterboxd.com"
    }
    /// Keeps only valid, unexpired, secure, root-path cookies for the exact site hosts. Returns nil without the session cookie.
    public static func accept(_ cookies: [WebCookie], now: Date = Date()) -> [String: String]? {
        var jar: [String: String] = [:]
        for c in cookies {
            guard hostMatches(c.domain), c.secure, c.path == "/", !c.name.isEmpty, !c.value.isEmpty else { continue }
            if let e = c.expires, e <= now { continue }
            jar[c.name] = c.value
        }
        return jar[sessionCookieName] == nil ? nil : jar
    }
}

/// Server-side identity check. A signed-in page bootstraps `person = { username: "...", loggedIn: true ... }`; guests get
/// `username: "", loggedIn: false` (the guest form is observed in recorded pages; the signed-in form is NOT yet observed).
public enum IdentityCheck {
    public static func username(fromHomepage html: String) -> String? {
        guard let r = html.range(of: "person = {") else { return nil }
        let chunk = String(html[r.upperBound...].prefix(400))
        let compact = chunk.filter { !$0.isWhitespace }
        guard compact.contains("loggedIn:true"),
              let u = compact.range(of: "username:\"") else { return nil }
        let name = compact[u.upperBound...].prefix { $0 != "\"" }
        let s = String(name)
        return (try? Validate.username(s)) != nil ? s : nil
    }
}

public typealias HomepageFetcher = @Sendable ([String: String]) async throws -> (status: Int, html: String)

/// Native sign-in is not implemented (the form needs a Turnstile token only the site's page can produce).
/// Sign-in runs in an interactive web view; a session is stored ONLY after the server confirms the identity.
/// Writes are unverified and unsupported.
public final class LiveAccountService: AccountService, @unchecked Sendable {
    let store: SessionStore
    public init(store: SessionStore) { self.store = store }
    public func signIn(email: String, password: String) async throws -> Session { throw AuthError.verificationRequired }

    public func complete(cookies: [WebCookie], fetch: HomepageFetcher, now: Date = Date()) async throws -> Session {
        guard let jar = SessionCookies.accept(cookies, now: now) else { throw AuthError.notSignedIn }
        let r = try await fetch(jar)
        guard r.status == 200, let name = IdentityCheck.username(fromHomepage: r.html) else { throw AuthError.notSignedIn }
        let s = Session(username: name, cookies: jar)
        try store.save(s); return s
    }
    public func signOut() async throws { try store.clear() }
    public func setWatchlist(slug: String, on: Bool) async throws { throw AuthError.unsupported("Watchlist writes are not verified.") }
    public func createList(name: String, isPrivate: Bool) async throws -> URL { throw AuthError.unsupported("List writes are not verified.") }
    public func deleteList(_ url: URL) async throws { throw AuthError.unsupported("List writes are not verified.") }
}
