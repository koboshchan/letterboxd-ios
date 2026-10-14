import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Raw exchange used only for sign-in. Cookies are carried explicitly so they can be stored in the Keychain.
public struct AuthResponse: Sendable { public let data: Data; public let status: Int; public let setCookies: [String: String]
    public init(data: Data, status: Int, setCookies: [String: String]) { self.data = data; self.status = status; self.setCookies = setCookies } }

public protocol AuthTransport: Sendable {
    func send(method: String, url: URL, form: [String: String]?, cookies: [String: String]) async throws -> AuthResponse
}

public struct URLSessionAuthTransport: AuthTransport {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        session = URLSession(configuration: c)
    }
    public func send(method: String, url: URL, form: [String: String]?, cookies: [String: String]) async throws -> AuthResponse {
        var r = URLRequest(url: try Validate.url(url)); r.httpMethod = method
        r.setValue("LetterboxdReader/0.1 (personal client; user-triggered)", forHTTPHeaderField: "User-Agent")
        if !cookies.isEmpty { r.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        if let form {
            var cs = URLComponents(); cs.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            r.httpBody = Data((cs.percentEncodedQuery ?? "").utf8)
            r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
        }
        do {
            let (d, resp) = try await session.data(for: r)
            let h = resp as? HTTPURLResponse
            var out: [String: String] = [:]
            if let h, let u = h.url {
                let fields = h.allHeaderFields.reduce(into: [String: String]()) { $0["\($1.key)"] = "\($1.value)" }
                for c in HTTPCookie.cookies(withResponseHeaderFields: fields, for: u) { out[c.name] = c.value }
            }
            return AuthResponse(data: d, status: h?.statusCode ?? 0, setCookies: out)
        } catch is CancellationError { throw LetterboxdError.cancelled
        } catch { throw LetterboxdError.network(error.localizedDescription) }
    }
}

/// Sign-in per recorded evidence: form POST /user/login.do with __csrf, authenticationCode, username, password, remember.
/// The CSRF token is the value of cookie com.xk72.webparts.csrf set by a prior GET (cookie/field pairing inferred from
/// the recorded cookie name and the bootstrap name supermodelCSRF; NOT yet verified live). Email sign-in was rejected: username only.
public final class LiveAccountService: AccountService, @unchecked Sendable {
    static let csrfCookie = "com.xk72.webparts.csrf"
    let transport: AuthTransport; let store: SessionStore
    public init(transport: AuthTransport = URLSessionAuthTransport(), store: SessionStore) { self.transport = transport; self.store = store }

    public func signIn(email: String, password: String) async throws -> Session { try await signIn(username: email, password: password) }

    public func signIn(username: String, password: String) async throws -> Session {
        guard !username.contains("@") else { throw AuthError.unsupported("Use your Letterboxd username, not your email address.") }
        let home = URL(string: "https://letterboxd.com/")!
        let first = try await transport.send(method: "GET", url: home, form: nil, cookies: [:])
        if first.status == 403 || first.status == 429 || first.status == 503 { throw AuthError.verificationRequired }
        var jar = first.setCookies
        guard let csrf = jar[Self.csrfCookie] else { throw AuthError.unsupported("No CSRF cookie was issued.") }
        let r = try await transport.send(method: "POST", url: URL(string: "https://letterboxd.com/user/login.do")!,
            form: ["__csrf": csrf, "authenticationCode": "", "username": username, "password": password, "remember": "true"], cookies: jar)
        if r.status == 403 || r.status == 429 { throw AuthError.verificationRequired }
        guard r.status == 200, let resp = try? LoginResponse.decode(r.data) else { throw AuthError.badCredentials }
        guard resp.succeeded else { throw AuthError.badCredentials }
        jar.merge(r.setCookies) { $1 }
        let s = Session(username: username, cookies: jar)
        try store.save(s)
        return s
    }
    public func signOut() async throws { try store.clear() }
    public func setWatchlist(slug: String, on: Bool) async throws { throw AuthError.unsupported("Watchlist writes are not verified.") }
    public func createList(name: String, isPrivate: Bool) async throws -> URL { throw AuthError.unsupported("List writes are not verified.") }
    public func deleteList(_ url: URL) async throws { throw AuthError.unsupported("List writes are not verified.") }
}
