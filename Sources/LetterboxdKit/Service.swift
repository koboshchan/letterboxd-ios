import Foundation

/// Replaceable data layer. The app depends on this protocol only.
public protocol LetterboxdService: Sendable {
    func profile(username: String, refresh: Bool) async throws -> Profile
    func films(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary>
    func watchlist(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary>
    func diary(username: String, refresh: Bool) async throws -> [ActivityEntry]
    func reviews(username: String, refresh: Bool) async throws -> [ActivityEntry]
    func lists(username: String, page: Int, refresh: Bool) async throws -> Page<ListSummary>
    func browse(_ kind: BrowseKind, page: Int, refresh: Bool) async throws -> Page<FilmSummary>
    func film(slug: String, refresh: Bool) async throws -> FilmDetail
    func searchFilms(query: String, page: Int) async throws -> Page<FilmSummary>
    func searchMembers(query: String, page: Int) async throws -> Page<MemberSummary>
    func poster(for slug: String) async -> URL?
}

/// Live adapter: public RSS for diary/reviews, public HTML for the rest. GET only, no login,
/// no background crawling, no challenge bypass. Letterboxd's official API is approval-only
/// and is NOT used here.
public final class PublicWebService: LetterboxdService {
    let fetcher: Fetcher
    let base = URL(string: "https://letterboxd.com")!
    public init(fetcher: Fetcher = Fetcher()) { self.fetcher = fetcher }
    public var auth: AuthAuthority { fetcher.auth }

    private func url(_ parts: [String], page: Int = 1, query: [URLQueryItem] = []) -> URL {
        var u = base
        for p in parts { u.appendPathComponent(p) }
        if page > 1 { u.appendPathComponent("page"); u.appendPathComponent(String(page)) }
        u.appendPathComponent("")   // trailing slash
        if !query.isEmpty { var c = URLComponents(url: u, resolvingAgainstBaseURL: false)!; c.queryItems = query; return c.url! }
        return u
    }
    public func profile(username: String, refresh: Bool) async throws -> Profile {
        let u = try Validate.username(username)
        return try Parsers.profile(html: try await fetcher.text(url([u]), forceRefresh: refresh), username: u)
    }
    public func films(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        let u = try Validate.username(username)
        return try Parsers.filmGrid(html: try await fetcher.text(url([u, "films"], page: page), forceRefresh: refresh), page: page)
    }
    public func watchlist(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        let u = try Validate.username(username)
        return try Parsers.filmGrid(html: try await fetcher.text(url([u, "watchlist"], page: page), forceRefresh: refresh), page: page)
    }
    public func diary(username: String, refresh: Bool) async throws -> [ActivityEntry] {
        let u = try Validate.username(username)
        return try RSSParser.parse(Data(try await fetcher.text(url([u, "rss"]), accept: "application/rss+xml", forceRefresh: refresh).utf8)).filter { $0.watchedDate != nil && !$0.isListEntry }
    }
    public func reviews(username: String, refresh: Bool) async throws -> [ActivityEntry] {
        try await diary(username: username, refresh: refresh).filter { ($0.review ?? "").isEmpty == false }
    }
    public func lists(username: String, page: Int, refresh: Bool) async throws -> Page<ListSummary> {
        let u = try Validate.username(username)
        return try Parsers.lists(html: try await fetcher.text(url([u, "lists"], page: page), forceRefresh: refresh), page: page)
    }
    public func browse(_ kind: BrowseKind, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        // Popular lists are server-side fragments (csi) of the browse page.
        let seg: [String]
        switch kind {
        case .popular: seg = ["csi", "films", "films-browser-list", "popular"]
        case .topRated: seg = ["csi", "films", "films-browser-list", "by", "rating"]
        case .anticipated: seg = ["csi", "films", "films-browser-list", "popular", "this", "week"]
        }
        return try Parsers.filmGrid(html: try await fetcher.text(url(seg, page: page), forceRefresh: refresh), page: page)
    }
    public func film(slug: String, refresh: Bool) async throws -> FilmDetail {
        let s = try Validate.slug(slug)
        return try Parsers.filmDetail(html: try await fetcher.text(url(["film", s]), forceRefresh: refresh), slug: s)
    }
    public func searchFilms(query: String, page: Int) async throws -> Page<FilmSummary> {
        let q = try Self.cleanQuery(query)
        return try Parsers.filmGrid(html: try await fetcher.text(url(["s", "search", "films", q], page: page)), page: page)
    }
    public func searchMembers(query: String, page: Int) async throws -> Page<MemberSummary> {
        let q = try Self.cleanQuery(query)
        return try Parsers.members(html: try await fetcher.text(url(["s", "search", "members", q], page: page)), page: page)
    }
    public func poster(for slug: String) async -> URL? {
        guard let s = try? Validate.slug(slug), let h = try? await fetcher.text(url(["film", s])) else { return nil }
        return Parsers.ogImage(html: h)
    }
    static func cleanQuery(_ q: String) throws -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 100, !t.contains("/") else { throw LetterboxdError.invalidInput("query") }
        return t
    }
}
