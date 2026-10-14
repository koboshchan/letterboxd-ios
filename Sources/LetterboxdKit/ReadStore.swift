import Foundation

/// Private read-model cache: minimal decoded models (never HTML, cookies, CSRF or tokens), one namespace per validated
/// signed-in username, TTL + bounded entry count, memory + optional disk. Clearing bumps an epoch so a read that was
/// in flight cannot write back afterwards. If storage can't be prepared it falls back to memory only (fail closed).
public actor ReadStore {
    private struct Entry: Codable { var at: Date; var data: Data }
    private let dir: URL?
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let now: @Sendable () -> Date
    private var mem: [String: Entry] = [:]
    private var epoch = 0

    public init(directory: URL?, ttl: TimeInterval = 600, maxEntries: Int = 200, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl; self.maxEntries = maxEntries; self.now = now
        var d = directory
        if let dd = d {
            do {
                try FileManager.default.createDirectory(at: dd, withIntermediateDirectories: true)
                var v = URLResourceValues(); v.isExcludedFromBackup = true
                var m = dd; try? m.setResourceValues(v)
                #if canImport(Darwin)
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dd.path)
                #endif
            } catch { d = nil }
        }
        dir = d
    }

    public func currentEpoch() -> Int { epoch }
    /// Namespace is the validated username; anything else is refused so a key can never escape its folder.
    private func file(_ ns: String, _ key: String) -> URL? {
        guard let dir, ns.range(of: "^[A-Za-z0-9_]{1,40}$", options: .regularExpression) != nil else { return nil }
        let safe = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return dir.appendingPathComponent(ns, isDirectory: true).appendingPathComponent(String(safe.prefix(120)) + ".json")
    }
    private func id(_ ns: String, _ key: String) -> String { ns + "/" + key }

    public func get<T: Decodable>(_ type: T.Type, ns: String, key: String) -> T? {
        let k = id(ns, key)
        var e = mem[k]
        if e == nil, let f = file(ns, key), let d = try? Data(contentsOf: f), let x = try? JSONDecoder().decode(Entry.self, from: d) { e = x; mem[k] = x }
        guard let e else { return nil }
        guard now().timeIntervalSince(e.at) < ttl, let v = try? JSONDecoder().decode(T.self, from: e.data) else { remove(ns, key); return nil }
        return v
    }
    /// Stores only if no clear happened since the caller captured `epoch`.
    public func set<T: Encodable>(_ v: T, ns: String, key: String, epoch e: Int) {
        guard e == epoch, let data = try? JSONEncoder().encode(v) else { return }
        let entry = Entry(at: now(), data: data)
        mem[id(ns, key)] = entry
        if let f = file(ns, key), let enc = try? JSONEncoder().encode(entry) {
            try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? enc.write(to: f, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        while mem.count > maxEntries, let oldest = mem.min(by: { $0.value.at < $1.value.at })?.key {
            mem[oldest] = nil
            let p = oldest.split(separator: "/", maxSplits: 1).map(String.init)
            if p.count == 2, let f = file(p[0], p[1]) { try? FileManager.default.removeItem(at: f) }
        }
    }
    private func remove(_ ns: String, _ key: String) { mem[id(ns, key)] = nil; if let f = file(ns, key) { try? FileManager.default.removeItem(at: f) } }
    /// Drops every entry of one namespace whose key starts with prefix (used after a write).
    public func invalidate(ns: String, prefix: String) {
        epoch += 1
        for k in mem.keys where k.hasPrefix(ns + "/" + prefix) { mem[k] = nil }
        if let f = file(ns, "x")?.deletingLastPathComponent(), let items = try? FileManager.default.contentsOfDirectory(atPath: f.path) {
            let safePrefix = prefix.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
            for i in items where i.hasPrefix(safePrefix) { try? FileManager.default.removeItem(at: f.appendingPathComponent(i)) }
        }
    }
    /// Sign-out / account switch: purge everything, memory and disk, and fence late writes.
    public func clear() {
        epoch += 1; mem.removeAll()
        if let dir { try? FileManager.default.removeItem(at: dir); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    }
}

struct CachedPage<T: Codable & Sendable>: Codable, Sendable { var items: [T]; var page: Int; var hasNext: Bool }
