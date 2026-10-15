import XCTest
@testable import LetterboxdKit

/// Sanitized structural fixtures derived from live read-only diary/reviews captures.
final class MemberEntriesTests: XCTestCase {
    func testDiaryIncludesUnreviewedAndRepeatedWatchesWithFullDates() throws {
        let p = try Parsers.memberDiary(html: fixtureText("member-diary", "html"), page: 1)
        XCTAssertEqual(p.items.count, 2)
        XCTAssertTrue(p.hasNext)
        XCTAssertTrue(p.items[0].rewatch)
        XCTAssertFalse(p.items[1].rewatch, "off cells still contain the rewatch icon")
        XCTAssertEqual(p.items[0].rating, 4.5)
        XCTAssertNil(p.items[1].rating)
        XCTAssertTrue(p.items.allSatisfy { $0.review == nil && $0.watchedDate != nil })
        XCTAssertNotEqual(p.items[0].id, p.items[1].id, "rewatches must not collapse by film")
        XCTAssertGreaterThan(p.items[0].watchedDate!, p.items[1].watchedDate!)
    }
    func testReviewsOnlyWrittenTextAndUsesViewingNotFilmLink() throws {
        let p = try Parsers.memberReviews(html: fixtureText("member-reviews", "html"), page: 1)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.items[0].review, "Synthetic review text.")
        XCTAssertEqual(p.items[0].link.path, "/example-member/film/example-film/2")
        XCTAssertEqual(p.items[0].rating, 4.5)
        XCTAssertTrue(p.items[0].rewatch)
        XCTAssertNil(p.items[0].posterURL)
        XCTAssertTrue(p.hasNext)
    }
    func testServiceUsesSeparateHTMLSourcesAndPaging() async throws {
        let diary = try fixtureText("member-diary", "html"), reviews = try fixtureText("member-reviews", "html")
        let svc = PublicWebService(fetcher: Fetcher(transport: StubTransport { url in
            let p = url.path
            XCTAssertFalse(p.contains("rss"))
            guard p == "/example-member/diary/films/page/2" || p == "/example-member/reviews/films/page/2" else {
                XCTFail("unexpected path \(p)"); throw LetterboxdError.notFound
            }
            return HTTPResult(data: Data((p.contains("/diary/") ? diary : reviews).utf8), status: 200)
        }))
        let d = try await svc.diaryPage(username: "example-member", page: 2, refresh: true)
        let r = try await svc.reviewsPage(username: "example-member", page: 2, refresh: true)
        XCTAssertEqual(d.items.count, 2); XCTAssertEqual(r.items.count, 1)
        XCTAssertEqual(d.page, 2); XCTAssertEqual(r.page, 2)
    }
    func testLazyPosterAndCanonicalSlugFallback() throws {
        let html = try fixtureText("member-reviews", "html")
        let lazy = html.replacingOccurrences(of: "<img src=", with: "<img data-src=\"https://a.ltrbxd.com/real-poster.jpg\" src=")
        let entry = try XCTUnwrap(Parsers.memberReviews(html: lazy, page: 1).items.first)
        XCTAssertEqual(entry.posterURL?.absoluteString, "https://a.ltrbxd.com/real-poster.jpg")
        XCTAssertEqual(entry.filmSlug, "example-film")
        let missing = try Parsers.memberReviews(html: html, page: 1).items[0]
        XCTAssertNil(missing.posterURL)
        XCTAssertEqual(missing.filmSlug, "example-film")
        let diary = try Parsers.memberDiary(html: fixtureText("member-diary", "html"), page: 1)
        XCTAssertEqual(diary.items.map(\.filmSlug), ["example-film", "example-film"])
        let hostile = ActivityEntry(link: URL(string: "https://evil.example/tester/film/example/")!, filmTitle: "X", filmYear: nil, rating: nil, watchedDate: nil, rewatch: false, review: nil, posterURL: nil)
        XCTAssertNil(hostile.filmSlug)
    }
    func testPersonDetailsSanitizedFixture() {
        let details = Parsers.personDetails(html: """
        <img class="js-tmdb-person" data-image="https://image.tmdb.org/t/p/w500/example.jpg">
        <div id="content-nav"><ul class="smenu-menu"><li class="smenu-subselected"><span>Actor <small>1,234</small></span></li><li><a>Producer <small>2</small></a></li></ul></div>
        <div class="js-tmdb-bio"><p>Example biography.</p><p>Second paragraph.</p></div>
        """)
        XCTAssertEqual(details.filmCount, 1234)
        XCTAssertEqual(details.roles, ["Actor", "Producer"])
        XCTAssertEqual(details.biography, "Example biography.\n\nSecond paragraph.")
        XCTAssertEqual(details.portraitURL?.host, "image.tmdb.org")
        XCTAssertNil(Parsers.personDetails(html: "<html></html>").biography)
    }
    func testEmptyAndHostileLinks() throws {
        XCTAssertTrue(try Parsers.memberDiary(html: "<table></table>", page: 1).items.isEmpty)
        XCTAssertTrue(try Parsers.memberReviews(html: "<html></html>", page: 1).items.isEmpty)
        let h = try fixtureText("member-diary", "html").replacingOccurrences(of: "data-target-link=\"/example-member/", with: "data-target-link=\"https://evil.example/")
        XCTAssertTrue(try Parsers.memberDiary(html: h, page: 1).items.isEmpty)
    }
}
