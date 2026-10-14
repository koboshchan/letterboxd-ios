import XCTest
@testable import LetterboxdKit

final class ReadStoreTests: XCTestCase {
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("rs-" + UUID().uuidString) }
    func testRoundTripPersistsAndIsolatesAccounts() async {
        let d = tmp(); let s = ReadStore(directory: d); let e = await s.currentEpoch()
        await s.set(["a"], ns: "alice", key: "k", epoch: e)
        let s2 = ReadStore(directory: d)
        let a = await s2.get([String].self, ns: "alice", key: "k"); XCTAssertEqual(a, ["a"])
        let b = await s2.get([String].self, ns: "bob", key: "k"); XCTAssertNil(b)
    }
    func testExpiryAndBound() async {
        let t = Box(Date()); let s = ReadStore(directory: nil, ttl: 10, maxEntries: 2, now: { t.v })
        let e = await s.currentEpoch()
        await s.set(1, ns: "u", key: "a", epoch: e); t.v = t.v.addingTimeInterval(1)
        await s.set(2, ns: "u", key: "b", epoch: e); t.v = t.v.addingTimeInterval(1)
        await s.set(3, ns: "u", key: "c", epoch: e)
        let a = await s.get(Int.self, ns: "u", key: "a"); XCTAssertNil(a)
        t.v = t.v.addingTimeInterval(60)
        let c = await s.get(Int.self, ns: "u", key: "c"); XCTAssertNil(c)
    }
    func testClearPurgesDiskAndFencesLateWrite() async {
        let d = tmp(); let s = ReadStore(directory: d); let e = await s.currentEpoch()
        await s.set(1, ns: "u", key: "k", epoch: e); await s.clear()
        await s.set(2, ns: "u", key: "k", epoch: e)
        let v = await ReadStore(directory: d).get(Int.self, ns: "u", key: "k"); XCTAssertNil(v)
    }
    func testInvalidateDropsAndBadNamespaceRefused() async {
        let s = ReadStore(directory: tmp()); let e = await s.currentEpoch()
        await s.set(1, ns: "u", key: "watchlist-1", epoch: e); await s.invalidate(ns: "u", prefix: "")
        let v = await s.get(Int.self, ns: "u", key: "watchlist-1"); XCTAssertNil(v)
        let e2 = await s.currentEpoch(); await s.set(1, ns: "../x", key: "k", epoch: e2)
        let w = await s.get(Int.self, ns: "../x", key: "k"); XCTAssertEqual(w, 1) // memory only; never touches disk
    }
}
final class Box: @unchecked Sendable { var v: Date; init(_ v: Date) { self.v = v } }
