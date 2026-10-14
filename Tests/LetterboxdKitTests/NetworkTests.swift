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
}
