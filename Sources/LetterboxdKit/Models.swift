import Foundation

public struct FilmSummary: Hashable, Sendable, Identifiable, Codable {
    public var id: String { slug }
    public let slug: String
    public let title: String
    public let year: Int?
    public var posterURL: URL?
    /// Rating (0.5...5) given by the owner of the page this film was listed on. Never the viewer's.
    public var ownerRating: Double?
    public init(slug: String, title: String, year: Int?, posterURL: URL? = nil, ownerRating: Double? = nil) {
        self.slug = slug; self.title = title; self.year = year; self.posterURL = posterURL; self.ownerRating = ownerRating
    }
    public var pageURL: URL { URL(string: "https://letterboxd.com/film/\(slug)/")! }
    /// "★4.5" / "★4"; nil when the owner has not rated the film.
    public var ownerRatingLabel: String? {
        guard let r = ownerRating, r >= 0.5, r <= 5 else { return nil }
        return "\u{2605}" + (r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r))
    }
}

public struct Person: Hashable, Sendable, Codable {
    public let name: String
    public let url: URL?
    public init(name: String, url: URL?) { self.name = name; self.url = url }
}

public struct Credit: Hashable, Sendable, Codable, Identifiable {
    public var id: String { role.rawValue + "/" + slug }
    public let name: String; public let role: PersonRole; public let slug: String
    public init(name: String, role: PersonRole, slug: String) { self.name = name; self.role = role; self.slug = slug }
}

public struct FilmDetail: Hashable, Sendable, Codable {
    public let slug: String
    public let title: String
    public let year: Int?
    public let tagline: String?
    public let synopsis: String?
    public let posterURL: URL?
    public let runtimeMinutes: Int?
    /// Certification reported by Letterboxd releases, Canada preferred over USA.
    public let contentRating: String?
    public let directors: [Person]
    public let cast: [Person]
    public let genres: [String]
    public let averageRating: Double?
    public let ratingCount: Int?
    /// From the film page backdrop element (#backdrop data-backdrop-mobile / data-backdrop). nil when the film has none.
    public let backdropURL: URL?
    /// Cast and crew links from the film page (a.text-slug / a.contributor), validated, deduped.
    public var credits: [Credit] = []
    public init(slug: String, title: String, year: Int?, tagline: String?, synopsis: String?, posterURL: URL?, runtimeMinutes: Int?, directors: [Person], cast: [Person], genres: [String], averageRating: Double?, ratingCount: Int?, backdropURL: URL? = nil, credits: [Credit] = [], contentRating: String? = nil) {
        self.contentRating = contentRating
        self.credits = credits
        self.backdropURL = backdropURL
        self.slug = slug; self.title = title; self.year = year; self.tagline = tagline; self.synopsis = synopsis
        self.posterURL = posterURL; self.runtimeMinutes = runtimeMinutes; self.directors = directors; self.cast = cast
        self.genres = genres; self.averageRating = averageRating; self.ratingCount = ratingCount
    }
    public var pageURL: URL { URL(string: "https://letterboxd.com/film/\(slug)/")! }
}

public struct Page<T: Sendable>: Sendable {
    public let items: [T]
    public let page: Int
    public let hasNext: Bool
    public init(items: [T], page: Int, hasNext: Bool) { self.items = items; self.page = page; self.hasNext = hasNext }
}

public struct Profile: Hashable, Sendable, Codable {
    public let username: String
    public let displayName: String
    public let avatarURL: URL?
    public let bio: String?
    public let filmCount: Int?
    public let followingCount: Int?
    public let followersCount: Int?
    public init(username: String, displayName: String, avatarURL: URL?, bio: String?, filmCount: Int?, followingCount: Int?, followersCount: Int?) {
        self.username = username; self.displayName = displayName; self.avatarURL = avatarURL; self.bio = bio
        self.filmCount = filmCount; self.followingCount = followingCount; self.followersCount = followersCount
    }
    public var pageURL: URL { URL(string: "https://letterboxd.com/\(username)/")! }
}

/// A diary entry or review parsed from a member RSS feed.
/// A review of a film by any member, as listed on /film/<slug>/reviews/.
public struct FilmReview: Hashable, Sendable, Identifiable {
    public var id: String { link.absoluteString }
    public let link: URL; public let author: String; public let username: String
    public let rating: Double?; public let text: String; public let date: Date?
    public let fullTextPath: String?
    public init(link: URL, author: String, username: String, rating: Double?, text: String, date: Date?, fullTextPath: String?) {
        self.link = link; self.author = author; self.username = username; self.rating = rating; self.text = text; self.date = date; self.fullTextPath = fullTextPath
    }
}
public struct ActivityEntry: Hashable, Sendable, Identifiable, Codable {
    /// Review links retain the canonical film slug, including repeated viewings.
    public var filmSlug: String? {
        guard !isListEntry, let page = try? Validate.reviewPage(link) else { return nil }
        return page.path.split(separator: "/").dropFirst(2).first.map(String.init)
    }
    public var id: String { link.absoluteString }
    public let link: URL
    public let filmTitle: String
    public let filmYear: Int?
    public let rating: Double?
    public let watchedDate: Date?
    public let rewatch: Bool
    public let review: String?
    public let posterURL: URL?
    public let isListEntry: Bool
    public init(link: URL, filmTitle: String, filmYear: Int?, rating: Double?, watchedDate: Date?, rewatch: Bool, review: String?, posterURL: URL?, isListEntry: Bool = false) {
        self.link = link; self.filmTitle = filmTitle; self.filmYear = filmYear; self.rating = rating; self.watchedDate = watchedDate
        self.rewatch = rewatch; self.review = review; self.posterURL = posterURL; self.isListEntry = isListEntry
    }
}

public struct ListSummary: Hashable, Sendable, Identifiable, Codable {
    public var id: String { url.absoluteString }
    public let title: String
    public let url: URL
    public let filmCount: Int?
    public let blurb: String?
    public init(title: String, url: URL, filmCount: Int?, blurb: String?) {
        self.title = title; self.url = url; self.filmCount = filmCount; self.blurb = blurb
    }
}

public struct MemberSummary: Hashable, Sendable, Identifiable, Codable {
    public var id: String { username }
    public let username: String
    public let displayName: String
    public let avatarURL: URL?
    public init(username: String, displayName: String, avatarURL: URL?) {
        self.username = username; self.displayName = displayName; self.avatarURL = avatarURL
    }
}

public enum BrowseKind: String, CaseIterable, Sendable { case popular, topRated, anticipated
    public var title: String { switch self { case .popular: "Popular"; case .topRated: "Top Rated"; case .anticipated: "Anticipated" } }
}


public struct PersonDetails: Sendable {
    public let portraitURL: URL?
    public let biography: String?
    public let filmCount: Int?
    public let roles: [String]
    public init(portraitURL: URL? = nil, biography: String? = nil, filmCount: Int? = nil, roles: [String] = []) {
        self.portraitURL = portraitURL; self.biography = biography; self.filmCount = filmCount; self.roles = roles
    }
}
