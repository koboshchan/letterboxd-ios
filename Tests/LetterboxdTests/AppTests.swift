import XCTest
@testable import Letterboxd
import LetterboxdKit

@MainActor
final class AppTests: XCTestCase {
    func testLiveIsDefaultAndFixtureOnlyByArgument() {
        XCTAssertFalse(AppEnvironment.make().isFixtureMode)
        XCTAssertFalse(AppEnvironment.make().service is FixtureService)
    }
    func testPagedLoaderAppendsWithoutDuplicates() async {
        let l = PagedLoader<FilmSummary> { p, _ in
            Page(items: p == 1 ? [FilmSummary(slug: "a", title: "A", year: nil)] : [FilmSummary(slug: "a", title: "A", year: nil), FilmSummary(slug: "b", title: "B", year: nil)], page: p, hasNext: p == 1) }
        await l.loadFirst(); XCTAssertEqual(l.items.count, 1)
        await l.loadMore(current: l.items[0]); XCTAssertEqual(l.items.map(\.slug), ["a", "b"])
    }
    func testPagedLoaderSurfacesBlockedError() async {
        let l = PagedLoader<FilmSummary> { _, _ in throw LetterboxdError.blocked(status: 403) }
        await l.loadFirst(); XCTAssertEqual(l.error, .blocked(status: 403)); XCTAssertTrue(l.items.isEmpty)
    }
    func testEmptyIsDistinctFromError() async {
        let l = PagedLoader<FilmSummary> { p, _ in Page(items: [], page: p, hasNext: false) }
        await l.loadFirst(); XCTAssertTrue(l.isEmptyLoaded); XCTAssertNil(l.error)
    }
}
