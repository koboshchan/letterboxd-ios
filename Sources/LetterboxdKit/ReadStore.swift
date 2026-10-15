import Foundation

/// Filesystem seam so purge/IO failures can be injected deterministically in tests.
public protocol ReadFS: Sendable {
    func createDirectory(_ u: URL) throws
    func totalBytes(_ u: URL) throws -> Int
    func remove(_ u: URL) throws
    func write(_ d: Data, to u: URL) throws
    func read(_ u: URL, maxBytes: Int) throws -> Data
    func list(_ u: URL) throws -> [URL]
    func size(_ u: URL) -> Int?
    func exists(_ u: URL) -> Bool
}
public struct RealReadFS: ReadFS {
    public init() {}
    public func totalBytes(_ u: URL) throws -> Int {
        var total = 0
        var err: Error?
        guard let en = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [], errorHandler: { _, e in err = e; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let f as URL in en {
            let v = try f.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            guard let isDir = v.isDirectory else { throw CocoaError(.fileReadUnknown) }
            if !isDir {
                guard let sz = v.fileSize, sz >= 0 else { throw CocoaError(.fileReadUnknown) }
                let (n, o) = total.addingReportingOverflow(sz); if o { throw CocoaError(.fileReadUnknown) }
                total = n
            }
        }
        if let err { throw err }
        return total
    }
    public func createDirectory(_ u: URL) throws {
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: u.path)   // also tightens pre-existing loose dirs
        var v = URLResourceValues(); v.isExcludedFromBackup = true; var m = u; try m.setResourceValues(v)
        #if canImport(Darwin)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: u.path)
        #endif
    }
    public func remove(_ u: URL) throws {
        do { try FileManager.default.removeItem(at: u) }
        catch let e as CocoaError where e.code == .fileNoSuchFile || e.code == .fileReadNoSuchFile { return }
        catch let e as NSError where e.domain == NSPOSIXErrorDomain && e.code == Int(ENOENT) { return }
    }
    public func write(_ d: Data, to u: URL) throws {
        #if canImport(Darwin)
        try d.write(to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try d.write(to: u, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: u.path)
    }
    public func read(_ u: URL, maxBytes: Int) throws -> Data {
        guard let s = size(u), s <= maxBytes else { throw CocoaError(.fileReadTooLarge) }
        return try Data(contentsOf: u)
    }
    public func list(_ u: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) }
    public func size(_ u: URL) -> Int? { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? nil }
    public func exists(_ u: URL) -> Bool { FileManager.default.fileExists(atPath: u.path) }
}

/// Durable storage-generation record, kept OUTSIDE the cache directory (UserDefaults in the app) so it stays
/// authoritative even when the cache directory is unwritable. Setting returns true only if a read-back matches.
public protocol GenStore: Sendable { func get() -> String?; func set(_ v: String) -> Bool }
public struct DefaultsGenStore: GenStore {
    let key: String
    public init(key: String = "LetterboxdReadStoreGeneration") { self.key = key }
    public func get() -> String? { UserDefaults.standard.string(forKey: key) }
    public func set(_ v: String) -> Bool { UserDefaults.standard.set(v, forKey: key); return UserDefaults.standard.string(forKey: key) == v }
}
public final class MemGenStore: GenStore, @unchecked Sendable {
    private let l = NSLock(); private var v: String?; public var failSet = false
    public init() {}
    public func get() -> String? { l.lock(); defer { l.unlock() }; return v }
    public func set(_ x: String) -> Bool { l.lock(); defer { l.unlock() }; if failSet { return false }; v = x; return true }
}

/// Private read-model cache: minimal decoded models (never HTML, cookies, CSRF or tokens), one namespace per validated
/// signed-in username. Bounded by TTL, entry count, per-entry bytes and TOTAL disk bytes across the whole cache root (all generations, checked at launch, purge and before every write).
/// ISOLATION: every instance (every launch) and every clear/invalidate switches to a fresh random in-process generation
/// directory; nothing from an earlier generation is ever read. Old generations are deleted best effort; if leftovers
/// (or an unreadable root) push total bytes over the cap, disk writes are disabled so bytes never accumulate (not secure erasure). If the new directory
/// cannot be prepared, or any scan/eviction IO fails, disk is disabled (memory only). GenStore is unused legacy API.
/// Callbacks (fs, now, Codable) run under the lock and must never re-enter this store or AuthAuthority.
public final class ReadStore: @unchecked Sendable {
    private let lock = NSLock()
    private struct Entry: Codable { var key: String; var at: Date; var data: Data }
    private struct Meta { var ns: String; var at: Date; var size: Int }
    private let root: URL?
    private let fs: ReadFS
    private let gens: GenStore
    private let ttl: TimeInterval
    private let maxEntries: Int, maxEntryBytes: Int, maxTotalBytes: Int
    private let now: @Sendable () -> Date
    private var mem: [String: Entry] = [:]
    private var inventory: [URL: Meta] = [:]
    private var gen = ""
    private var epoch = 0
    private var diskFailed = false

    public init(directory: URL?, ttl: TimeInterval = 600, maxEntries: Int = 200, maxEntryBytes: Int = 256 * 1024,
                maxTotalBytes: Int = 8 << 20, fs: ReadFS = RealReadFS(), gens: GenStore = DefaultsGenStore(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl; self.maxEntries = maxEntries; self.maxEntryBytes = maxEntryBytes; self.maxTotalBytes = maxTotalBytes
        self.now = now; self.fs = fs; self.gens = gens; self.root = directory
        guard let d = directory else { return }
        do {
            try fs.createDirectory(d)
            gen = UUID().uuidString   // fresh private generation EVERY launch: nothing from a previous process is ever read
            try fs.createDirectory(d.appendingPathComponent(gen, isDirectory: true))
            sweepOldGenerations(d)
            try enforceGlobalBound(d)
            try scanLocked()
        } catch { diskFailed = true; inventory.removeAll() }
    }
    public var diskDisabled: Bool { lock.lock(); defer { lock.unlock() }; return diskFailed }
    public func currentEpoch() -> Int { lock.lock(); defer { lock.unlock() }; return epoch }

    private func fnv(_ s: String, _ seed: UInt64) -> UInt64 { var h = seed; for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }; return h }
    private func validNS(_ ns: String) -> Bool { ns.range(of: "^[A-Za-z0-9_]{1,40}$", options: .regularExpression) != nil }
    private var genDir: URL? { root?.appendingPathComponent(gen, isDirectory: true) }
    private func file(_ ns: String, _ key: String) -> URL? {
        guard let g = genDir, !diskFailed, validNS(ns) else { return nil }
        let n = String(format: "%016llx%016llx", fnv(key, 0xcbf29ce484222325), fnv(key, 0x84222325cbf29ce4))
        return g.appendingPathComponent(ns, isDirectory: true).appendingPathComponent(n + ".json")
    }
    private func id(_ ns: String, _ key: String) -> String { ns + "/" + key }
    private func fresh(_ e: Entry) -> Bool { let a = now().timeIntervalSince(e.at); return a >= 0 && a < ttl }
    /// Old generations are never read, so a failed delete is only a storage-use issue; retried next launch.
    private func sweepOldGenerations(_ d: URL) {
        for u in (try? fs.list(d)) ?? [] where u.lastPathComponent != gen { try? fs.remove(u) }
    }
    /// The WHOLE cache root (all generations) must fit the cap; unreadable/undeletable leftovers disable disk writes.
    private func enforceGlobalBound(_ d: URL, adding: Int = 0) throws {
        let tb = try fs.totalBytes(d); let (sum, ov) = tb.addingReportingOverflow(adding)
        if ov || sum > maxTotalBytes { throw CocoaError(.fileWriteOutOfSpace) }
    }
    private func scanLocked() throws {
        guard let g = genDir else { return }
        inventory.removeAll()
        for nsDir in try fs.list(g) {
            guard validNS(nsDir.lastPathComponent) else { try fs.remove(nsDir); continue }
            for f in try fs.list(nsDir) {
                guard let sz = fs.size(f), sz <= maxEntryBytes,
                      let data = try? fs.read(f, maxBytes: maxEntryBytes), let e = try? JSONDecoder().decode(Entry.self, from: data), fresh(e)
                else { try fs.remove(f); continue }
                inventory[f] = Meta(ns: nsDir.lastPathComponent, at: e.at, size: sz)
            }
        }
        try evictDiskLocked()
    }
    /// Subtracts bytes only after the file is really gone; any IO failure throws (caller disables disk).
    private func evictDiskLocked() throws {
        var total = inventory.values.reduce(0) { $0 + $1.size }
        while (inventory.count > maxEntries || total > maxTotalBytes), let o = inventory.min(by: { $0.value.at < $1.value.at }) {
            try fs.remove(o.key); total -= o.value.size; inventory[o.key] = nil
        }
    }

    public func get<T: Decodable>(_ type: T.Type, ns: String, key: String) -> T? {
        lock.lock(); defer { lock.unlock() }
        var e = mem[id(ns, key)]
        if e == nil, let f = file(ns, key), let d = try? fs.read(f, maxBytes: maxEntryBytes), let x = try? JSONDecoder().decode(Entry.self, from: d), x.key == key {
            e = x; mem[id(ns, key)] = x
        }
        guard let e else { return nil }
        guard fresh(e), let v = try? JSONDecoder().decode(T.self, from: e.data) else { remove(ns, key); return nil }
        return v
    }
    /// Stores only if no clear/invalidate happened since `epoch` was captured. Returns whether it was accepted.
    @discardableResult
    public func set<T: Encodable>(_ v: T, ns: String, key: String, epoch e: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard e == epoch, let data = try? JSONEncoder().encode(v), data.count <= maxEntryBytes else { return false }
        let entry = Entry(key: key, at: now(), data: data)
        mem[id(ns, key)] = entry
        if let f = file(ns, key), let enc = try? JSONEncoder().encode(entry), enc.count <= maxEntryBytes {
            do { if let r = root { try enforceGlobalBound(r, adding: enc.count) }; try fs.createDirectory(f.deletingLastPathComponent()); try fs.write(enc, to: f); inventory[f] = Meta(ns: ns, at: entry.at, size: enc.count); try evictDiskLocked(); if let r = root { try enforceGlobalBound(r) } }
            catch { diskFailed = true }
        }
        while mem.count > maxEntries, let oldest = mem.min(by: { $0.value.at < $1.value.at })?.key { mem[oldest] = nil }
        return true
    }
    private func remove(_ ns: String, _ key: String) {
        mem[id(ns, key)] = nil
        if let f = file(ns, key) { do { try fs.remove(f); inventory[f] = nil } catch { diskFailed = true } }
    }
    /// Durable switch to a fresh generation. Returns false (and disables disk) if it cannot be recorded.
    private func rotateLocked() {
        guard let d = root else { return }
        let old = genDir
        let g = UUID().uuidString
                gen = g; inventory.removeAll()
        do { try fs.createDirectory(genDir!); diskFailed = false } catch { diskFailed = true }
        if let old { try? fs.remove(old) }
        sweepOldGenerations(d)
        do { try enforceGlobalBound(d) } catch { diskFailed = true }
    }
    /// A write happened: drop every cached read (conservative) durably, and fence in-flight reads.
    public func invalidate(ns: String, prefix: String) {
        lock.lock(); defer { lock.unlock() }
        epoch += 1; mem.removeAll(); rotateLocked()
    }
    /// Sign-out / account switch: SYNCHRONOUS purge and fence.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        epoch += 1; mem.removeAll(); rotateLocked()
    }
}

struct CachedPage<T: Codable & Sendable>: Codable, Sendable { var items: [T]; var page: Int; var hasNext: Bool }
