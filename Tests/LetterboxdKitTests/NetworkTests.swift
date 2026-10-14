import XCTest
@testable import LetterboxdKit

final class NetworkTests: XCTestCase {
    func testFollowingRowsParseAndPageLinkDetected() throws {
        let p = try Parsers.members(html: try fixtureText("network-members", "html"), page: 1)
        XCTAssertEqual(p.items.map(\.username), ["member-one", "member_two"])
        XCTAssertEqual(p.items[0].displayName, "Member One")
        XCTAssertNotNil(p.items[0].avatarURL)
        XCTAssertTrue(p.hasNext)
    }
    func testEmptyNetworkPageHasNoItems() throws {
        let p = try Parsers.members(html: "<html><body><table></table></body></html>", page: 1)
        XCTAssertTrue(p.items.isEmpty); XCTAssertFalse(p.hasNext)
    }
    func testRejectsHostileHrefs() throws {
        let h = #"<div class="person-summary"><a href="https://evil.example/x/" class="name">Evil</a></div><div class="person-summary"><a href="/../etc/" class="name">Bad</a></div>"#
        XCTAssertTrue(try Parsers.members(html: h, page: 1).items.isEmpty)
    }

    /// Row markup copied from a real GET of /koboshchan/following/ (public page, single member row, follow-button cell removed).
    func testRealFollowingRowShape() throws {
        let p = try Parsers.members(html: try fixtureText("real-following-row", "html"), page: 1)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.items[0].username, "vertsdu"); XCTAssertEqual(p.items[0].displayName, "vertsdu")
        XCTAssertEqual(p.items[0].avatarURL?.host, "a.ltrbxd.com")
    }

    /// First six tiles of a real GET /actor/brad-pitt/ page.
    func testRealActorFilmographyGrid() throws {
        let p = try Parsers.filmGrid(html: try fixtureText("real-actor-grid", "html"), page: 1)
        XCTAssertEqual(p.items.count, 6); XCTAssertEqual(p.items.first?.slug, "fight-club")
        XCTAssertEqual(Set(p.items.map(\.slug)).count, 6, "no duplicates")
    }
    func testPersonLinkValidation() throws {
        let ok = try Validate.personLink(URL(string: "https://letterboxd.com/actor/brad-pitt/")!)
        XCTAssertEqual(ok.role, .actor); XCTAssertEqual(ok.slug, "brad-pitt")
        for bad in ["https://evil.example/actor/brad-pitt/", "http://letterboxd.com/actor/brad-pitt/", "https://letterboxd.com:8443/actor/x/",
                    "https://letterboxd.com/film/fight-club/", "https://letterboxd.com/actor/x/y/", "https://letterboxd.com/actor/..%2Fx/",
                    "https://letterboxd.com/actor/brad-pitt/?a=1", "https://u@letterboxd.com/actor/x/"] {
            XCTAssertThrowsError(try Validate.personLink(URL(string: bad)!), bad)
        }
    }

    func testRealFilmCredits() throws {
        let c = Parsers.credits(html: try fixtureText("real-film-credits", "html"))
        XCTAssertTrue(c.contains(Credit(name: "David Fincher", role: .director, slug: "david-fincher")))
        XCTAssertTrue(c.contains { $0.role == .actor && $0.slug == "brad-pitt" && $0.name == "Brad Pitt" })
        XCTAssertEqual(Set(c.map(\.id)).count, c.count, "deduped")
        XCTAssertFalse(c.contains { $0.name.hasPrefix("Show All") })
    }
    func testCreditsDropHostileLinks() {
        let h = #"<a class="text-slug" href="https://evil.example/actor/x/">Evil</a><a class="text-slug" href="/film/x/">Film</a><a class="text-slug" href="/actor/ok-one/">Ok</a>"#
        XCTAssertEqual(Parsers.credits(html: h).map(\.slug), ["ok-one"])
    }
    func testPersonName() throws {
        XCTAssertEqual(Parsers.personName(html: #"<meta property="og:title" content="Films starring Brad Pitt">"#), "Brad Pitt")
    }
}
