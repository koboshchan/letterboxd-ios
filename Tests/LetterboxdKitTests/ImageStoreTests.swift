import XCTest
@testable import LetterboxdKit

private final class HitCounter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0; private var urls: [URL] = []
    func hit(_ u: URL) { l.lock(); n += 1; urls.append(u); l.unlock() }
    var count: Int { l.lock(); defer { l.unlock() }; return n }
}
private final class TestClock: @unchecked Sendable {
    private let l = NSLock(); private var t = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { l.lock(); defer { l.unlock() }; return t }
    func advance(_ s: TimeInterval) { l.lock(); t = t.addingTimeInterval(s); l.unlock() }
}

final class ImageStoreTests: XCTestCase {
    let u1 = URL(string: "https://a.ltrbxd.com/resized/film-poster/1-0-230-0-345-crop.jpg")!
    let u2 = URL(string: "https://image.tmdb.org/t/p/w500/abc.jpg")!
    func tmp() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("imgstore-" + UUID().uuidString) }
    func bytes(_ n: Int, _ b: UInt8 = 7) -> Data { Data(repeating: b, count: n) }

    func testHostValidation() {
        for bad in ["http://a.ltrbxd.com/x.jpg", "https://evil.com/x.jpg", "https://a.ltrbxd.com.evil.com/x", "https://user@a.ltrbxd.com/x", "https://a.ltrbxd.com:8443/x", "https://a.ltrbxd.com/x#f", "https://letterboxd.com/x.jpg"] {
            XCTAssertNil(ImageStore.validate(URL(string: bad)!), bad)
        }
        XCTAssertNotNil(ImageStore.validate(u1)); XCTAssertNotNil(ImageStore.validate(u2))
    }

    func testMissFetchesOnceThenMemoryAndDiskHits() async throws {
        let c = HitCounter(); let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = ImageStore(directory: d, loader: { u in c.hit(u); return Data(repeating: 1, count: 100) })
        _ = try await s.data(for: u1); _ = try await s.data(for: u1)
        XCTAssertEqual(c.count, 1)
        // New instance = cold memory: served from disk, still no network (persistence).
        let s2 = ImageStore(directory: d, loader: { u in c.hit(u); return Data() })
        let got = try await s2.data(for: u1)
        XCTAssertEqual(got.count, 100); XCTAssertEqual(c.count, 1)
        let diskCount = await s2.diskCount; XCTAssertEqual(diskCount, 1)
    }

    func testConcurrentRequestsCoalesce() async throws {
        let c = HitCounter()
        let s = ImageStore(directory: nil, loader: { u in c.hit(u); try await Task.sleep(nanoseconds: 80_000_000); return Data(repeating: 2, count: 10) })
        try await withThrowingTaskGroup(of: Int.self) { g in
            let u = u1
            for _ in 0..<12 { g.addTask { try await s.data(for: u).count } }
            for try await n in g { XCTAssertEqual(n, 10) }
        }
        XCTAssertEqual(c.count, 1)
        let nf = await s.networkFetches; XCTAssertEqual(nf, 1)
    }

    func testStaleServedImmediatelyThenRefreshed() async throws {
        let c = HitCounter(); let clock = TestClock(); let version = HitCounter()
        let s = ImageStore(directory: nil, ttl: 100, now: { clock.now }, loader: { u in c.hit(u); version.hit(u); return Data(repeating: UInt8(version.count), count: 5) })
        let first = try await s.data(for: u1); XCTAssertEqual(first.first, 1)
        clock.advance(500)
        let stale = try await s.data(for: u1)
        XCTAssertEqual(stale.first, 1, "stale bytes shown immediately, no wait")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(c.count, 2, "one background revalidation")
        let fresh = try await s.data(for: u1); XCTAssertEqual(fresh.first, 2)
        XCTAssertEqual(c.count, 2)
    }

    func testDiskBoundEvictsLeastRecentlyUsed() async throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }; let clock = TestClock()
        let s = ImageStore(directory: d, maxBytes: 1000, now: { clock.now }, loader: { _ in Data(repeating: 3, count: 240) })
        var urls: [URL] = []
        for i in 0..<8 { let u = URL(string: "https://a.ltrbxd.com/p/\(i).jpg")!; urls.append(u); _ = try await s.data(for: u); clock.advance(1) }
        let total = await s.diskBytes; XCTAssertLessThanOrEqual(total, 1000)
        let oldest = await s.cached(urls[0]); XCTAssertNil(oldest)
        let newest = await s.cached(urls[7]); XCTAssertNotNil(newest)
    }

    func testRejectsBadHostAndNeverFetches() async {
        let c = HitCounter(); let s = ImageStore(directory: nil, loader: { u in c.hit(u); return Data([1]) })
        do { _ = try await s.data(for: URL(string: "https://evil.com/a.jpg")!); XCTFail() } catch {}
        XCTAssertEqual(c.count, 0)
    }

    func testFailureNotCachedAndRetryable() async throws {
        let c = HitCounter()
        let s = ImageStore(directory: nil, loader: { u in c.hit(u); if c.count == 1 { throw LetterboxdError.network("x") }; return Data([9]) })
        do { _ = try await s.data(for: u1); XCTFail() } catch {}
        let ok = try await s.data(for: u1); XCTAssertEqual(ok, Data([9])); XCTAssertEqual(c.count, 2)
    }

    func testClearPurgesDiskAndMemory() async throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = ImageStore(directory: d, loader: { _ in Data([1, 2, 3]) })
        _ = try await s.data(for: u1); await s.clear()
        let hit = await s.cached(u1); XCTAssertNil(hit)
        let n = await s.diskCount; XCTAssertEqual(n, 0)
    }

    func testClearWhileInFlightDoesNotResurrect() async throws {
        let d = tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let s = ImageStore(directory: d, loader: { _ in try? await Task.sleep(nanoseconds: 120_000_000); return Data([4, 4]) })
        let u = u1
        let task = Task { try? await s.data(for: u) }
        try await Task.sleep(nanoseconds: 30_000_000)
        await s.clear(); _ = await task.value
        try await Task.sleep(nanoseconds: 100_000_000)
        let hit = await s.cached(u1); XCTAssertNil(hit)
        let n = await s.diskCount; XCTAssertEqual(n, 0)
    }

    func testUnwritableDirectoryFailsClosedToMemoryOnly() async throws {
        let s = ImageStore(directory: URL(fileURLWithPath: "/proc/nope/imgs"), loader: { _ in Data([5]) })
        let d = try await s.data(for: u1); XCTAssertEqual(d, Data([5]))
        let n = await s.diskCount; XCTAssertEqual(n, 0)
    }
}

final class ResponseCacheClearTests: XCTestCase {
    func testClearPurgesAndFencesLateSet() async {
        let c = ResponseCache(); let u = URL(string: "https://letterboxd.com/a/")!
        let e = await c.currentEpoch()
        await c.set(u, Data([1]), partition: 1, epoch: e)
        let hit = await c.get(u, partition: 1); XCTAssertNotNil(hit)
        await c.clear()
        let gone = await c.get(u, partition: 1); XCTAssertNil(gone)
        await c.set(u, Data([2]), partition: 1, epoch: e)   // started before clear
        let late = await c.get(u, partition: 1); XCTAssertNil(late, "late in-flight write must not resurrect")
        await c.set(u, Data([3]), partition: 1, epoch: await c.currentEpoch())
        let fresh = await c.get(u, partition: 1); XCTAssertNotNil(fresh)
    }
}
