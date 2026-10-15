import XCTest
@testable import LetterboxdKit

final class ContentRatingTests: XCTestCase {
    private func film(_ releases: String) throws -> FilmDetail {
        try Parsers.filmDetail(html: """
        <script type="application/ld+json">{"@type":"Movie","name":"Example","duration":"PT99M","contentRating":"R"}</script>
        \(releases)
        """, slug: "example")
    }
    private func release(_ country: String, _ rating: String, note: String = "") -> String {
        """
        <span class="release-country"><span class="details"><span class="name">\(country)</span><span class="release-certification-badge"><span class="label">\(rating)</span></span><span class="release-note">\(note)</span></span></span>
        """
    }
    func testCanadaPreferredRegardlessOfOrder() throws {
        XCTAssertEqual(try film(release("USA", "R") + release("Canada", "14A")).contentRating, "14A")
        XCTAssertEqual(try film(release("Canada", "14A") + release("USA", "R")).contentRating, "14A")
    }
    func testExplicitBritishColumbiaPreferred() throws {
        XCTAssertEqual(try film(release("Canada", "18A") + release("Canada", "14A", note: "British Columbia")).contentRating, "14A")
    }
    func testUSFallbackAndEmptyCanada() throws {
        XCTAssertEqual(try film(release("Canada", " ") + release("USA", "PG-13")).contentRating, "PG-13")
        XCTAssertEqual(try film(release("United States", "PG")).contentRating, "PG")
    }
    func testNoUnscopedOrOtherTerritoryRating() throws {
        XCTAssertNil(try film(release("United Kingdom", "18") + "<span class='release-certification-badge'><span class='label'>R</span></span>").contentRating)
        XCTAssertNil(try film("").contentRating)
    }
    func testMissingBadgeDoesNotTakeNextCountryRating() throws {
        XCTAssertEqual(try film("<span class='release-country'><span class='name'>Canada</span></span>" + release("USA", "R")).contentRating, "R")
    }
    func testRatingRoundTripAndOlderCache() throws {
        let detail = try film(release("Canada", "14A"))
        let data = try JSONEncoder().encode(detail)
        XCTAssertEqual(try JSONDecoder().decode(FilmDetail.self, from: data).contentRating, "14A")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "contentRating")
        XCTAssertNil(try JSONDecoder().decode(FilmDetail.self, from: JSONSerialization.data(withJSONObject: json)).contentRating)
    }
}
