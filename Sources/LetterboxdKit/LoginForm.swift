import Foundation

/// Pure serializer for the site's sign-in form, from static evidence only (login-request-template.sanitized.json).
/// NOT wired to any transport: nothing in this package sends it. A body needs the bootstrap CSRF (window.supermodelCSRF)
/// and a captcha token produced by the site's own Turnstile in a web view; without both it refuses.
public enum LoginForm {
    public enum Missing: Error, Equatable { case bootstrapCSRF, challengeToken }
    public static func body(csrf: String?, username: String, password: String, remember: Bool, captchaToken: String?) throws -> String {
        guard let csrf, !csrf.isEmpty else { throw Missing.bootstrapCSRF }
        guard let captchaToken, !captchaToken.isEmpty else { throw Missing.challengeToken }
        var f: [(String, String)] = [("__csrf", csrf), ("authenticationCode", ""), ("username", username), ("password", password)]
        if remember { f.append(("remember", "true")) }
        f += [("captchaResponse", captchaToken), ("captchaAction", "signin")]
        var cs = URLComponents(); cs.queryItems = f.map { URLQueryItem(name: $0.0, value: $0.1) }
        return (cs.percentEncodedQuery ?? "").replacingOccurrences(of: "%20", with: "+")
    }
}
