import XCTest
@testable import LetterboxdKit
final class RatingReadbackContractTests: XCTestCase {
    func testRatingHalfStarMarksWatchedAndClearKeepsWatched() async throws {
        let s = RState(); let a = AuthAuthority(); a.setValidated(Session(username: "t", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")]))
        let f = FilmActions(transport: RT(st: s), auth: a)
        let r = try await f.setRating(slug: "x", rating: 0.5); XCTAssertEqual(r, RatingState(rating: 0.5, watched: true))
        let c = try await f.setRating(slug: "x", rating: nil); XCTAssertEqual(c, RatingState(rating: nil, watched: true))
        let u = try await f.setWatched(slug: "x", watched: false); XCTAssertEqual(u, RatingState(rating: nil, watched: false))
    }
}
