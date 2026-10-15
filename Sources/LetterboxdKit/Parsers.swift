import Foundation
import SwiftSoup
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum Parsers {
    /// /s/full-text/ returns an HTML fragment of sibling <p> elements (captured, status 200). Paragraphs joined by blank lines.
    public static func fullText(html: String) throws -> String {
        let doc = try SwiftSoup.parseBodyFragment(html)
        let t = try doc.select("p").array().map { try $0.text() }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !t.isEmpty else { throw LetterboxdError.parse("full text") }
        return t
    }
    /// A review page carries its viewing id in data-likeable-identifier ({"uid":"viewing:<id>"}); captured on a real review page.
    public static func reviewFullTextPath(html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        for el in try doc.select("[data-likeable-identifier]").array() {
            let raw = try el.attr("data-likeable-identifier")
            if let r = raw.range(of: #"viewing:[0-9]{1,18}"#, options: .regularExpression) {
                return try Validate.fullTextPath("/s/full-text/" + raw[r] + "/")
            }
        }
        throw LetterboxdError.parse("review id")
    }
    static func splitTitleYear(_ s: String) -> (String, Int?) {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = t.range(of: #" \((\d{4})\)$"#, options: .regularExpression) {
            let y = Int(t[r].filter(\.isNumber))
            return (String(t[t.startIndex..<r.lowerBound]), y)
        }
        return (t, nil)
    }
    static func int(_ s: String) -> Int? { Int(s.filter(\.isNumber)) }

    // MARK: poster grids (films, watchlist, popular)
    public static func filmGrid(html: String, page: Int, ownerRatings: Bool = false) throws -> Page<FilmSummary> {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var out: [FilmSummary] = []
        var seen = Set<String>()
        for el in try doc.select("[data-item-slug]") {
            let slug = try el.attr("data-item-slug")
            guard (try? Validate.slug(slug)) != nil, seen.insert(slug).inserted else { continue }
            let full = try el.attr("data-item-full-display-name")
            let name = try el.attr("data-item-name")
            let (title, year) = splitTitleYear(full.isEmpty ? name : full)
            var poster: URL? = nil
            if let src = try el.select("img[src]").first()?.attr("src"), src.contains("ltrbxd.com"), !src.contains("empty-poster") {
                poster = URL(string: src)
            }
            out.append(FilmSummary(slug: slug, title: title, year: year, posterURL: poster, ownerRating: ownerRatings ? ownerRating(in: el) : nil))
        }
        let hasNext = !(try doc.select("a.next").isEmpty())
        return Page(items: out, page: page, hasNext: hasNext)
    }

    /// Reads `rated-N` (N = half-stars, 1...10) from the owner's poster-viewingdata in the same grid cell.
    static func ownerRating(in el: Element) -> Double? {
        guard let cell = el.parents().first(where: { $0.tagName() == "li" }),
              let spans = try? cell.select("p.poster-viewingdata span.rating") else { return nil }
        for span in spans {
            let cls = (try? span.className()) ?? ""
            for part in cls.split(separator: " ") where part.hasPrefix("rated-") {
                if let n = Int(part.dropFirst(6)), (1...10).contains(n) { return Double(n) / 2 }
            }
        }
        return nil
    }

    // MARK: film detail via JSON-LD (+ og fallback)
    public static func filmDetail(html: String, slug: String) throws -> FilmDetail {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var json: [String: Any]? = nil
        for s in try doc.select("script[type=application/ld+json]") {
            var t = s.data()
            t = t.replacingOccurrences(of: "/* <![CDATA[ */", with: "").replacingOccurrences(of: "/* ]]> */", with: "")
            if let d = t.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], (o["@type"] as? String) == "Movie" { json = o; break }
        }
        guard let j = json else { throw LetterboxdError.parse("film JSON-LD missing") }
        func people(_ k: String) -> [Person] {
            (j[k] as? [[String: Any]] ?? []).compactMap { p in
                guard let n = p["name"] as? String else { return nil }
                return Person(name: n, url: (p["sameAs"] as? String).flatMap(URL.init(string:)).flatMap { try? Validate.url($0) })
            }
        }
        let ogT = try doc.select("meta[property=og:title]").first()?.attr("content")
        let rawName = j["name"] as? String ?? ogT ?? ""
        let (title, ogYear) = splitTitleYear(rawName)
        var year = ogYear
        if year == nil, let rel = (j["releasedEvent"] as? [[String: Any]])?.first?["startDate"] as? String { year = Int(rel.prefix(4)) }
        var minutes: Int? = nil
        if let d = j["duration"] as? String, let m = d.range(of: #"PT(?:(\d+)H)?(?:(\d+)M)?"#, options: .regularExpression) {
            let parts = d[m].replacingOccurrences(of: "PT", with: "")
            let h = parts.split(separator: "H").first.flatMap { parts.contains("H") ? Int($0) : nil } ?? 0
            let mm = parts.components(separatedBy: "H").last.flatMap { Int($0.replacingOccurrences(of: "M", with: "")) } ?? 0
            minutes = h * 60 + mm
        }
        let agg = j["aggregateRating"] as? [String: Any]
        let avg = (agg?["ratingValue"] as? Double) ?? (agg?["ratingValue"] as? NSNumber)?.doubleValue
        let cnt = (agg?["ratingCount"] as? Int)
        let tagline = try doc.select("h4.tagline").first()?.text()
        let blurb = try doc.select("div.truncate p").first()?.text() ?? (j["description"] as? String)
        return FilmDetail(slug: slug, title: title, year: year, tagline: tagline, synopsis: blurb,
                          posterURL: (j["image"] as? String).flatMap(URL.init(string:)).flatMap { try? Validate.url($0) },
                          runtimeMinutes: minutes, directors: people("director"), cast: people("actor"),
                          genres: (j["genre"] as? [String]) ?? [], averageRating: avg, ratingCount: cnt,
                          backdropURL: backdrop(doc), credits: credits(html: html))
    }

    /// Real film pages carry <div id="backdrop" data-backdrop-mobile=... data-backdrop=...>. Only https a.ltrbxd.com-style hosts pass Validate.url.
    static func backdrop(_ doc: Document) -> URL? {
        guard let el = try? doc.select("#backdrop").first() else { return nil }
        for k in ["data-backdrop2x", "data-backdrop", "data-backdrop-mobile"] {
            if let v = try? el.attr(k), !v.isEmpty, let u = URL(string: v), let ok = try? Validate.url(u) { return ok }
        }
        return nil
    }

    /// Real film pages link people as <a href="/actor/slug/" class="text-slug ...">Name</a>.
    public static func credits(html: String) -> [Credit] {
        guard let doc = try? SwiftSoup.parse(html, "https://letterboxd.com/") else { return [] }
        var seen = Set<String>(), out: [Credit] = []
        for a in (try? doc.select("a.text-slug[href], a.contributor[href]")) ?? Elements() {
            guard let h = try? a.attr("href"), let u = Validate.resolve(h), let (role, slug) = try? Validate.personLink(u),
                  let n = try? a.text().trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty, n != "Show All…" else { continue }
            if seen.insert(role.rawValue + "/" + slug).inserted { out.append(Credit(name: n, role: role, slug: slug)) }
        }
        return out
    }
    /// Person page title: "Films starring Brad Pitt" (og:title). The page carries no portrait (og:image is the site default), so none is shown.
    public static func personName(html: String) -> String? {
        guard let t = try? SwiftSoup.parse(html).select("meta[property=og:title]").first()?.attr("content") else { return nil }
        for p in ["Films starring ", "Films directed by ", "Films written by ", "Films produced by ", "Films with ", "Films by "] where t.hasPrefix(p) { return String(t.dropFirst(p.count)) }
        return t.isEmpty ? nil : t
    }

    /// Portrait from the real person page: <img class="js-tmdb-person" data-image="https://image.tmdb.org/t/p/w500/...jpg">.
    /// Only https image.tmdb.org /t/p/ paths are accepted.
    public static func personPortrait(html: String) -> URL? {
        guard let doc = try? SwiftSoup.parse(html), let raw = try? doc.select("img.js-tmdb-person").first()?.attr("data-image"),
              let u = URL(string: raw), u.scheme == "https", u.host == "image.tmdb.org", u.port == nil, u.user == nil,
              u.path.hasPrefix("/t/p/"), u.query == nil else { return nil }
        return u
    }

    // MARK: profile
    public static func profile(html: String, username: String) throws -> Profile {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        let ogTitle = try doc.select("meta[property=og:title]").first()?.attr("content") ?? ""
        var name = ogTitle.replacingOccurrences(of: "’s profile", with: "").replacingOccurrences(of: "'s profile", with: "")
        if let h = try doc.select("h1.title-1, h1.person-display-name, span.displayname").first()?.text(), !h.isEmpty { name = h }
        guard !name.isEmpty else { throw LetterboxdError.parse("profile name missing") }
        let avatar = try doc.select("meta[property=og:image]").first()?.attr("content")
        var stats: [String: Int] = [:]
        for el in try doc.select(".profile-statistic, .profile-stats a, h4.profile-statistic") {
            // Real markup: <span class="value">1</span><span class="definition">Follower</span>; the label is singular when the count is 1.
            let label = try el.select(".definition").first()?.text() ?? el.text()
            let raw = try el.select(".value").first()?.text() ?? ""
            let key: String? = label.range(of: "Follower", options: .caseInsensitive) != nil ? "Followers"
                : label.range(of: "Following", options: .caseInsensitive) != nil ? "Following"
                : label.range(of: "Film", options: .caseInsensitive) != nil ? "Films" : nil
            if let key, let v = int(raw.isEmpty ? label.filter { !$0.isLetter && !$0.isWhitespace } : raw) { stats[key] = v }
        }
        let bio = try doc.select(".profile-bio, .bio .collapsed-text, meta[name=description]").first()
        let bioText = try bio.map { $0.tagName() == "meta" ? try $0.attr("content") : try $0.text() }
        return Profile(username: username, displayName: name, avatarURL: avatar.flatMap(URL.init(string:)).flatMap { try? Validate.url($0) },
                       bio: bioText?.isEmpty == true ? nil : bioText, filmCount: stats["Films"], followingCount: stats["Following"], followersCount: stats["Followers"])
    }

    // MARK: lists
    public static func lists(html: String, page: Int) throws -> Page<ListSummary> {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var out: [ListSummary] = []
        for sec in try doc.select("section.list, div.film-list-summary, article.list-summary, section.-overlapped-list") {
            guard let a = try sec.select("h2 a, h3 a, .title a").first() else { continue }
            let href = try a.attr("href")
            guard let u = Validate.resolve(href) else { continue }
            let count = try sec.select(".value, .content-metadata").first().flatMap { int(try $0.text()) }
            let blurb = try sec.select(".body-text p, .notes").first()?.text()
            out.append(ListSummary(title: try a.text(), url: u, filmCount: count, blurb: blurb))
        }
        return Page(items: out, page: page, hasNext: !(try doc.select("a.next").isEmpty()))
    }

    // MARK: film reviews
    /// Rating from the svg aria-label of stars ("★★★½").
    static func stars(_ s: String) -> Double? {
        let full = s.filter { $0 == "★" }.count, half = s.contains("½") ? 0.5 : 0
        let v = Double(full) + half; return v > 0 ? v : nil
    }
    public static func filmReviews(html: String, page: Int) throws -> Page<FilmReview> {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var out: [FilmReview] = []
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        for a in try doc.select("article.production-viewing") {
            guard let ctx = try a.select("a.context").first(), let link = Validate.resolve(try ctx.attr("href")),
                  let user = try? Validate.username(try a.select("a.avatar").first()?.attr("href").trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""),
                  let body = try a.select(".js-review-body").first() else { continue }
            let text = try body.select("p").array().map { try $0.text() }.joined(separator: "\n\n")
            guard !text.isEmpty else { continue }
            let name = try a.select(".displayname").first()?.text() ?? user
            let rating = try a.select("svg.glyph.-rating").first().flatMap { stars(try $0.attr("aria-label")) }
            let date = try a.select("time.timestamp").first().flatMap { df.date(from: try $0.attr("datetime")) }
            var full: String? = try body.attr("data-full-text-url")
            if let f = full, (try? Validate.fullTextPath(f)) == nil { full = nil }
            if full?.isEmpty == true { full = nil }
            out.append(FilmReview(link: link, author: name, username: user, rating: rating, text: text, date: date, fullTextPath: full))
        }
        return Page(items: out, page: page, hasNext: !(try doc.select("a.next").isEmpty()))
    }

    // MARK: members
    static func avatar(_ raw: String?) -> URL? {
        guard let raw, let u = URL(string: raw), u.scheme == "https", u.port == nil, u.user == nil,
              let h = u.host, h == "a.ltrbxd.com" || h == "s.ltrbxd.com" else { return nil }
        return u
    }
    public static func members(html: String, page: Int) throws -> Page<MemberSummary> {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        var out: [MemberSummary] = []
        for p in try doc.select(".person-summary") {
            guard let a = try p.select("a.name").first() else { continue }
            let href = try a.attr("href").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let u = try? Validate.username(href) else { continue }
            out.append(MemberSummary(username: u, displayName: try a.text(), avatarURL: avatar(try p.select("img").first()?.attr("src"))))
        }
        return Page(items: out, page: page, hasNext: !(try doc.select("a.next").isEmpty()))
    }

    /// Film poster from a film page's og:image (used lazily for grid items).
    public static func ogImage(html: String) -> URL? {
        guard let doc = try? SwiftSoup.parse(html), let c = try? doc.select("meta[property=og:image]").first()?.attr("content") else { return nil }
        return URL(string: c).flatMap { try? Validate.url($0) }
    }
}

// MARK: RSS (diary / reviews / lists)
public final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [[String: String]] = []
    private var cur: [String: String]? = nil
    private var text = ""
    public static func parse(_ data: Data) throws -> [ActivityEntry] {
        let p = RSSParser(); let x = XMLParser(data: data); x.delegate = p
        guard x.parse() else { throw LetterboxdError.parse("RSS xml: \(x.parserError?.localizedDescription ?? "invalid")") }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"; df.timeZone = TimeZone(identifier: "UTC")
        return p.items.compactMap { d in
            guard let l = d["link"], let u = URL(string: l), (try? Validate.url(u)) != nil else { return nil }
            let title = d["letterboxd:filmTitle"] ?? d["title"] ?? ""
            var poster: URL? = nil
            var review: String? = nil
            if let html = d["description"], let doc = try? SwiftSoup.parse(html) {
                if let s = try? doc.select("img").first()?.attr("src"), let pu = URL(string: s), (try? Validate.url(pu)) != nil { poster = pu }
                let ps = (try? doc.select("p").array().map { try $0.text() }) ?? []
                let body = ps.filter { !$0.hasPrefix("Watched on") && !$0.isEmpty }.joined(separator: "\n\n")
                review = body.isEmpty || body == "Watched on" ? nil : body
            }
            return ActivityEntry(link: u, filmTitle: title, filmYear: d["letterboxd:filmYear"].flatMap(Int.init),
                                 rating: d["letterboxd:memberRating"].flatMap(Double.init),
                                 watchedDate: d["letterboxd:watchedDate"].flatMap(df.date(from:)),
                                 rewatch: d["letterboxd:rewatch"] == "Yes", review: review, posterURL: poster,
                                 isListEntry: d["guid"]?.hasPrefix("letterboxd-list") == true)
        }
    }
    public func parser(_ parser: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName q: String?, attributes a: [String: String] = [:]) {
        if e == "item" { cur = [:] }; text = ""
    }
    public func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }
    public func parser(_ parser: XMLParser, foundCDATA b: Data) { text += String(decoding: b, as: UTF8.self) }
    public func parser(_ parser: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName q: String?) {
        if e == "item", let c = cur { items.append(c); cur = nil; return }
        if cur != nil { cur?[q ?? e] = text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
