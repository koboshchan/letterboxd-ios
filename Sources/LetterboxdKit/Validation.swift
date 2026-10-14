import Foundation

public enum LetterboxdError: Error, Equatable, LocalizedError, Sendable {
    case invalidInput(String)
    case blocked(status: Int)          // Cloudflare challenge / rate limit / forbidden
    case notFound
    case http(status: Int)
    case parse(String)
    case network(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let s): "Invalid input: \(s)"
        case .blocked(let c): "Letterboxd declined this request (HTTP \(c)). Automated access is restricted; open the website instead."
        case .notFound: "Not found on Letterboxd."
        case .http(let c): "Letterboxd returned HTTP \(c)."
        case .parse(let s): "Couldn't read the page (\(s)). The site layout may have changed."
        case .network(let s): "Network error: \(s)"
        case .cancelled: "Cancelled."
        }
    }
}

public enum PersonRole: String, CaseIterable, Sendable, Codable { case actor, director, writer, producer, composer, cinematography, editor
    case productionDesign = "production-design", costumeDesign = "costume-design", makeup, sound, visualEffects = "visual-effects", stunts }

public enum Validate {
    /// Accepts only a Letterboxd /<role>/<slug>/ link (absolute https on an allowed host or site-relative). Returns role and slug.
    public static func personLink(_ u: URL) throws -> (role: PersonRole, slug: String) {
        let ok = try? url(u)
        guard let ok, ok.query == nil, ok.fragment == nil else { throw LetterboxdError.invalidInput("person") }
        let parts = ok.path.split(separator: "/").map(String.init)
        guard parts.count == 2, let role = PersonRole(rawValue: parts[0]), let slug = try? Validate.slug(parts[1]) else { throw LetterboxdError.invalidInput("person") }
        return (role, slug)
    }
    public static func username(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.range(of: #"^[a-z0-9_]{2,15}$"#, options: .regularExpression) != nil
                || t.range(of: #"^[a-z0-9_-]{2,30}$"#, options: .regularExpression) != nil else {
            throw LetterboxdError.invalidInput("username")
        }
        return t
    }
    /// "/<user>/list/<slug>/" on letterboxd.com only (from a parsed ListSummary).
    public static func listPath(_ u: URL) throws -> (user: String, slug: String) {
        guard u.scheme == "https", u.host == "letterboxd.com", u.port == nil, u.user == nil, u.query == nil, u.fragment == nil else { throw LetterboxdError.invalidInput("list url") }
        let c = u.pathComponents.filter { $0 != "/" }
        guard c.count == 3, c[1] == "list" else { throw LetterboxdError.invalidInput("list url") }
        return (try username(c[0]), try slug(c[2]))
    }
    public static func slug(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.range(of: #"^[a-z0-9][a-z0-9-]{0,120}$"#, options: .regularExpression) != nil else {
            throw LetterboxdError.invalidInput("slug")
        }
        return t
    }
    /// Only absolute https URLs on Letterboxd hosts may be fetched.
    public static let allowedHosts: Set<String> = ["letterboxd.com", "www.letterboxd.com", "a.ltrbxd.com", "s.ltrbxd.com"]
    public static func url(_ u: URL) throws -> URL {
        guard u.scheme == "https", let h = u.host?.lowercased(), allowedHosts.contains(h), u.user == nil, u.port == nil else {
            throw LetterboxdError.invalidInput("url")
        }
        return u
    }
    /// Resolve a site-relative path like /film/x/ into an absolute allowed URL.
    public static func resolve(_ href: String) -> URL? {
        guard let u = URL(string: href, relativeTo: URL(string: "https://letterboxd.com/")!)?.absoluteURL else { return nil }
        return try? url(u)
    }
}

extension Validate {
    /// Only the captured shape: exactly /s/full-text/viewing:<digits>/ . No query, fragment, userinfo, encoding or traversal.
    public static func fullTextPath(_ p: String) throws -> String {
        guard p.range(of: "^/s/full-text/viewing:[0-9]{1,18}/\\z", options: .regularExpression) != nil else { throw LetterboxdError.invalidInput("full text path") }
        return p
    }
}

extension Validate {
    /// Canonical review page: https://letterboxd.com/<user>/film/<slug>/ or .../<n>/ for repeat viewings.
    public static func reviewPage(_ u: URL) throws -> URL {
        guard u.scheme == "https", u.host == "letterboxd.com", u.port == nil, u.user == nil, u.query == nil, u.fragment == nil else { throw LetterboxdError.invalidInput("review url") }
        let c = u.pathComponents.filter { $0 != "/" }
        guard c.count == 3 || c.count == 4, c[1] == "film" else { throw LetterboxdError.invalidInput("review url") }
        var parts = [try username(c[0]), "film", try slug(c[2])]
        if c.count == 4 { guard c[3].range(of: "^[0-9]{1,4}$", options: .regularExpression) != nil else { throw LetterboxdError.invalidInput("review url") }; parts.append(c[3]) }
        guard let out = URL(string: "https://letterboxd.com/" + parts.joined(separator: "/") + "/") else { throw LetterboxdError.invalidInput("review url") }
        return out
    }
}
