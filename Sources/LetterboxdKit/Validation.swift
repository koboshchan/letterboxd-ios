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

public enum Validate {
    public static func username(_ s: String) throws -> String {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.range(of: #"^[a-z0-9_]{2,15}$"#, options: .regularExpression) != nil
                || t.range(of: #"^[a-z0-9_-]{2,30}$"#, options: .regularExpression) != nil else {
            throw LetterboxdError.invalidInput("username")
        }
        return t
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
