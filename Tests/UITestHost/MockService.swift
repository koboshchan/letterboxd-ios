import Foundation
import LetterboxdKit

/// Deterministic mock data layer for the UI-test host. Records nothing and writes nothing.
final class MockService: LetterboxdService, @unchecked Sendable {
    let sc: Scenario
    private let l = NSLock(); private var failedOnce = false
    init(_ sc: Scenario) { self.sc = sc }
    private func maybeFail() throws {
        guard sc.failFirst else { return }
        l.lock(); defer { l.unlock() }
        if !failedOnce { failedOnce = true; throw LetterboxdError.http(status: 500) }
    }
    private func films(_ prefix: String, _ n: Int, offset: Int = 0) -> [FilmSummary] { (0..<n).map { FilmSummary(slug: "\(prefix.lowercased())-\($0 + offset)", title: "\(prefix) \($0 + offset)", year: 2000 + $0) } }
    func profile(username: String, refresh: Bool) async throws -> Profile {
        Profile(username: username, displayName: username == "tester" ? "Tester Person" : "Member \(username)", avatarURL: nil, bio: nil, filmCount: 3, followingCount: 2, followersCount: 1)
    }
    func films(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        return Page(items: films("Logged", 3), page: 1, hasNext: false)
    }
    func watchlist(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        return Page(items: films("Wanted", 2), page: 1, hasNext: false)
    }
    private var entry: ActivityEntry { ActivityEntry(link: URL(string: "https://letterboxd.com/tester/film/diary-film/")!, filmTitle: "Diary Film", filmYear: 1999, rating: 4, watchedDate: Date(timeIntervalSince1970: 1_700_000_000), rewatch: false, review: "Great mock review text", posterURL: nil) }
    func diary(username: String, refresh: Bool) async throws -> [ActivityEntry] { sc.empty ? [] : [entry] }
    func reviews(username: String, refresh: Bool) async throws -> [ActivityEntry] { sc.empty ? [] : [entry] }
    func lists(username: String, page: Int, refresh: Bool) async throws -> Page<ListSummary> {
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        return Page(items: [ListSummary(title: "Mock List", url: URL(string: "https://letterboxd.com/tester/list/mock-list/")!, filmCount: 4, blurb: "A list")], page: 1, hasNext: false)
    }
    func browse(_ kind: BrowseKind, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        try maybeFail()
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        let prefix = ["popular": "Popular", "topRated": "Rated", "anticipated": "Soon"][kind.rawValue]!
        if page == 1 {
            var items = films(prefix, 30)
            if refresh { items.insert(FilmSummary(slug: "refreshed", title: "Refreshed Film", year: 2024), at: 0) }
            return Page(items: items, page: 1, hasNext: kind == .popular)
        }
        return Page(items: films("Late", 3, offset: 30), page: page, hasNext: false)
    }
    func film(slug: String, refresh: Bool) async throws -> FilmDetail {
        try maybeFail()
        return FilmDetail(slug: slug, title: slug, year: 2001, tagline: "A tagline", synopsis: "Synopsis for \(slug)", posterURL: nil, runtimeMinutes: 99, directors: [Person(name: "Dana Director", url: nil)], cast: [Person(name: "Cam Cast", url: nil)], genres: [], averageRating: 3.5, ratingCount: 10, credits: sc.empty ? [] : [Credit(name: "Dana Director", role: .director, slug: "dana-director"), Credit(name: "Cam Cast", role: .actor, slug: "cam-cast"), Credit(name: "Wes Writer", role: .writer, slug: "wes-writer")])
    }
    func searchFilms(query: String, page: Int) async throws -> Page<FilmSummary> {
        if query.lowercased().contains("nothing") { return Page(items: [], page: 1, hasNext: false) }
        if query.lowercased().contains("boom") { throw LetterboxdError.network("mock offline") }
        return Page(items: [FilmSummary(slug: "found-film", title: "Found Film", year: 2010)], page: 1, hasNext: false)
    }
    func personFilms(role: PersonRole, slug: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        Page(items: [FilmSummary(slug: "found-film", title: "Found Film", year: 2010)], page: 1, hasNext: false)
    }
    func filmReviews(slug: String, page: Int, refresh: Bool) async throws -> Page<FilmReview> {
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        return Page(items: [FilmReview(link: URL(string: "https://letterboxd.com/rev/film/\(slug)/")!, author: "Rae Reviewer", username: "rae", rating: 4, text: "Mock review body", date: nil, fullTextPath: nil)], page: 1, hasNext: false)
    }
    func filmLists(slug: String, page: Int, refresh: Bool) async throws -> Page<ListSummary> {
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        return Page(items: [ListSummary(title: "Film List", url: URL(string: "https://letterboxd.com/lee/list/film-list/")!, filmCount: 5, blurb: nil)], page: 1, hasNext: false)
    }
    func personPortrait(role: PersonRole, slug: String) async -> URL? { nil }
   func following(username: String, page: Int, refresh: Bool) async throws -> Page<MemberSummary> { try network("friend", username, page) }
    func followers(username: String, page: Int, refresh: Bool) async throws -> Page<MemberSummary> { try network("fan", username, page) }
    private func network(_ p: String, _ u: String, _ page: Int) throws -> Page<MemberSummary> {
        if sc.empty { return Page(items: [], page: 1, hasNext: false) }
        if page == 2 { return Page(items: [MemberSummary(username: p + "-late", displayName: p + " late", avatarURL: nil)], page: 2, hasNext: false) }
        return Page(items: (0..<14).map { MemberSummary(username: "\(p)-\($0)", displayName: "\(u == "tester" ? "" : u + " ")\(p) \($0)", avatarURL: nil) }, page: 1, hasNext: true)
    }
    func poster(for slug: String) async -> URL? { nil }
}
