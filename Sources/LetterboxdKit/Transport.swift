import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResult: Sendable { public let data: Data; public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status } }

/// Replaceable transport. Only GET exists by design: the app is read-only.
public protocol HTTPTransport: Sendable {
    func get(_ url: URL, accept: String) async throws -> HTTPResult
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        self.session = URLSession(configuration: c)
    }
    public func get(_ url: URL, accept: String) async throws -> HTTPResult {
        var r = URLRequest(url: try Validate.url(url))
        r.httpMethod = "GET"
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("LetterboxdReader/0.1 (read-only personal client; user-triggered)", forHTTPHeaderField: "User-Agent")
        do {
            let (d, resp) = try await session.data(for: r)
            return HTTPResult(data: d, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError { throw LetterboxdError.cancelled
        } catch let e as URLError where e.code == .cancelled { throw LetterboxdError.cancelled
        } catch { throw LetterboxdError.network(error.localizedDescription) }
    }
}

public enum BlockDetector {
    /// Detects Cloudflare-style challenge/denial pages. We never try to get past them.
    public static func check(_ r: HTTPResult) throws {
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
    private var store: [URL: Entry] = [:]
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    public init(ttl: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() }) { self.ttl = ttl; self.now = now }
    public func get(_ u: URL) -> Data? {
        guard let e = store[u], now().timeIntervalSince(e.at) < ttl else { store[u] = nil; return nil }
        return e.data
    }
    public func set(_ u: URL, _ d: Data) { store[u] = Entry(data: d, at: now()) }
    public func clear() { store.removeAll() }
}

public final class Fetcher: Sendable {
    let transport: HTTPTransport
    let cache: ResponseCache
    public init(transport: HTTPTransport = URLSessionTransport(), cache: ResponseCache = ResponseCache()) {
        self.transport = transport; self.cache = cache
    }
    /// forceRefresh is used by pull-to-refresh (a user action) and bypasses the cache.
    public func text(_ url: URL, accept: String = "text/html", forceRefresh: Bool = false) async throws -> String {
        try Task.checkCancellation()
        let u = try Validate.url(url)
        if !forceRefresh, let d = await cache.get(u) { return String(decoding: d, as: UTF8.self) }
        let r = try await transport.get(u, accept: accept)
        try Task.checkCancellation()
        try BlockDetector.check(r)
        await cache.set(u, r.data)
        return String(decoding: r.data, as: UTF8.self)
    }
}
