import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResult: Sendable { public let data: Data; public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status } }

/// Replaceable transport. Only GET exists by design: the app is read-only.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, accept: String) async throws -> HTTPResult
    func send(_ request: WriteRequest) async throws -> HTTPResult
    func get(_ url: URL, accept: String, credentials: RequestCredentials) async throws -> HTTPResult
    func send(_ request: WriteRequest, credentials: RequestCredentials) async throws -> HTTPResult
}

/// Immutable originating session; never fetch a newer account's credentials during an operation.
public struct RequestCredentials: Sendable, Equatable {
    public let generation: Int
    let cookie: String
}
extension HTTPTransport {
    // Compatibility for injected transports that do not acquire credentials themselves.
    public func get(_ url: URL, accept: String, credentials: RequestCredentials) async throws -> HTTPResult { try await get(url, accept: accept) }
    public func send(_ request: WriteRequest, credentials: RequestCredentials) async throws -> HTTPResult { try await send(request) }
}

/// Redirect policy. Authenticated requests (carrying a Cookie) never follow ANY redirect, including 307/308, so
/// credentials cannot leave the original request; the 3xx is returned to the caller as an error status.
/// Unauthenticated requests may follow a redirect only to exact https letterboxd.com / www.letterboxd.com on port 443.
public enum RedirectPolicy {
    public static func isExactSiteURL(_ u: URL) -> Bool {
        u.scheme == "https" && (u.host == "letterboxd.com" || u.host == "www.letterboxd.com")
            && (u.port == nil || u.port == 443) && u.user == nil && u.password == nil
    }
    public static func allows(to new: URL, authenticated: Bool) -> Bool { !authenticated && isExactSiteURL(new) }
    /// The only URL an authenticated request may target: exact https://letterboxd.com on the default port.
    public static func mayCarryCredentials(_ u: URL) -> Bool {
        u.scheme == "https" && u.host == "letterboxd.com" && (u.port == nil || u.port == 443) && u.user == nil && u.password == nil
    }
}
final class RedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let authenticated: Bool
    /// Test seam: observes every redirect callback URLSession actually delivers (status, target, allowed).
    let observer: (@Sendable (Int, URL?, Bool) -> Void)?
    /// Test seam ONLY (negative control): false makes the delegate follow redirects unchanged. Always true in the app.
    let enforce: Bool
    /// Test seam: replaces the exact-site predicate so a loopback server can stand in for letterboxd.com. nil in the app.
    let siteCheck: (@Sendable (URL) -> Bool)?
    init(authenticated: Bool, observer: (@Sendable (Int, URL?, Bool) -> Void)? = nil, enforce: Bool = true, siteCheck: (@Sendable (URL) -> Bool)? = nil) { self.authenticated = authenticated; self.observer = observer; self.enforce = enforce; self.siteCheck = siteCheck }
    func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? {
        guard enforce else { observer?(response.statusCode, newRequest.url, true); return newRequest }
        let ok = newRequest.url.map { u in siteCheck.map { !authenticated && $0(u) } ?? RedirectPolicy.allows(to: u, authenticated: authenticated) } ?? false
        observer?(response.statusCode, newRequest.url, ok)
        guard ok else { return nil }
        var r = newRequest
        for h in ["Cookie", "Authorization", "X-CSRF-Token", "X-Requested-With"] { r.setValue(nil, forHTTPHeaderField: h) }
        return r
    }
}

public struct URLSessionTransport: HTTPTransport {
    let configuration: URLSessionConfiguration
    let cookieHeader: (@Sendable () -> String?)?
    let redirectObserver: (@Sendable (Int, URL?, Bool) -> Void)?
    let enforceRedirectPolicy: Bool
    var testSite: (@Sendable (URL) -> Bool)? = nil
    /// cookieHeader (optional) is attached ONLY to https://letterboxd.com requests, for the signed-in account.
    public init(configuration: URLSessionConfiguration? = nil, cookieHeader: (@Sendable () -> String?)? = nil) {
        self.init(configuration: configuration, cookieHeader: cookieHeader, observer: nil, enforce: true)
    }
    init(configuration: URLSessionConfiguration?, cookieHeader: (@Sendable () -> String?)?, observer: (@Sendable (Int, URL?, Bool) -> Void)?, enforce: Bool) {
        self.redirectObserver = observer; self.enforceRedirectPolicy = enforce
        self.cookieHeader = cookieHeader
        let c = configuration ?? URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        self.configuration = c
    }
    public func get(_ url: URL, accept: String) async throws -> HTTPResult {
        try await get(url, accept: accept, cookie: cookieHeader?())
    }
    public func get(_ url: URL, accept: String, credentials: RequestCredentials) async throws -> HTTPResult {
        try await get(url, accept: accept, cookie: credentials.cookie)
    }
    private func get(_ url: URL, accept: String, cookie: String?) async throws -> HTTPResult {
        var r = URLRequest(url: testSite == nil ? try Validate.url(url) : url)
        r.httpMethod = "GET"
        r.setValue(accept, forHTTPHeaderField: "Accept")
        var authenticated = false
        if let h = cookie, !h.isEmpty, let u = r.url, testSite.map({ $0(u) }) ?? RedirectPolicy.mayCarryCredentials(u) { r.setValue(h, forHTTPHeaderField: "Cookie"); authenticated = true }
        r.setValue("LetterboxdReader/0.1 (read-only personal client; user-triggered)", forHTTPHeaderField: "User-Agent")
        do {
            let (d, resp) = try await { () async throws -> (Data, URLResponse) in
                // Session-level delegate (per request): redirect handling is enforced on every platform.
                let s = URLSession(configuration: configuration, delegate: RedirectGuard(authenticated: authenticated, observer: redirectObserver, enforce: enforceRedirectPolicy, siteCheck: testSite), delegateQueue: nil)
                defer { s.finishTasksAndInvalidate() }
                return try await s.data(for: r, delegate: RedirectGuard(authenticated: authenticated, observer: redirectObserver, enforce: enforceRedirectPolicy, siteCheck: testSite))
            }()
            return HTTPResult(data: d, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError { throw LetterboxdError.cancelled
        } catch let e as URLError where e.code == .cancelled { throw LetterboxdError.cancelled
        } catch { throw LetterboxdError.network(error.localizedDescription) }
    }
}

public enum BlockDetector {
    /// Detects Cloudflare-style challenge/denial pages. We never try to get past them.
    public static func check(_ r: HTTPResult) throws {
        if (300..<400).contains(r.status) { throw LetterboxdError.http(status: r.status) }
        if r.status == 404 { throw LetterboxdError.notFound }
        if r.status == 403 || r.status == 429 || r.status == 503 { throw LetterboxdError.blocked(status: r.status) }
        if r.status >= 400 { throw LetterboxdError.http(status: r.status) }
        let head = String(decoding: r.data.prefix(4096), as: UTF8.self)
        if head.contains("Just a moment...") || head.contains("challenges.cloudflare.com") { throw LetterboxdError.blocked(status: r.status) }
    }
}

/// Small TTL cache with in-flight de-duplication so repeated taps never re-request.
public actor ResponseCache {
    private struct Entry { let data: Data; let at: Date }
    private struct Key: Hashable { let url: URL; let partition: Int }
    private var store: [Key: Entry] = [:]
    private var epoch = 0
    public func currentEpoch() -> Int { epoch }
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    /// Test seams: run inside the actor just before get/set return, i.e. in the window where Fetcher is suspended.
    var afterGet: (@Sendable () -> Void)?; var afterSet: (@Sendable () -> Void)?
    func installHooks(get: (@Sendable () -> Void)?, set: (@Sendable () -> Void)?) { afterGet = get; afterSet = set }
    public init(ttl: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() }) { self.ttl = ttl; self.now = now }
    public func get(_ u: URL, partition: Int = 0) -> Data? {
        let k = Key(url: u, partition: partition)
        guard let e = store[k], now().timeIntervalSince(e.at) < ttl else { store[k] = nil; return nil }
        afterGet?(); return e.data
    }
    public func set(_ u: URL, _ d: Data, partition: Int = 0, epoch e: Int? = nil) { if let e, e != epoch { return }; store[Key(url: u, partition: partition)] = Entry(data: d, at: now()); afterSet?() }
    /// Purge and fence: a response that started before this call can no longer be stored.
    public func clear() { epoch += 1; store.removeAll() }
}

/// The ONLY source of credentials for requests. Holds the in-memory, server-validated session (never the raw Keychain).
/// Every change (sign-in, restore, sign-out, revoke) bumps `generation`; caches are partitioned by it and any response
/// that started under an older generation is discarded, so nothing from a previous account state is cached or shown.
public final class AuthAuthority: @unchecked Sendable {
    private let lock = NSLock()
    private var session: Session?
    private var gen = 0
    private var observers: [@Sendable () -> Void] = []
    private var purgeHooks: [@Sendable () -> Void] = []
    public init() {}
    /// Purge hooks run INSIDE the auth lock, BEFORE the new session/generation is published, so no reader can see the new
    /// state while old private data is still reachable. Lock order is auth -> hook; a hook MUST NOT call back into this
    /// AuthAuthority (it would deadlock). Overlapping transitions are serialized by the lock, so they cannot interleave.
    public func addPurgeHook(_ f: @escaping @Sendable () -> Void) { lock.lock(); purgeHooks.append(f); lock.unlock() }
    /// Username and generation read atomically, so a namespace can never be paired with another account's generation.
    public func snapshot() -> (username: String?, generation: Int) { lock.lock(); defer { lock.unlock() }; return (session?.username, gen) }
    public func requestCredentials(now: Date = Date()) throws -> RequestCredentials {
        lock.lock(); defer { lock.unlock() }
        guard let h = session?.header(now: now), !h.isEmpty else { throw AuthError.notSignedIn }
        return RequestCredentials(generation: gen, cookie: h)
    }
    /// Called synchronously, inside the auth change itself, on sign-in/restore/sign-out/revoke.
    public func onChange(_ f: @escaping @Sendable () -> Void) { lock.lock(); observers.append(f); lock.unlock() }
    private func notify() { lock.lock(); let o = observers; lock.unlock(); o.forEach { $0() } }
    public var generation: Int { lock.lock(); defer { lock.unlock() }; return gen }
    public var username: String? { lock.lock(); defer { lock.unlock() }; return session?.username }
    /// Call only after the server confirmed this session.
    public func setValidated(_ s: Session) { lock.lock(); purgeHooks.forEach { $0() }; session = s; gen += 1; lock.unlock(); notify() }
    /// Bumps the generation only if a session was actually held (a no-op revoke must not disturb in-flight guest loads).
    public func revoke() { lock.lock(); let had = session != nil; if had { purgeHooks.forEach { $0() }; session = nil; gen += 1 }; lock.unlock(); if had { notify() } }
    /// Cookie header or nil (nil = send no credentials). Expired cookies are never included.
    public func cookieHeader(now: Date = Date()) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let h = session?.header(now: now), !h.isEmpty else { return nil }
        return h
    }
}

public final class Fetcher: Sendable {
    let transport: HTTPTransport
    let cache: ResponseCache
    let auth: AuthAuthority
    public init(transport: HTTPTransport = URLSessionTransport(), cache: ResponseCache = ResponseCache(), auth: AuthAuthority = AuthAuthority()) {
        self.transport = transport; self.cache = cache; self.auth = auth
    }
    public func clearCache() async { await cache.clear() }
    /// forceRefresh is used by pull-to-refresh (a user action) and bypasses the cache.
    public func text(_ url: URL, accept: String = "text/html", forceRefresh: Bool = false) async throws -> String {
        try Task.checkCancellation()
        let u = try Validate.url(url)
        let g = auth.generation
        let ce = await cache.currentEpoch()
        if !forceRefresh, let d = await cache.get(u, partition: g) {
            guard await cache.currentEpoch() == ce, auth.generation == g else { throw LetterboxdError.cancelled }
            return String(decoding: d, as: UTF8.self)
        }
        let r = try await transport.get(u, accept: accept)
        try Task.checkCancellation()
        // Auth state changed while in flight: drop the response, never cache or render it.
        guard auth.generation == g else { throw LetterboxdError.cancelled }
        try BlockDetector.check(r)
        await cache.set(u, r.data, partition: g, epoch: ce)
        guard await cache.currentEpoch() == ce, auth.generation == g else { throw LetterboxdError.cancelled }
        return String(decoding: r.data, as: UTF8.self)
    }
}
