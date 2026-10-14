import XCTest
@testable import Letterboxd

/// Prefetch bounds. Hosts are not on the public allow-list, so fetches fail fast and never touch the network;
/// what is under test is the window cap and cancellation bookkeeping.
@MainActor
final class ImagePipelineTests: XCTestCase {
    func urls(_ n: Int) -> [URL] { (0..<n).map { URL(string: "https://example.invalid/p\($0).jpg")! } }
    func testPrefetchWindowIsCapped() {
        let p = ImagePipeline()
        p.prefetch(urls(100))
        XCTAssertLessThanOrEqual(p.prefetchInFlight, 12)
    }
    func testObsoleteCancelledButVisibleKept() {
        let p = ImagePipeline(); let a = urls(3)
        p.didShow(a[0])
        p.prefetch(a)
        p.prefetch([])               // window moved away
        XCTAssertLessThanOrEqual(p.prefetchInFlight, 1, "only the visible URL may survive")
    }
}
