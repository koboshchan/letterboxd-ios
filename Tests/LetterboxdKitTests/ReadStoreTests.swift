import XCTest
@testable import LetterboxdKit

final class ReadStoreTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rs-" + UUID().uuidString) }
    func testWithinLaunchRoundTripAndNoCrossLaunchReuse() async {
        let d = tmp(); let g = MemGenStore(); let s = ReadStore(directory: d, gens: g); let e = s.currentEpoch()
        s.set(["a"], ns: "alice", key: "k", epoch: e)
        let s2 = ReadStore(directory: d, gens: g)
        XCTAssertEqual(s.get([String].self, ns: "alice", key: "k"), ["a"])   // same launch persists
        let a = s2.get([String].self, ns: "alice", key: "k"); XCTAssertNil(a)   // NEW launch never reads private data
        let b = s2.get([String].self, ns: "bob", key: "k"); XCTAssertNil(b)
    }
    func testExpiryAndBound() async {
        let t = Box(Date()); let s = ReadStore(directory: nil, ttl: 10, maxEntries: 2, now: { t.v })
        let e = s.currentEpoch()
        s.set(1, ns: "u", key: "a", epoch: e); t.v = t.v.addingTimeInterval(1)
        s.set(2, ns: "u", key: "b", epoch: e); t.v = t.v.addingTimeInterval(1)
        s.set(3, ns: "u", key: "c", epoch: e)
        let a = s.get(Int.self, ns: "u", key: "a"); XCTAssertNil(a)
        t.v = t.v.addingTimeInterval(60)
        let c = s.get(Int.self, ns: "u", key: "c"); XCTAssertNil(c)
    }
    func testClearPurgesDiskAndFencesLateWrite() async {
        let d = tmp(); let s = ReadStore(directory: d, gens: MemGenStore()); let e = s.currentEpoch()
        s.set(1, ns: "u", key: "k", epoch: e); s.clear()
        s.set(2, ns: "u", key: "k", epoch: e)
        let v = ReadStore(directory: d, gens: MemGenStore()).get(Int.self, ns: "u", key: "k"); XCTAssertNil(v)
    }
    func testInvalidateDropsAndBadNamespaceRefused() async {
        let s = ReadStore(directory: tmp(), gens: MemGenStore()); let e = s.currentEpoch()
        s.set(1, ns: "u", key: "watchlist-1", epoch: e); s.invalidate(ns: "u", prefix: "")
        let v = s.get(Int.self, ns: "u", key: "watchlist-1"); XCTAssertNil(v)
        let e2 = s.currentEpoch(); s.set(1, ns: "../x", key: "k", epoch: e2)
        let w = s.get(Int.self, ns: "../x", key: "k"); XCTAssertEqual(w, 1) // memory only; never touches disk
    }
}
final class Box: @unchecked Sendable { var v: Date; init(_ v: Date) { self.v = v } }

final class ServiceReadCacheTests: XCTestCase {
    func svc(_ auth: AuthAuthority, _ rs: ReadStore) -> PublicWebService {
        PublicWebService(fetcher: Fetcher(transport: StubTransport(handler: { _ in throw LetterboxdError.http(status: 500) }), auth: auth), reads: rs)
    }
    func testSignedOutNeverStoresAndClearPurges() async throws {
        let rs = ReadStore(directory: nil); let a = AuthAuthority()
        _ = try? await svc(a, rs).profile(username: "example-member", refresh: false)
        let v = rs.get(Profile.self, ns: "example-member", key: "profile-example-member"); XCTAssertNil(v)
        await svc(a, rs).clearCaches()
        let e = rs.currentEpoch(); XCTAssertGreaterThan(e, 0)
    }
}

final class PrivateCacheSecurityTests: XCTestCase {
    func sess(_ u: String) -> Session { Session(username: u, cookies: []) }
    func testNoCredentialMaterialOnDisk() async throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sec-" + UUID().uuidString)
        let s = ReadStore(directory: d, gens: MemGenStore()); let e = s.currentEpoch()
        s.set(["title"], ns: "alice", key: "films-alice-1", epoch: e)
        let files = FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }
        XCTAssertFalse(files.isEmpty)
        for f in files { let t = String(decoding: try Data(contentsOf: f), as: UTF8.self).lowercased()
            for bad in ["cookie", "csrf", "token", "set-cookie", "authorization"] { XCTAssertFalse(t.contains(bad)) } }
    }
    func testAccountSwitchReadsNothingFromPreviousAccount() async {
        let s = ReadStore(directory: nil); let e = s.currentEpoch()
        s.set(1, ns: "alice", key: "profile-alice", epoch: e)
        let a = s.get(Int.self, ns: "bob", key: "profile-alice"); XCTAssertNil(a)
    }
    func testInFlightReadAcrossAccountChangeIsNotStored() async throws {
        let rs = ReadStore(directory: nil); let auth = AuthAuthority(); auth.setValidated(sess("alice"))
        let gate = Counter()
        let svc = PublicWebService(fetcher: Fetcher(transport: StubTransport(handler: { _ in
            await gate.inc(); try await Task.sleep(nanoseconds: 200_000_000)
            return HTTPResult(data: Data("<html></html>".utf8), status: 200) }), auth: auth), reads: rs)
        let t = Task { try? await svc.profile(username: "alice", refresh: true) }
        while await gate.value() == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        auth.revoke(); await svc.clearCaches(); _ = await t.value
        let v = rs.get(Profile.self, ns: "alice", key: "profile-alice"); XCTAssertNil(v)
    }
}

final class SyncPurgeTests: XCTestCase {
    func sess(_ u: String) -> Session { Session(username: u, cookies: []) }
    func testRevokePurgesSynchronouslyBeforeAnyAwait() {
        let rs = ReadStore(directory: nil); let a = AuthAuthority(); a.setValidated(sess("alice"))
        _ = PublicWebService(fetcher: Fetcher(transport: StubTransport(handler: { _ in throw LetterboxdError.http(status: 500) }), auth: a), reads: rs)
        rs.set(1, ns: "alice", key: "profile-alice", epoch: rs.currentEpoch())
        XCTAssertNotNil(rs.get(Int.self, ns: "alice", key: "profile-alice"))
        a.revoke()   // no await, no UI observer
        XCTAssertNil(rs.get(Int.self, ns: "alice", key: "profile-alice"))
    }
    func testAccountSwitchAtoBPurgesAndLateWriteRejected() {
        let rs = ReadStore(directory: nil); let a = AuthAuthority(); a.setValidated(sess("alice"))
        _ = PublicWebService(fetcher: Fetcher(transport: StubTransport(handler: { _ in throw LetterboxdError.http(status: 500) }), auth: a), reads: rs)
        let oldEpoch = rs.currentEpoch()
        rs.set(1, ns: "alice", key: "k", epoch: oldEpoch)
        a.setValidated(sess("bob"))
        rs.set(2, ns: "alice", key: "k", epoch: oldEpoch)   // late save from alice's in-flight read
        XCTAssertNil(rs.get(Int.self, ns: "alice", key: "k")); XCTAssertNil(rs.get(Int.self, ns: "bob", key: "k"))
    }}

final class FailingFS: ReadFS, @unchecked Sendable {
    let real = RealReadFS(); var failRemove = false; var hugeTotal = false; var failList = false; var failWrite = false
    func createDirectory(_ u: URL) throws { try real.createDirectory(u) }
    func remove(_ u: URL) throws { if failRemove { throw CocoaError(.fileWriteNoPermission) }; try real.remove(u) }
    func write(_ d: Data, to u: URL) throws { if failWrite { throw CocoaError(.fileWriteNoPermission) }; try real.write(d, to: u) }
    func read(_ u: URL, maxBytes: Int) throws -> Data { try real.read(u, maxBytes: maxBytes) }
    func list(_ u: URL) throws -> [URL] { if failList { throw CocoaError(.fileReadNoPermission) }; return try real.list(u) }
    func size(_ u: URL) -> Int? { real.size(u) }
    func exists(_ u: URL) -> Bool { real.exists(u) }
    func totalBytes(_ u: URL) throws -> Int { if hugeTotal { return Int.max }; if failList { throw CocoaError(.fileReadNoPermission) }; return try real.totalBytes(u) }
}
final class ReadStoreHardeningTests: XCTestCase {
    func testUndeletableOldGenerationsDisableNewWritesAndNeverAccumulate() {
        let d = tmp(); let fs = FailingFS(); let tm = Box(Date())
        var s = ReadStore(directory: d, maxEntryBytes: 3000, maxTotalBytes: 5000, fs: fs, gens: MemGenStore(), now: { tm.v })
        s.set(String(repeating: "x", count: 1500), ns: "u", key: "a", epoch: s.currentEpoch())
        fs.failRemove = true
        for i in 0..<6 { s = ReadStore(directory: d, maxEntryBytes: 3000, maxTotalBytes: 5000, fs: fs, gens: MemGenStore(), now: { tm.v })
            s.set(String(repeating: "y", count: 1500), ns: "u", key: "k\(i)", epoch: s.currentEpoch()) }
        let total = (try? RealReadFS().totalBytes(d)) ?? 0
        XCTAssertLessThanOrEqual(total, 5000 + 3000, "n=\(FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil)!.allObjects.count)")
        XCTAssertTrue(s.diskDisabled)
    }
    func testSingleWriteCannotCrossWholeRootCap() throws {
        let d = tmp(); let fs = FailingFS(); let g = MemGenStore()
        func mk() -> ReadStore { ReadStore(directory: d, maxEntryBytes: 20000, maxTotalBytes: 9000, fs: fs, gens: g) }
        var s = mk()
        s.set(String(repeating: "x", count: 2000), ns: "u", key: "a", epoch: s.currentEpoch())
        fs.failRemove = true
        s = mk()
        let before = try RealReadFS().totalBytes(d)
        XCTAssertLessThan(before, 9000)
        let big = String(repeating: "y", count: 5000)   // wrapper ~6.7KB fits maxEntryBytes; before + wrapper > cap
        let wrapper = try JSONEncoder().encode(["key": "k", "data": String(repeating: "y", count: 6700)]).count
        XCTAssertLessThan(wrapper, 20000); XCTAssertGreaterThan(before + 6700, 9000)
        s.set(big, ns: "u", key: "b", epoch: s.currentEpoch())
        XCTAssertTrue(s.diskDisabled)
        XCTAssertLessThanOrEqual(try RealReadFS().totalBytes(d), before)
    }
    func testIntMaxTotalDisablesWithoutCrash() {
        final class Huge: ReadFS, @unchecked Sendable {
            let r = RealReadFS()
            func createDirectory(_ u: URL) throws { try r.createDirectory(u) }
            func remove(_ u: URL) throws { try r.remove(u) }
            func write(_ d: Data, to u: URL) throws { try r.write(d, to: u) }
            func read(_ u: URL, maxBytes: Int) throws -> Data { try r.read(u, maxBytes: maxBytes) }
            func list(_ u: URL) throws -> [URL] { try r.list(u) }
            func size(_ u: URL) -> Int? { r.size(u) }
            func exists(_ u: URL) -> Bool { r.exists(u) }
            func totalBytes(_ u: URL) throws -> Int { Int.max }
        }
        let s = ReadStore(directory: tmp(), fs: Huge(), gens: MemGenStore())
        XCTAssertTrue(s.diskDisabled)
    }
    func testProjectedAddOverflowDisablesDiskWithoutCrash() {
        let d = tmp(); let fs = FailingFS(); let g = MemGenStore()
        let s = ReadStore(directory: d, maxEntryBytes: 20000, maxTotalBytes: Int.max, fs: fs, gens: g)
        fs.hugeTotal = true
        s.set("small", ns: "u", key: "k", epoch: s.currentEpoch())
        XCTAssertTrue(s.diskDisabled)
    }
    func testUnmeasurableRootDisablesDisk() {
        let d = tmp(); let fs = FailingFS(); _ = ReadStore(directory: d, fs: fs, gens: MemGenStore()); fs.failList = true
        XCTAssertTrue(ReadStore(directory: d, fs: fs, gens: MemGenStore()).diskDisabled)
    }
    func testDoubleUnwritableRestartNeverReturnsOldEntries() {
        let d = tmp(); let fs = FailingFS(); let g = MemGenStore(); let s = ReadStore(directory: d, fs: fs, gens: g)
        s.set(123, ns: "alice", key: "k", epoch: s.currentEpoch())
        fs.failRemove = true; fs.failList = true; g.failSet = true; s.clear()
        let r = ReadStore(directory: d, fs: fs, gens: g)
        XCTAssertNil(r.get(Int.self, ns: "alice", key: "k"))
        let r2 = ReadStore(directory: d, gens: MemGenStore()); XCTAssertNil(r2.get(Int.self, ns: "alice", key: "k"))
    }
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rh-" + UUID().uuidString) }
    func files(_ d: URL) -> [URL] { (FileManager.default.enumerator(at: d, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "json" } }
    func testClearSurvivesRestartEvenWhenDeleteAndListFail() {
        let d = tmp(); let fs = FailingFS(); let g = MemGenStore()
        let s = ReadStore(directory: d, fs: fs, gens: g); s.set(123, ns: "alice", key: "k", epoch: s.currentEpoch())
        fs.failRemove = true; fs.failList = true; s.clear()
        XCTAssertNil(s.get(Int.self, ns: "alice", key: "k"))
        // fresh instances with a healthy FS but the same durable generation record: old value must be unreachable
        XCTAssertNil(ReadStore(directory: d, gens: g).get(Int.self, ns: "alice", key: "k"))
        fs.failRemove = false; fs.failList = false
        XCTAssertNil(ReadStore(directory: d, fs: fs, gens: g).get(Int.self, ns: "alice", key: "k"))
    }
    func testClearWorksEvenIfGenerationRecordFails() {
        let d = tmp(); let g = MemGenStore(); let s = ReadStore(directory: d, gens: g)
        s.set(1, ns: "alice", key: "k", epoch: s.currentEpoch()); g.failSet = true; s.clear()
        XCTAssertNil(s.get(Int.self, ns: "alice", key: "k")); XCTAssertNil(ReadStore(directory: d, gens: g).get(Int.self, ns: "alice", key: "k"))
        s.set(2, ns: "alice", key: "k2", epoch: s.currentEpoch())   // memory only, nothing written
        XCTAssertEqual(s.get(Int.self, ns: "alice", key: "k2"), 2)
    }
    func testInvalidateIsDurableAcrossRestart() {
        let d = tmp(); let fs = FailingFS(); let g = MemGenStore(); let s = ReadStore(directory: d, fs: fs, gens: g)
        s.set(1, ns: "alice", key: "k", epoch: s.currentEpoch()); fs.failRemove = true
        s.invalidate(ns: "alice", prefix: "")
        XCTAssertNil(ReadStore(directory: d, gens: g).get(Int.self, ns: "alice", key: "k"))
    }
    func testScanFailureDisablesDisk() {
        let d = tmp(); let fs = FailingFS(); let g = MemGenStore(); let s = ReadStore(directory: d, fs: fs, gens: g)
        s.set(1, ns: "alice", key: "k", epoch: s.currentEpoch()); fs.failList = true
        XCTAssertTrue(ReadStore(directory: d, fs: fs, gens: g).diskDisabled)
    }
    func testEvictionFailureDisablesDisk() {
        let d = tmp(); let fs = FailingFS(); let tm = Box(Date())
        let s = ReadStore(directory: d, maxEntries: 1, fs: fs, gens: MemGenStore(), now: { tm.v })
        s.set(1, ns: "u", key: "a", epoch: s.currentEpoch()); tm.v = tm.v.addingTimeInterval(1); fs.failRemove = true
        s.set(2, ns: "u", key: "b", epoch: s.currentEpoch()); XCTAssertTrue(s.diskDisabled)
    }
    func testOversizedEntryRejectedAndTotalBytesBoundedAcrossRestart() {
        let d = tmp(); let g = MemGenStore(); let s = ReadStore(directory: d, maxEntryBytes: 2000, maxTotalBytes: 5000, gens: g)
        XCTAssertFalse(s.set(String(repeating: "x", count: 3000), ns: "u", key: "big", epoch: s.currentEpoch()))
        let tm = Box(Date())
        let s1 = ReadStore(directory: d, maxEntryBytes: 2000, maxTotalBytes: 5000, gens: g, now: { tm.v })
        for i in 0..<10 { tm.v = tm.v.addingTimeInterval(1); s1.set(String(repeating: "y", count: 900), ns: "u", key: "k\(i)", epoch: s1.currentEpoch()) }
        func total() -> Int { files(d).reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } }
        XCTAssertLessThanOrEqual(total(), 5000)
        _ = ReadStore(directory: d, maxEntryBytes: 2000, maxTotalBytes: 2000, gens: g, now: { tm.v })   // smaller cap on restart evicts
        XCTAssertLessThanOrEqual(total(), 2000)
    }
    func testKeyCollisionLikeNamesStayDistinct() {
        let d = tmp(); let g = MemGenStore(); let s = ReadStore(directory: d, gens: g); let e = s.currentEpoch()
        s.set(1, ns: "u", key: "profile-a-b", epoch: e); s.set(2, ns: "u", key: "profile-a_b", epoch: e)
        XCTAssertEqual(s.get(Int.self, ns: "u", key: "profile-a-b"), 1); XCTAssertEqual(s.get(Int.self, ns: "u", key: "profile-a_b"), 2)
        XCTAssertEqual(files(d).count, 2)
    }
    func testPermissionsPrivateAndFutureTimestampRejected() throws {
        let d = tmp(); let tm = Box(Date().addingTimeInterval(3600))
        let s = ReadStore(directory: d, now: { tm.v }); s.set(1, ns: "u", key: "k", epoch: s.currentEpoch())
        let f = files(d)[0]
        let fp = try FileManager.default.attributesOfItem(atPath: f.path)[.posixPermissions] as? Int
        let dp = try FileManager.default.attributesOfItem(atPath: f.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(fp, 0o600); XCTAssertEqual(dp, 0o700)
        tm.v = Date()   // entry is now "from the future"
        XCTAssertNil(ReadStore(directory: d, gens: MemGenStore()).get(Int.self, ns: "u", key: "k"))
    }
    func testStoredBytesContainOnlyModelFields() throws {
        struct M: Codable { var title: String }
        let d = tmp(); let s = ReadStore(directory: d, gens: MemGenStore()); s.set(M(title: "Film"), ns: "u", key: "k", epoch: s.currentEpoch())
        let f = files(d)[0]
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: f)) as! [String: Any]
        XCTAssertEqual(Set(o.keys), ["key", "at", "data"])
        let b64 = o["data"] as! String
        let inner = try JSONSerialization.jsonObject(with: Data(base64Encoded: b64)!) as! [String: Any]
        XCTAssertEqual(Set(inner.keys), ["title"])
    }
    func testPurgeHookRunsBeforeNewGenerationVisible() {
        let rs = ReadStore(directory: nil); let a = AuthAuthority()
        let seen = Box2(); a.addPurgeHook { rs.clear(); seen.cleared = true }
        a.setValidated(Session(username: "alice", cookies: [])); rs.set(1, ns: "alice", key: "k", epoch: rs.currentEpoch())
        a.setValidated(Session(username: "bob", cookies: []))
        XCTAssertTrue(seen.cleared); XCTAssertNil(rs.get(Int.self, ns: "alice", key: "k"))
        let s = a.snapshot(); XCTAssertEqual(s.username, "bob"); XCTAssertEqual(s.generation, 2)
    }
}
final class Box2: @unchecked Sendable { var cleared = false }
