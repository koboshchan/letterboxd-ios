import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public-image byte cache: bounded disk store + in-flight coalescing + TTL (stale-while-revalidate).
/// Account-neutral on purpose: it only ever holds public CDN images, requested with NO cookies, NO auth headers and NO
/// custom headers, so nothing here can carry credentials or private state. Private read data never goes through it.
public actor ImageStore {
    public static let allowedHosts: Set<String> = ["a.ltrbxd.com", "s.ltrbxd.com", "image.tmdb.org"]
    public typealias Loader = @Sendable (URL) async throws -> Data

    /// Only https, exact allowed host, default port, no userinfo, no fragment.
    public static func validate(_ u: URL) -> URL? {
        guard u.scheme == "https", let h = u.host?.lowercased(), allowedHosts.contains(h), u.port == nil,
              u.user == nil, u.password == nil, u.fragment == nil, u.absoluteString.count <= 512 else { return nil }
        return u
    }

    private struct Meta: Codable { var url: String; var at: Date; var last: Date; var size: Int }
    private let dir: URL?
    private let ttl: TimeInterval
    private let maxBytes: Int
    private let maxMaxBytesMemory: Int
    private let now: @Sendable () -> Date
    private let load: Loader
    private var index: [String: Meta] = [:]
    private var total = 0
    private var epoch = 0
    private var inflight: [String: Task<Data, Error>] = [:]
    private var memory: [String: Data] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
    private var memoryStamp: [String: Date] = [:]
    public private(set) var networkFetches = 0   // deterministic counter for tests/diagnostics

    /// dir nil = memory only (fail closed when storage can't be prepared).
    public init(directory: URL?, ttl: TimeInterval = 7 * 86400, maxBytes: Int = 100 << 20, memoryBytes: Int = 24 << 20,
                now: @escaping @Sendable () -> Date = { Date() }, loader: @escaping Loader = ImageStore.networkLoader) {
        self.ttl = ttl; self.maxBytes = maxBytes; self.maxMaxBytesMemory = memoryBytes; self.now = now; self.load = loader
        var d = directory
        if let dd = d {
            do {
                try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true, attributes: nil)
                var v = URLResourceValues(); v.isExcludedFromBackup = true
                var m = dd; try? m.setResourceValues(v)
                #if canImport(Darwin)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dd.path)
                #endif
            } catch { d = nil }
        }
        self.dir = d
        if let d { (index, total) = Self.scan(d) }
    }

    /// Cookie-less, header-less fetch on an ephemeral session; redirects off the allowed hosts are refused.
    public static let networkLoader: Loader = { url in
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCredentialStorage = nil; c.urlCache = nil
        c.timeoutIntervalForRequest = 20
        let s = URLSession(configuration: c, delegate: HostGuard(), delegateQueue: nil)
        defer { s.finishTasksAndInvalidate() }
        var r = URLRequest(url: url); r.httpShouldHandleCookies = false
        let (d, resp) = try await s.data(for: r)
        guard let h = resp as? HTTPURLResponse, h.statusCode == 200, d.count > 0, d.count <= 10 << 20 else { throw LetterboxdError.network("image") }
        return d
    }
    final class HostGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest q: URLRequest) async -> URLRequest? {
            q.url.flatMap(ImageStore.validate) == nil ? nil : q
        }
    }

    /// Cached bytes immediately (memory, then disk) even if past TTL; refreshes stale entries in the background.
    /// A miss fetches once; concurrent callers for the same URL share one request.
    public func data(for raw: URL) async throws -> Data {
        guard let url = Self.validate(raw) else { throw LetterboxdError.invalidInput("image host") }
        let key = Self.key(url)
        if let hit = readLocal(key, url) {
            if now().timeIntervalSince(hit.at) >= ttl { startFetch(key, url) }   // stale: show now, refresh quietly
            return hit.data
        }
        let t = startFetch(key, url)
        return try await t.value
    }

    /// Prefetch: same path, errors ignored, never throws.
    public func prefetch(_ url: URL) async { _ = try? await data(for: url) }

    public func cached(_ raw: URL) -> Data? {
        guard let url = Self.validate(raw) else { return nil }
        return readLocal(Self.key(url), url)?.data
    }

    public func clear() {
        epoch += 1
        inflight.values.forEach { $0.cancel() }; inflight = [:]
        memory = [:]; memoryOrder = []; memoryBytes = 0
        if let dir { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        index = [:]; total = 0
    }
    public var diskBytes: Int { total }
    public var diskCount: Int { index.count }

    @discardableResult
    private func startFetch(_ key: String, _ url: URL) -> Task<Data, Error> {
        if let t = inflight[key] { return t }
        networkFetches += 1
        let loader = load; let ep = epoch
        let t = Task<Data, Error> { [weak self] in
            do {
                let d = try await loader(url)
                await self?.finish(key, url, .success(d), ep)   // stored and de-registered BEFORE any waiter resumes
                return d
            } catch {
                await self?.finish(key, url, .failure(error), ep)
                throw error
            }
        }
        inflight[key] = t
        return t
    }
    private func finish(_ key: String, _ url: URL, _ r: Result<Data, Error>, _ ep: Int) {
        guard ep == epoch else { return }   // cleared while in flight: never resurrect purged data
        inflight[key] = nil
        if case .success(let d) = r { store(key, url, d) }
    }

    // MARK: storage
    private func readLocal(_ key: String, _ url: URL) -> (data: Data, at: Date)? {
        if let m = memory[key], let meta = index[key], meta.url == url.absoluteString { touch(key); return (m, meta.at) }
        if let m = memory[key], dir == nil { return (m, memoryStamp[key] ?? now()) }
        guard let dir, var meta = index[key], meta.url == url.absoluteString,
              let d = try? Data(contentsOf: dir.appendingPathComponent(key)), d.count == meta.size else {
            if index[key] != nil { drop(key) }
            return nil
        }
        meta.last = now(); index[key] = meta
        remember(key, d)
        return (d, meta.at)
    }
    private func touch(_ key: String) { index[key]?.last = now() }
    private func remember(_ key: String, _ d: Data) {
        guard d.count <= maxMaxBytesMemory / 4 else { return }
        if memory[key] == nil { memoryBytes += d.count; memoryOrder.append(key) }
        memory[key] = d; memoryStamp[key] = now()
        while memoryBytes > maxMaxBytesMemory, let old = memoryOrder.first {
            memoryOrder.removeFirst(); if let o = memory.removeValue(forKey: old) { memoryBytes -= o.count }
        }
    }
    private func store(_ key: String, _ url: URL, _ d: Data) {
        remember(key, d)
        guard let dir, d.count <= maxBytes / 4 else { return }
        do {
            try d.write(to: dir.appendingPathComponent(key), options: .atomic)
        } catch { return }   // storage failure: memory only, never a crash
        if let old = index[key] { total -= old.size }
        index[key] = Meta(url: url.absoluteString, at: now(), last: now(), size: d.count); total += d.count
        persistIndex()
        evict()
    }
    private func evict() {
        guard total > maxBytes else { return }
        for (k, _) in index.sorted(by: { $0.value.last < $1.value.last }) {
            if total <= maxBytes * 9 / 10 { break }
            drop(k)
        }
        persistIndex()
    }
    private func drop(_ key: String) {
        if let m = index.removeValue(forKey: key) { total -= m.size }
        if let m = memory.removeValue(forKey: key) { memoryBytes -= m.count; memoryOrder.removeAll { $0 == key } }
        if let dir { try? FileManager.default.removeItem(at: dir.appendingPathComponent(key)) }
    }
    private func persistIndex() {
        guard let dir, let d = try? JSONEncoder().encode(index) else { return }
        try? d.write(to: dir.appendingPathComponent("index.json"), options: .atomic)
    }
    private static func scan(_ dir: URL) -> ([String: Meta], Int) {
        guard let d = try? Data(contentsOf: dir.appendingPathComponent("index.json")),
              let idx = try? JSONDecoder().decode([String: Meta].self, from: d) else { return ([:], 0) }
        var ok: [String: Meta] = [:]; var t = 0
        for (k, m) in idx where FileManager.default.fileExists(atPath: dir.appendingPathComponent(k).path) { ok[k] = m; t += m.size }
        return (ok, t)
    }
    static func key(_ u: URL) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in u.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return "img-" + String(h, radix: 16)
    }
}
