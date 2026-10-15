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
        guard let cookie = cookieHeader?(), !cookie.isEmpty else { throw AuthError.notSignedIn }
        return try await send(request, cookie: cookie)
    }
    public func send(_ request: WriteRequest, credentials: RequestCredentials) async throws -> HTTPResult {
        try await send(request, cookie: credentials.cookie)
    }
    private func send(_ request: WriteRequest, cookie: String) async throws -> HTTPResult {
        guard testSite != nil || RedirectPolicy.mayCarryCredentials(request.url), !cookie.isEmpty else { throw AuthError.notSignedIn }
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method; r.httpBody = request.body
        r.setValue(request.contentType, forHTTPHeaderField: "Content-Type")
        r.setValue("application/json, text/javascript, */*", forHTTPHeaderField: "Accept")
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("https://letterboxd.com", forHTTPHeaderField: "Origin")
        for (k, v) in request.headers where !["cookie", "authorization"].contains(k.lowercased()) { r.setValue(v, forHTTPHeaderField: k) }
        do {
            let s = URLSession(configuration: configuration, delegate: RedirectGuard(authenticated: true, observer: redirectObserver, enforce: enforceRedirectPolicy, siteCheck: testSite), delegateQueue: nil)
            defer { s.finishTasksAndInvalidate() }
            let (d, resp) = try await s.data(for: r)
            return HTTPResult(data: d, status: (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError { throw LetterboxdError.cancelled
        } catch { throw LetterboxdError.network(error.localizedDescription) }
    }
}

public struct FilmHandle: Sendable, Equatable {
    public let slug: String, lid: String, id: Int, csrf: String
    let credentials: RequestCredentials?
    init(slug: String, lid: String, id: Int, csrf: String, credentials: RequestCredentials? = nil) {
        self.slug = slug; self.lid = lid; self.id = id; self.csrf = csrf; self.credentials = credentials
    }
}
public struct FilmState: Sendable, Equatable { public let watchlist: Bool, liked: Bool
    public init(watchlist: Bool, liked: Bool) { self.watchlist = watchlist; self.liked = liked } }

/// What the film screen talks to. FilmActions is the production implementation; the UI-test host injects a mock.
/// Every call returns state the SERVER confirmed, or throws (including when the outcome could not be confirmed).
public protocol FilmActionsClient: Sendable {
    func state(slug: String) async throws -> FilmState
    func setWatchlist(slug: String, on: Bool) async throws -> FilmState
    func setLike(slug: String, liked: Bool) async throws -> FilmState
    /// Rating and watched (Oct 14 captures). Default: unsupported, so older clients and test doubles keep compiling.
    var supportsRating: Bool { get }
    func ratingState(slug: String) async throws -> RatingState
    func setRating(slug: String, rating: Double?) async throws -> RatingState
    func setWatched(slug: String, watched: Bool) async throws -> RatingState
}
public extension FilmActionsClient {
    var supportsRating: Bool { false }
    func ratingState(slug: String) async throws -> RatingState { throw LetterboxdError.invalidInput("rating unsupported") }
    func setRating(slug: String, rating: Double?) async throws -> RatingState { throw LetterboxdError.invalidInput("rating unsupported") }
    func setWatched(slug: String, watched: Bool) async throws -> RatingState { throw LetterboxdError.invalidInput("rating unsupported") }
}

public struct LikeResult: Sendable, Equatable { public let liked: Bool, count: Int? }

/// Watchlist and like, built ONLY from the captured wire format:
/// PATCH /api/v0/me/watchlist/{filmLid}  JSON {"inWatchlist":Bool}, header x-csrf-token, response {}
/// POST  /s/film:{filmId}/like/          form liked=<bool>&__csrf=<token>, response result/csrf/count/liked
/// The lid, id and csrf come from GET /film/{slug}/json/. Diary, review, list and rating writes are NOT verified, so absent.
public final class FilmActions: Sendable {
    let transport: HTTPTransport; let auth: AuthAuthority
    public init(transport: HTTPTransport, auth: AuthAuthority) { self.transport = transport; self.auth = auth }

    private func guarded<T: Sendable>(_ originating: RequestCredentials? = nil, _ body: (RequestCredentials) async throws -> T) async throws -> T {
        let credentials = try originating ?? auth.requestCredentials()
        guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
        let v = try await body(credentials)
        guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
        return v
    }
    private func check(_ r: HTTPResult) throws {
        if r.status == 403 || r.status == 429 { throw LetterboxdError.blocked(status: r.status) }
        guard r.status == 200 else { throw LetterboxdError.http(status: r.status) }
        let head = String(decoding: r.data.prefix(4096), as: UTF8.self)
        if head.contains("Just a moment...") || head.contains("challenges.cloudflare.com") { throw LetterboxdError.blocked(status: r.status) }
    }
    public func handle(slug: String) async throws -> FilmHandle {
        try await guarded { credentials in
            try Task.checkCancellation()
            let u = try Validate.url(URL(string: "https://letterboxd.com/film/\(try Validate.slug(slug))/json/")!)
            let r = try await transport.get(u, accept: "application/json", credentials: credentials)
            try check(r)
            guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true,
                  let lid = j["lid"] as? String, let id = j["id"] as? Int, let csrf = j["csrf"] as? String, !csrf.isEmpty,
                  lid.range(of: "^[A-Za-z0-9]{1,12}$", options: .regularExpression) != nil
            else { throw LetterboxdError.parse("film json") }
            return FilmHandle(slug: slug, lid: lid, id: id, csrf: csrf, credentials: credentials)
        }
    }
    public func setWatchlist(_ f: FilmHandle, on: Bool) async throws {
        try await guarded(f.credentials) { credentials in
            try Task.checkCancellation()
            let u = URL(string: "https://letterboxd.com/api/v0/me/watchlist/\(f.lid)")!
            let body = try JSONSerialization.data(withJSONObject: ["inWatchlist": on])
            let r = try await transport.send(WriteRequest(method: "PATCH", url: u, contentType: "application/json; charset=UTF-8", body: body, headers: ["x-csrf-token": f.csrf]), credentials: credentials)
            try check(r)
            guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
            // PATCH answers 200 {} which proves nothing: read the server's watchlist back and require the target state.
            guard try await relation(f).watchlist == on else { throw LetterboxdError.parse("watchlist readback mismatch") }
        }
    }
    /// Authoritative current state: GET /s/check-viewingable-relation?viewingableUID=film:{id}
    /// (captured: 200, JSON with liked, rating, isInWatchlist, isDerivedRating). The uid value is the film JSON's "uid",
    /// which equals film:{id}.
    public func relation(_ f: FilmHandle) async throws -> FilmState {
        try await guarded(f.credentials) { credentials in
        var c = URLComponents(string: "https://letterboxd.com/s/check-viewingable-relation")!
        c.queryItems = [URLQueryItem(name: "viewingableUID", value: "film:\(f.id)")]
        let r = try await transport.get(try Validate.url(c.url!), accept: "application/json", credentials: credentials)
        try check(r)
        guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true,
              let w = j["isInWatchlist"] as? Bool, let l = j["liked"] as? Bool else { throw LetterboxdError.parse("relation") }
        return FilmState(watchlist: w, liked: l)
        }
    }
    public func setLike(_ f: FilmHandle, liked: Bool) async throws -> LikeResult {
        try await guarded(f.credentials) { credentials in
            try Task.checkCancellation()
            let u = URL(string: "https://letterboxd.com/s/film:\(f.id)/like/")!
            var c = URLComponents(); c.queryItems = [URLQueryItem(name: "liked", value: liked ? "true" : "false"), URLQueryItem(name: "__csrf", value: f.csrf)]
            let body = Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
            let r = try await transport.send(WriteRequest(method: "POST", url: u, contentType: "application/x-www-form-urlencoded", body: body), credentials: credentials)
            try check(r)
            guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true, let l = j["liked"] as? Bool, l == liked
            else { throw LetterboxdError.parse("like response") }
            return LikeResult(liked: l, count: j["count"] as? Int)
        }
    }
}

extension FilmActions: FilmActionsClient {
    public var supportsRating: Bool { true }
    public func ratingState(slug: String) async throws -> RatingState {
        let h = try await handle(slug: slug)
        return try await ratingState(h)
    }
    public func state(slug: String) async throws -> FilmState {
        let h = try await handle(slug: slug)
        return try await guarded(h.credentials) { _ in try await relation(h) }
    }
    public func setWatchlist(slug: String, on: Bool) async throws -> FilmState {
        let h = try await handle(slug: slug)
        try await setWatchlist(h, on: on)
        return try await guarded(h.credentials) { _ in try await relation(h) }
    }
    public func setLike(slug: String, liked: Bool) async throws -> FilmState {
        let h = try await handle(slug: slug)
        _ = try await setLike(h, liked: liked)
        let st = try await guarded(h.credentials) { _ in try await relation(h) }
        guard st.liked == liked else { throw LetterboxdError.parse("like readback mismatch") }
        return st
    }
}

/// Rating and watched, built ONLY from the Oct 14 captures (sanitized: /home/kit/out/letterboxd-network/rating-watched/):
/// PATCH /api/v0/me/rate/{lid}      JSON {"rating":0.5...5.0} or {"rating":null}, header x-csrf-token, 204 empty
/// POST  /s/film:{id}/watch/        form watched=<bool>&__csrf=, response {result,watched}
/// Readback: POST /ajax/letterboxd-metadata/ productions=film:{id}&__csrf= -> {watched:[uid], ratings:[{uid,rating}]}
/// (rating is in half-star units: 0.5 stars is 1). Setting a rating marks the film watched on the server; clearing it does not unwatch.
public struct RatingState: Sendable, Equatable { public let rating: Double?, watched: Bool
    public init(rating: Double?, watched: Bool) { self.rating = rating; self.watched = watched } }

extension FilmActions {
    public static func validRating(_ r: Double) -> Bool { r >= 0.5 && r <= 5 && (r * 2).rounded() == r * 2 }
    private func form(_ pairs: [(String, String)]) -> Data {
        var c = URLComponents(); c.queryItems = pairs.map { URLQueryItem(name: $0.0, value: $0.1) }
        return Data((c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
    public func ratingState(_ f: FilmHandle) async throws -> RatingState {
        try await guarded(f.credentials) { credentials in
        let u = URL(string: "https://letterboxd.com/ajax/letterboxd-metadata/")!
        let r = try await transport.send(WriteRequest(method: "POST", url: u, contentType: "application/x-www-form-urlencoded", body: form([("productions", "film:\(f.id)"), ("__csrf", f.csrf)])), credentials: credentials)
        try check2(r)
        guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true else { throw LetterboxdError.parse("metadata") }
        let watched = (j["watched"] as? [String] ?? []).contains("film:\(f.id)")
        var rating: Double? = nil
        for e in j["ratings"] as? [[String: Any]] ?? [] where e["uid"] as? String == "film:\(f.id)" {
            if let n = e["rating"] as? Double ?? (e["rating"] as? Int).map(Double.init) { rating = n / 2 }
        }
        return RatingState(rating: rating, watched: watched)
        }
    }
    private func check2(_ r: HTTPResult) throws {
        if r.status == 403 || r.status == 429 { throw LetterboxdError.blocked(status: r.status) }
        guard r.status == 200 else { throw LetterboxdError.http(status: r.status) }
    }
    /// nil clears. Returns server-confirmed state or throws.
    public func setRating(slug: String, rating: Double?) async throws -> RatingState {
        if let r = rating, !Self.validRating(r) { throw LetterboxdError.parse("rating out of range") }
        let h = try await handle(slug: slug)
        return try await guarded(h.credentials) { credentials in
            try Task.checkCancellation()
            let u = URL(string: "https://letterboxd.com/api/v0/me/rate/\(h.lid)")!
            let body = try JSONSerialization.data(withJSONObject: ["rating": (rating.map { $0 as Any } ?? NSNull())])
            let r = try await transport.send(WriteRequest(method: "PATCH", url: u, contentType: "application/json; charset=UTF-8", body: body, headers: ["x-csrf-token": h.csrf]), credentials: credentials)
            guard r.status == 204 || r.status == 200 else { throw LetterboxdError.http(status: r.status) }
            guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
            let st = try await ratingState(h)
            guard st.rating == rating else { throw LetterboxdError.parse("rating readback mismatch") }
            return st
        }
    }
    public func setWatched(slug: String, watched: Bool) async throws -> RatingState {
        let h = try await handle(slug: slug)
        return try await guarded(h.credentials) { credentials in
            try Task.checkCancellation()
            let u = URL(string: "https://letterboxd.com/s/film:\(h.id)/watch/")!
            let r = try await transport.send(WriteRequest(method: "POST", url: u, contentType: "application/x-www-form-urlencoded", body: form([("watched", watched ? "true" : "false"), ("__csrf", h.csrf)])), credentials: credentials)
            try check2(r)
            guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
            let st = try await ratingState(h)
            guard st.watched == watched else { throw LetterboxdError.parse("watched readback mismatch") }
            return st
        }
    }
}
