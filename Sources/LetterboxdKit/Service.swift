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
    func following(username: String, page: Int, refresh: Bool) async throws -> Page<MemberSummary>
    func followers(username: String, page: Int, refresh: Bool) async throws -> Page<MemberSummary>
    func filmReviews(slug: String, page: Int, refresh: Bool) async throws -> Page<FilmReview>
    func fullReviewText(path: String) async throws -> String
    func entryReviewText(link: URL) async throws -> String
    func listFilms(list: URL, page: Int, refresh: Bool) async throws -> Page<FilmSummary>
    func filmLists(slug: String, page: Int, refresh: Bool) async throws -> Page<ListSummary>
    func personFilms(role: PersonRole, slug: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary>
    func personPortrait(role: PersonRole, slug: String) async -> URL?
    func poster(for slug: String) async -> URL?
}

/// Live adapter: public RSS for diary/reviews, public HTML for the rest. GET only, no login,
/// no background crawling, no challenge bypass. Letterboxd's official API is approval-only
/// and is NOT used here.
public final class PublicWebService: LetterboxdService {
    let fetcher: Fetcher
    let base = URL(string: "https://letterboxd.com")!
    let reads: ReadStore?
    public init(fetcher: Fetcher = Fetcher(), reads: ReadStore? = nil) { self.fetcher = fetcher; self.reads = reads }
    /// Read-through for the signed-in member only. Skipped when signed out or on pull-to-refresh (which still refills it).
    private func cached<T: Codable & Sendable>(_ type: T.Type, key: String, refresh: Bool, _ load: () async throws -> T) async throws -> T {
        guard let reads, let ns = auth.username else { return try await load() }
        let g = auth.generation, e = await reads.currentEpoch()
        if !refresh, let v = await reads.get(T.self, ns: ns, key: key), auth.generation == g { return v }
        let v = try await load()
        guard auth.generation == g else { throw LetterboxdError.cancelled }
        await reads.set(v, ns: ns, key: key, epoch: e)
        return v
    }
    /// A write happened: drop dependent reads so the next view is fresh.
    public func invalidateReads() async { if let ns = auth.username { await reads?.invalidate(ns: ns, prefix: "") } }
    public var auth: AuthAuthority { fetcher.auth }
    public func clearCaches() async { await fetcher.clearCache(); await reads?.clear() }

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
        return try await cached(Profile.self, key: "profile-\(u)", refresh: refresh) { try Parsers.profile(html: try await fetcher.text(url([u]), forceRefresh: refresh), username: u) }
    }
    public func films(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        let u = try Validate.username(username)
        let c = try await cached(CachedPage<FilmSummary>.self, key: "films-\(u)-\(page)", refresh: refresh) { let p = try Parsers.filmGrid(html: try await fetcher.text(url([u, "films"], page: page), forceRefresh: refresh), page: page); return CachedPage(items: p.items, page: p.page, hasNext: p.hasNext) }
        return Page(items: c.items, page: c.page, hasNext: c.hasNext)
    }
    public func watchlist(username: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        let u = try Validate.username(username)
        let c = try await cached(CachedPage<FilmSummary>.self, key: "watchlist-\(u)-\(page)", refresh: refresh) { let p = try Parsers.filmGrid(html: try await fetcher.text(url([u, "watchlist"], page: page), forceRefresh: refresh), page: page); return CachedPage(items: p.items, page: p.page, hasNext: p.hasNext) }
        return Page(items: c.items, page: c.page, hasNext: c.hasNext)
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
    public func personFilms(role: PersonRole, slug: String, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        let s = try Validate.slug(slug)
        return try Parsers.filmGrid(html: try await fetcher.text(url([role.rawValue, s], page: page), forceRefresh: refresh), page: page)
    }
    public func fullReviewText(path: String) async throws -> String {
        guard let u = URL(string: "https://letterboxd.com" + (try Validate.fullTextPath(path))) else { throw LetterboxdError.invalidInput("path") }
        return try Parsers.fullText(html: try await fetcher.text(try Validate.url(u), accept: "text/html"))
    }
    public func entryReviewText(link: URL) async throws -> String {
        let page = try Validate.reviewPage(link)
        let path = try Parsers.reviewFullTextPath(html: try await fetcher.text(page, accept: "text/html"))
        return try await fullReviewText(path: path)
    }
    public func filmReviews(slug: String, page: Int, refresh: Bool) async throws -> Page<FilmReview> {
        let s = try Validate.slug(slug)
        return try Parsers.filmReviews(html: try await fetcher.text(url(["film", s, "reviews"], page: page), forceRefresh: refresh), page: page)
    }
    public func listFilms(list: URL, page: Int, refresh: Bool) async throws -> Page<FilmSummary> {
        let (u, s) = try Validate.listPath(list)
        return try Parsers.filmGrid(html: try await fetcher.text(url([u, "list", s], page: page), forceRefresh: refresh), page: page)
    }
    public func filmLists(slug: String, page: Int, refresh: Bool) async throws -> Page<ListSummary> {
        let s = try Validate.slug(slug)
        return try Parsers.lists(html: try await fetcher.text(url(["film", s, "lists"], page: page), forceRefresh: refresh), page: page)
    }
    public func personPortrait(role: PersonRole, slug: String) async -> URL? {
        guard let s = try? Validate.slug(slug), let h = try? await fetcher.text(url([role.rawValue, s]), forceRefresh: false) else { return nil }
        return Parsers.personPortrait(html: h)
    }
    public func film(slug: String, refresh: Bool) async throws -> FilmDetail {
        let s = try Validate.slug(slug)
        return try Parsers.filmDetail(html: try await fetcher.text(url(["film", s]), forceRefresh: refresh), slug: s)
    }
    public func searchFilms(query: String, page: Int) async throws -> Page<FilmSummary> {
        let q = try Self.cleanQuery(query)
        return try Parsers.filmGrid(html: try await fetcher.text(url(["s", "search", "films", q], page: page)), page: page)
    }
   /// Real pages observed: /{user}/following/ and /{user}/followers/ (table of .person-summary rows, a.next paging).
    public func following(username: String, page: Int, refresh: Bool) async throws -> Page<MemberSummary> {
        let u = try Validate.username(username)
        return try Parsers.members(html: try await fetcher.text(url([u, "following"], page: page), forceRefresh: refresh), page: page)
    }
    public func followers(username: String, page: Int, refresh: Bool) async throws -> Page<MemberSummary> {
        let u = try Validate.username(username)
        return try Parsers.members(html: try await fetcher.text(url([u, "followers"], page: page), forceRefresh: refresh), page: page)
    }
    public func poster(for slug: String) async -> URL? {
        guard let s = try? Validate.slug(slug) else { return nil }
        // Grid posters are lazy: the site serves them from a small JSON endpoint (observed in the saved-profile capture).
        if let j = try? await fetcher.text(url(["film", s, "poster", "std", "230"]), accept: "application/json"),
           let p = try? PosterJSON.decode(Data(j.utf8)) { return p.url2x }
        guard let h = try? await fetcher.text(url(["film", s])) else { return nil }
        return Parsers.ogImage(html: h)
    }
    static func cleanQuery(_ q: String) throws -> String {
        let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 100, !t.contains("/") else { throw LetterboxdError.invalidInput("query") }
        return t
    }
}
