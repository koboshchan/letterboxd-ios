import XCTest
@testable import LetterboxdKit

final class ProfileStatsTests: XCTestCase {
    func testProfileFollowerCountSingularZeroManyMissing() throws {
        func p(_ n: String) throws -> Profile { try Parsers.profile(html: try fixtureText(n, "html"), username: "example-member") }
        let one = try p("real-profile-stats-one")
        XCTAssertEqual(one.filmCount, 8); XCTAssertEqual(one.followingCount, 1)
        XCTAssertEqual(one.followersCount, 1, "singular 'Follower' label must still parse")
        let zero = try p("real-profile-stats-zero")
        XCTAssertEqual(zero.followersCount, 0); XCTAssertEqual(zero.followingCount, 0)
        let many = try p("real-profile-stats-many")
        XCTAssertEqual(many.followersCount, 1234); XCTAssertEqual(many.filmCount, 168)
        let missing = try p("real-profile-stats-missing")
        XCTAssertNil(missing.followersCount); XCTAssertNil(missing.followingCount); XCTAssertEqual(missing.filmCount, 8)
    }
}
