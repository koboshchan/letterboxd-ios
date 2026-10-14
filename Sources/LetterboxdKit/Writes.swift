import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A write request. Only the two shapes captured from the real site exist (see FilmActions).
public struct WriteRequest: Sendable {
    public let method: String, url: URL, contentType: String, body: Data, headers: [String: String]
    public init(method: String, url: URL, contentType: String, body: Data, headers: [String: String] = [:]) {
        self.method = method; self.url = url; self.contentType = contentType; self.body = body; self.headers = headers
    }
}

extension HTTPTransport {
    public func send(_ request: WriteRequest) async throws -> HTTPResult { throw LetterboxdError.network("Writes unsupported by this transport") }
}

extension URLSessionTransport {
    public func send(_ request: WriteRequest) async throws -> HTTPResult {
        guard testSite != nil || RedirectPolicy.mayCarryCredentials(request.url), let cookie = cookieHeader?(), !cookie.isEmpty else { throw AuthError.notSignedIn }
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method; r.httpBody = request.body
        r.setValue(request.contentType, forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/javascript, */*", forHTTPHeaderField: "Accept")
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("https://letterboxd.com", forHTTPHeaderField: "Origin")
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let s = URLSession(configuration: configuration, delegate: RedirectGuard(authenticated: true, observer: redirectObserver, enforce: enforceRedirectPolicy, siteCheck: testSite), delegateQueue: nil)
            defer { s.finishTasksAndInvalidate() }
            let (d, resp) = try await s.data(for: r)
            return HTTPResult(data: d, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError { throw LetterboxdError.cancelled
        } catch { throw LetterboxdError.network(error.localizedDescription) }
    }
}

public struct FilmHandle: Sendable, Equatable { public let slug: String, lid: String, id: Int, csrf: String }
public struct LikeResult: Sendable, Equatable { public let liked: Bool, count: Int? }

/// Watchlist and like, built ONLY from the captured wire format:
/// PATCH /api/v0/me/watchlist/{filmLid}  JSON {"inWatchlist":Bool}, header x-csrf-token, response {}
/// POST  /s/film:{filmId}/like/          form liked=<bool>&__csrf=<token>, response result/csrf/count/liked
/// The lid, id and csrf come from GET /film/{slug}/json/. Diary, review, list and rating writes are NOT verified, so absent.
public final class FilmActions: Sendable {
    let transport: HTTPTransport; let auth: AuthAuthority
    public init(transport: HTTPTransport, auth: AuthAuthority) { self.transport = transport; self.auth = auth }

    private func guarded<T: Sendable>(_ body: (Int) async throws -> T) async throws -> T {
        guard auth.cookieHeader() != nil else { throw AuthError.notSignedIn }
        let g = auth.generation
        let v = try await body(g)
        guard auth.generation == g else { throw LetterboxdError.cancelled }
        return v
    }
    private func check(_ r: HTTPResult) throws {
        if r.status == 403 || r.status == 429 { throw LetterboxdError.blocked(status: r.status) }
        guard r.status == 200 else { throw LetterboxdError.http(status: r.status) }
        let head = String(decoding: r.data.prefix(4096), as: UTF8.self)
        if head.contains("Just a moment...") || head.contains("challenges.cloudflare.com") { throw LetterboxdError.blocked(status: r.status) }
    }
    public func handle(slug: String) async throws -> FilmHandle {
        try await guarded { _ in
            try Task.checkCancellation()
            let u = try Validate.url(URL(string: "https://letterboxd.com/film/\(try Validate.slug(slug))/json/")!)
            let r = try await transport.get(u, accept: "application/json")
            try check(r)
            guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true,
                  let lid = j["lid"] as? String, let id = j["id"] as? Int, let csrf = j["csrf"] as? String, !csrf.isEmpty,
                  lid.range(of: "^[A-Za-z0-9]{1,12}$", options: .regularExpression) != nil
            else { throw LetterboxdError.parse("film json") }
            return FilmHandle(slug: slug, lid: lid, id: id, csrf: csrf)
        }
    }
    public func setWatchlist(_ f: FilmHandle, on: Bool) async throws {
        try await guarded { _ in
            try Task.checkCancellation()
            let u = URL(string: "https://letterboxd.com/api/v0/me/watchlist/\(f.lid)")!
            let body = try JSONSerialization.data(withJSONObject: ["inWatchlist": on])
            let r = try await transport.send(WriteRequest(method: "PATCH", url: u, contentType: "application/json; charset=UTF-8", body: body, headers: ["x-csrf-token": f.csrf]))
            try check(r)
        }
    }
    public func setLike(_ f: FilmHandle, liked: Bool) async throws -> LikeResult {
        try await guarded { _ in
            try Task.checkCancellation()
            let u = URL(string: "https://letterboxd.com/s/film:\(f.id)/like/")!
            var c = URLComponents(); c.queryItems = [URLQueryItem(name: "liked", value: liked ? "true" : "false"), URLQueryItem(name: "__csrf", value: f.csrf)]
            let body = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            let r = try await transport.send(WriteRequest(method: "POST", url: u, contentType: "application/x-www-form-urlencoded", body: body))
            try check(r)
            guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true, let l = j["liked"] as? Bool, l == liked
            else { throw LetterboxdError.parse("like response") }
            return LikeResult(liked: l, count: j["count"] as? Int)
        }
    }
}
