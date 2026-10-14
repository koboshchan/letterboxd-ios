import Foundation
import LetterboxdKit

/// Deterministic data for UI tests and screenshots ONLY. Enabled solely by the -UIFixtureMode launch argument
/// and always marked with an orange banner. Never used by default.
struct FixtureService: LetterboxdService {
    static let films: [FilmSummary] = [
        ("your-name", "Your Name.", 2016), ("paprika-2006", "Paprika", 2006), ("the-truman-show", "The Truman Show", 1998),
        ("a-minecraft-movie", "A Minecraft Movie", 2025), ("k-on-the-movie", "K-On! The Movie", 2011),
        ("parasite-2019", "Parasite", 2019), ("spirited-away", "Spirited Away", 2001), ("perfect-blue", "Perfect Blue", 1997), ("akira", "Akira", 1988)
    ].map { FilmSummary(slug: $0.0, title: $0.1, year: $0.2) }
    func profile(username: String, refresh: Bool) async throws -> Profile { Profile(username: username, displayName: "Fixture Member", avatarURL: nil, bio: nil, filmCount: 9, followingCount: 1, followersCount: 1) }
    func films(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> { Page(items: Self.films, page: 1, hasNext: false) }
    func watchlist(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> { Page(items: [], page: 1, hasNext: false) }
    func diary(username: String, refresh: Bool) async throws -> [ActivityEntry] {
        [ActivityEntry(link: URL(string: "https://letterboxd.com/fixture/film/your-name/")!, filmTitle: "Your Name.", filmYear: 2016, rating: 4.5, watchedDate: Date(timeIntervalSince1970: 1_790_000_000), rewatch: true, review: "Beautiful and sad in all the right ways.", posterURL: nil),
         ActivityEntry(link: URL(string: "https://letterboxd.com/fixture/film/paprika-2006/")!, filmTitle: "Paprika", filmYear: 2006, rating: 4, watchedDate: Date(timeIntervalSince1970: 1_789_000_000), rewatch: false, review: nil, posterURL: nil)]
    }
    func reviews(username: String, refresh: Bool) async throws -> [ActivityEntry] { try await diary(username: username, refresh: refresh).filter { $0.review != nil } }
    func lists(username: String, page: Int, refresh: Bool) async throws -> Page<ListSummary> { Page(items: [], page: 1, hasNext: false) }
    func browse(_ kind: BrowseKind, page: Int, refresh: Bool) async throws -> Page<FilmSummary> { Page(items: Self.films.reversed(), page: 1, hasNext: false) }
    func film(slug: String, refresh: Bool) async throws -> FilmDetail {
        FilmDetail(slug: slug, title: "Fixture Film", year: 2016, tagline: "A deterministic tagline", synopsis: "Fixture synopsis used only for UI tests.", posterURL: nil, runtimeMinutes: 107, directors: [Person(name: "Fixture Director", url: nil)], cast: [Person(name: "Actor One", url: nil), Person(name: "Actor Two", url: nil)], genres: [], averageRating: 4.1, ratingCount: 10)
    }
    func searchFilms(query: String, page: Int) async throws -> Page<FilmSummary> { Page(items: Self.films.filter { $0.title.localizedCaseInsensitiveContains(query) }, page: 1, hasNext: false) }
    func searchMembers(query: String, page: Int) async throws -> Page<MemberSummary> { Page(items: [MemberSummary(username: "fixture", displayName: "Fixture Member", avatarURL: nil)], page: 1, hasNext: false) }
    func poster(for slug: String) async -> URL? { nil }
}
