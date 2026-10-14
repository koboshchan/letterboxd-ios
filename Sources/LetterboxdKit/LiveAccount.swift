import Foundation

/// A cookie as reported by the web view's cookie store.
public struct WebCookie: Codable, Sendable, Equatable {
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
    /// Cookies with no expiry (session cookies) are trusted at most this long after we stored them.
    public static let maxSessionCookieAge: TimeInterval = 30 * 86400
    /// Applicability to a request for https://letterboxd.com/ : a host-only cookie must be for exactly letterboxd.com;
    /// a domain cookie must be .letterboxd.com. www host-only cookies are never forwarded to the bare host. Path must be "/".
    static func applies(_ c: WebCookie) -> Bool {
        let d = c.domain.lowercased()
        return d == "letterboxd.com" || d == ".letterboxd.com"
    }
    /// Valid, unexpired, secure cookies that apply to https://letterboxd.com/, one per name. Identical duplicates collapse;
    /// differing duplicates are ambiguous and dropped; an ambiguous or missing/empty session cookie yields nil.
    public static func accept(_ cookies: [WebCookie], now: Date = Date(), storedAt: Date? = nil) -> [WebCookie]? {
        var groups: [String: [WebCookie]] = [:]
        for c in cookies {
            guard applies(c), c.secure, c.path == "/", !c.name.isEmpty, !c.value.isEmpty else { continue }
            let end = c.expires ?? (storedAt ?? now).addingTimeInterval(maxSessionCookieAge)
            guard end > now else { continue }
            groups[c.name, default: []].append(c)
        }
        var out: [WebCookie] = []
        for (_, g) in groups where Set(g.map(\.value)).count == 1 { out.append(g.max { ($0.expires ?? .distantFuture) < ($1.expires ?? .distantFuture) }!) }
        guard out.contains(where: { $0.name == sessionCookieName }) else { return nil }
        return out.sorted { $0.name < $1.name }
    }
}

/// Reads the explicit assignments the server emits on an authenticated homepage:
/// `person.username = "name"` and `person.loggedIn = true` (recorded fixture authenticated-identity.sanitized.html).
/// The guest default (`loggedIn: false` in an object literal) is not an assignment and is ignored.
/// Ambiguous input (several differing usernames, any false assignment, none true) returns nil.
public enum IdentityCheck {
    static let userRE = try! NSRegularExpression(pattern: #"person\.username\s*=\s*"([^"\n]+)""#)
    static let loggedRE = try! NSRegularExpression(pattern: #"person\.loggedIn\s*=\s*(true|false)\b"#)
    static func captures(_ re: NSRegularExpression, _ s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }
    public static func username(fromHomepage html: String) -> String? {
        let flags = captures(loggedRE, html)
        guard !flags.isEmpty, flags.allSatisfy({ $0 == "true" }) else { return nil }
        let names = Set(captures(userRE, html))
        guard names.count == 1, let n = names.first, (try? Validate.username(n)) != nil else { return nil }
        return n
    }
}

public typealias HomepageFetcher = @Sendable (Session) async throws -> (status: Int, html: String)

/// Native sign-in is not implemented (the form needs a Turnstile token only the site's page can produce).
/// Sign-in runs in an interactive web view; a session is stored ONLY after the server confirms the identity.
/// Writes are unverified and unsupported.
public final class LiveAccountService: AccountService, @unchecked Sendable {
    let store: SessionStore
    let fence = AuthFence()
    public init(store: SessionStore) { self.store = store }
    public func signIn(email: String, password: String) async throws -> Session { throw AuthError.verificationRequired }

    public func complete(cookies: [WebCookie], fetch: HomepageFetcher, now: Date = Date(), token: Int? = nil) async throws -> Session {
        let token = token ?? fence.begin()   // never tokenless: obsolete if logout/another operation starts during the await
        guard let jar = SessionCookies.accept(cookies, now: now, storedAt: now) else { throw AuthError.notSignedIn }
        let r = try await fetch(Session(username: "", cookies: jar, storedAt: now))
        guard r.status == 200, let name = IdentityCheck.username(fromHomepage: r.html) else { throw AuthError.notSignedIn }
        let s = Session(username: name, cookies: jar, storedAt: now)
        // Atomic with logout: the fence lock is held while saving, so a logout cannot interleave and an obsolete token persists nothing.
        guard try commit(token, { try store.save(s) }) else { throw AuthError.notSignedIn }
        return s
    }
    /// Launch-time restore: re-validates stored cookie attributes and re-confirms identity with the server.
    /// Invalid, expired or mismatched sessions are removed. A network failure keeps the stored session untouched.
    public func restore(fetch: HomepageFetcher, now: Date = Date(), token: Int? = nil) async throws -> Session? {
        let token = token ?? fence.begin()
        guard let s = try? store.load() else { _ = try commit(token, { try store.clear() }); return nil }
        guard let jar = SessionCookies.accept(s.cookies, now: now, storedAt: s.storedAt) else { _ = try commit(token, { try store.clear() }); return nil }
        let r = try await fetch(Session(username: s.username, cookies: jar, storedAt: s.storedAt))
        guard r.status == 200, let name = IdentityCheck.username(fromHomepage: r.html), name.lowercased() == s.username.lowercased() else {
            _ = try commit(token, { try store.clear() }); return nil
        }
        guard fence.isCurrent(token) else { return nil }
        return Session(username: name, cookies: jar, storedAt: s.storedAt)
    }
    /// Starts a restore/complete operation; any later begin/invalidate makes this token obsolete.
    public func beginOperation() -> Int { fence.begin() }
    /// Synchronously obsoletes every pending operation (call before any await on logout).
    public func invalidatePending() { fence.invalidate() }
    public func isCurrent(_ t: Int) -> Bool { fence.isCurrent(t) }
    /// Synchronous single commit boundary: invalidate + clear atomically, callable before any await.
    public func signOutNow() throws { try fence.invalidateAndPerform { try store.clear() } }
    public func signOut() async throws { try signOutNow() }
    private func commit(_ t: Int, _ body: () throws -> Void) throws -> Bool {
        return try fence.perform(t, body) != nil
    }
    public func setWatchlist(slug: String, on: Bool) async throws { throw AuthError.unsupported("Watchlist writes are not verified.") }
    public func createList(name: String, isPrivate: Bool) async throws -> URL { throw AuthError.unsupported("List writes are not verified.") }
    public func deleteList(_ url: URL) async throws { throw AuthError.unsupported("List writes are not verified.") }
}

/// Serializes session persistence with logout. perform() holds the lock while writing, so a stale token can never persist
/// and a logout (invalidate + clear) is totally ordered against any save.
public final class AuthFence: @unchecked Sendable {
    private let lock = NSLock(); private var epoch = 0
    public init() {}
    public func begin() -> Int { lock.lock(); defer { lock.unlock() }; epoch += 1; return epoch }
    public func invalidate() { lock.lock(); epoch += 1; lock.unlock() }
    public func isCurrent(_ t: Int?) -> Bool { lock.lock(); defer { lock.unlock() }; return t == nil || t == epoch }
    public func perform(_ t: Int, _ body: () throws -> Void) rethrows -> Void? { lock.lock(); defer { lock.unlock() }; guard t == epoch else { return nil }; try body(); return () }
    /// Logout: obsoletes every pending token AND clears under ONE lock acquisition, so no operation can begin+save in between.
    public func invalidateAndPerform(_ body: () throws -> Void) rethrows { enter(); lock.lock(); defer { lock.unlock() }; leave(); epoch += 1; try body() }
    private let cl = NSLock(); private var _waiting = 0
    private func enter() { cl.lock(); _waiting += 1; cl.unlock() }
    private func leave() { cl.lock(); _waiting -= 1; cl.unlock() }
    /// Test seam: number of callers currently blocked acquiring the fence.
    public var waiting: Int { cl.lock(); defer { cl.unlock() }; return _waiting }
    public func performAlways(_ body: () throws -> Void) rethrows { lock.lock(); defer { lock.unlock() }; try body() }
}
