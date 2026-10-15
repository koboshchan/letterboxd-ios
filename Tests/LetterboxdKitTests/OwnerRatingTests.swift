import XCTest
@testable import LetterboxdKit

final class OwnerRatingTests: XCTestCase {
    private func cell(_ slug: String, _ viewing: String) -> String {
        "<li class=\"griditem\"><div class=\"viewing-poster-container\"><div class=\"react-component\" data-item-slug=\"\(slug)\" data-item-name=\"\(slug) (2000)\" data-item-full-display-name=\"\(slug) (2000)\"></div><p class=\"poster-viewingdata\">\(viewing)</p></div></li>"
    }
    private var html: String {
        "<ul>" + cell("half", "<span class=\"rating rated-9\"> x </span><span class=\"rating liked\"></span>")
        + cell("whole", "<span class=\"rating rated-6\"></span>") + cell("lowest", "<span class=\"rating rated-1\"></span>")
        + cell("unrated", "<span class=\"rating liked\"></span>") + cell("bad", "<span class=\"rating rated-11\"></span>") + "</ul>"
    }
    func testOwnerRatingsParsedWithHalfStarsAndUnrated() throws {
        let items = try Parsers.filmGrid(html: html, page: 1, ownerRatings: true).items
        XCTAssertEqual(items.map(\.ownerRating), [4.5, 3, 0.5, nil, nil])
        XCTAssertEqual(items.map(\.ownerRatingLabel), ["\u{2605}4.5", "\u{2605}3", "\u{2605}0.5", nil, nil])
    }
    func testOtherGridsNeverCarryRatings() throws {
        XCTAssertTrue(try Parsers.filmGrid(html: html, page: 1).items.allSatisfy { $0.ownerRating == nil })
    }
    func testRatingSurvivesCacheCodableAndOldEntriesDecode() throws {
        let f = FilmSummary(slug: "a", title: "A", year: 2000, ownerRating: 3.5)
        XCTAssertEqual(try JSONDecoder().decode(FilmSummary.self, from: JSONEncoder().encode(f)).ownerRating, 3.5)
        let old = #"{"slug":"a","title":"A"}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(FilmSummary.self, from: old).ownerRating)
    }
    func testCacheKeyedPerOwnerSoRatingsNeverCross() async throws {
        let rs = ReadStore(directory: nil); let e = rs.currentEpoch()
        let mine = CachedPage(items: [FilmSummary(slug: "a", title: "A", year: nil, ownerRating: 5)], page: 1, hasNext: false)
        rs.set(mine, ns: "viewer", key: "films2-viewer-1", epoch: e)
        XCTAssertNil(rs.get(CachedPage<FilmSummary>.self, ns: "viewer", key: "films2-other-1"))
        XCTAssertEqual(rs.get(CachedPage<FilmSummary>.self, ns: "viewer", key: "films2-viewer-1")?.items.first?.ownerRating, 5)
    }
}
