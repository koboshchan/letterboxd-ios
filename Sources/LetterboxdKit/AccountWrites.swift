import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Profile and list writes, built ONLY from the Oct 14 captures (/home/kit/out/letterboxd-network/):
/// Profile: GET /settings/ (form containing completeSettings), POST /user/update.do
///   application/x-www-form-urlencoded, the whole form as the browser serialises it (checked boxes only, username disabled),
///   response {result:true, errorFields:[], errorCodes:["update.user.profile.successful"]}.
///   Readback: GET /settings/ again; every control is compared, so untouched fields are provably preserved.
/// List:    POST /api/v0/lists JSON {published,name,sharePolicy,ranked,description,tags,entries}, header x-csrf-token,
///   response {data:{id,name,published,sharePolicy,...}}. Only the PRIVATE shape (published:false, sharePolicy "You") was captured,
///   so public lists are not offered. The csrf comes from the captured home page's supermodelCSRF assignment,
/// whose value equals the successful list POST header in the same captured session.
public struct ProfileFields: Sendable, Equatable {
    public var givenName: String, familyName: String, location: String, website: String, bio: String
    public init(givenName: String, familyName: String, location: String, website: String, bio: String) {
        self.givenName = givenName; self.familyName = familyName; self.location = location; self.website = website; self.bio = bio
    }
    static let names = ["givenName", "familyName", "location", "website", "bio"]
    static func norm(_ s: String) -> String { s.replacingOccurrences(of: "\r\n", with: "\n") }
    func value(_ name: String) -> String {
        switch name { case "givenName": givenName; case "familyName": familyName; case "location": location; case "website": website; default: bio }
    }
}

public struct CreatedList: Sendable, Equatable {
    public let id: String, name: String, isPrivate: Bool
    public init(id: String, name: String, isPrivate: Bool) { self.id = id; self.name = name; self.isPrivate = isPrivate }
}

/// What the profile editor and the new-list sheet talk to. AccountActions is production; the UI-test host injects a mock.
public protocol AccountEditingClient: Sendable {
    func loadProfile() async throws -> ProfileFields
    /// Returns what the server shows after saving, or throws.
    func saveProfile(_ f: ProfileFields) async throws -> ProfileFields
    func saveProfile(_ f: ProfileFields, expected: ProfileFields) async throws -> ProfileFields
    func createPrivateList(name: String, description: String) async throws -> CreatedList
}
extension AccountEditingClient {
    public func saveProfile(_ f: ProfileFields, expected: ProfileFields) async throws -> ProfileFields { try await saveProfile(f) }
}

/// The settings form exactly as served: ordered controls with the value a browser would submit.
public struct SettingsForm: Sendable, Equatable {
    public let controls: [(name: String, value: String)]
    /// In-memory full-page safety snapshot, including controls outside the edited form. Never persisted.
    private let preservation: [String]
    public static func == (a: SettingsForm, b: SettingsForm) -> Bool { a.controls.elementsEqual(b.controls) { $0.name == $1.name && $0.value == $1.value } && a.preservation == b.preservation }
    public func value(_ n: String) -> String? { controls.first { $0.name == n }?.value }
    public var csrf: String? { value("__csrf").flatMap { $0.isEmpty ? nil : $0 } }

    public static func parse(html: String) throws -> SettingsForm {
        let doc = try SwiftSoup.parse(html, "https://letterboxd.com/")
        guard let form = try doc.select("form").array().first(where: { (try? $0.select("input[name=completeSettings]").isEmpty()) == false }) else {
            throw LetterboxdError.parse("settings form")
        }
        guard try form.attr("method").lowercased() == "post",
              try form.attr("action") == "/user/update.do" else { throw LetterboxdError.parse("settings form target") }
        var preservation: [String] = []
        for el in try doc.select("input, textarea, select").array() {
            let name = try el.attr("name")
            guard !name.isEmpty, name != "__csrf", !ProfileFields.names.contains(name) else { continue }
            let value: String
            if el.tagName() == "textarea" { value = try el.text(trimAndNormaliseWhitespace: false) }
            else if el.tagName() == "select" {
                value = try el.select("option").array().filter { $0.hasAttr("selected") }.map { try $0.hasAttr("value") ? $0.attr("value") : $0.text() }.joined(separator: "\u{0}")
            } else { value = try el.attr("value") }
            preservation.append([name, el.tagName(), try el.attr("type"), el.hasAttr("disabled") ? "disabled" : "", el.hasAttr("checked") ? "checked" : "", ProfileFields.norm(value)].joined(separator: "\u{0}"))
        }
        var out: [(String, String)] = []
        for el in try form.select("input, textarea, select").array() {
            let name = try el.attr("name")
            guard !name.isEmpty, !el.hasAttr("disabled") else { continue }
            switch el.tagName() {
            case "textarea":
                out.append((name, try el.text(trimAndNormaliseWhitespace: false)))
            case "select":
                let opts = try el.select("option").array()
                let chosen = opts.first(where: { $0.hasAttr("selected") }) ?? opts.first
                if let c = chosen { out.append((name, try c.hasAttr("value") ? c.attr("value") : c.text())) }
            default:
                let type = (try el.attr("type")).lowercased()
                if ["submit", "button", "file", "image", "reset", "password"].contains(type) { continue }
                if type == "checkbox" || type == "radio" {
                    guard el.hasAttr("checked") else { continue }
                    out.append((name, el.hasAttr("value") ? try el.attr("value") : "on"))
                } else { out.append((name, try el.attr("value"))) }
            }
        }
        guard out.contains(where: { $0.0 == "__csrf" }) else { throw LetterboxdError.parse("settings csrf") }
        for n in ProfileFields.names where !out.contains(where: { $0.0 == n }) { throw LetterboxdError.parse("settings field \(n)") }
        guard out.filter({ $0.0 == "completeSettings" }).map(\.1) == ["true"],
              out.filter({ $0.0 == "password" }).allSatisfy({ $0.1.isEmpty }),
              !out.contains(where: { ["currentPassword", "newPassword", "confirmPassword"].contains($0.0) })
        else { throw LetterboxdError.parse("unsafe settings form") }
        return SettingsForm(controls: out, preservation: preservation)
    }
    public var fields: ProfileFields {
        ProfileFields(givenName: value("givenName") ?? "", familyName: value("familyName") ?? "", location: value("location") ?? "",
                      website: value("website") ?? "", bio: ProfileFields.norm(value("bio") ?? ""))
    }
    /// Browser-style urlencoding: everything but unreserved is %XX, space is +; newlines in values become CRLF as browsers submit them.
    static func encode(_ s: String) -> String {
        var o = ""
        for b in s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8 {
            switch b {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2A, 0x2D, 0x2E, 0x5F: o.unicodeScalars.append(Unicode.Scalar(b))
            case 0x20: o += "+"
            default: o += String(format: "%%%02X", Int(b))
            }
        }
        return o
    }
    /// The POST body: every successful control as served; production saves restrict changes to bio.
    func body(applying f: ProfileFields) -> Data {
        let pairs = controls.map { c -> (String, String) in ProfileFields.names.contains(c.name) ? (c.name, f.value(c.name)) : (c.name, c.value) }
        return Data(pairs.map { Self.encode($0.0) + "=" + Self.encode($0.1) }.joined(separator: "&").utf8)
    }
    /// Everything except the five editable fields and the rotating csrf token.
    var untouched: [String] { preservation }
}

public final class AccountActions: Sendable {
    let transport: HTTPTransport; let auth: AuthAuthority
    public init(transport: HTTPTransport, auth: AuthAuthority) { self.transport = transport; self.auth = auth }

    private func guarded<T: Sendable>(_ body: (RequestCredentials) async throws -> T) async throws -> T {
        let credentials = try auth.requestCredentials()
        guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
        let v = try await body(credentials)
        guard auth.generation == credentials.generation else { throw LetterboxdError.cancelled }
        return v
    }
    private func page(_ path: String, _ c: RequestCredentials) async throws -> String {
        let r = try await transport.get(try Validate.url(URL(string: "https://letterboxd.com" + path)!), accept: "text/html", credentials: c)
        try BlockDetector.check(r)
        return String(decoding: r.data, as: UTF8.self)
    }
    private func settings(_ c: RequestCredentials) async throws -> SettingsForm { try SettingsForm.parse(html: try await page("/settings/", c)) }

    public func loadProfile() async throws -> ProfileFields {
        try await guarded { c in try await settings(c).fields }
    }
    public func saveProfile(_ f: ProfileFields) async throws -> ProfileFields {
        try await saveProfile(f, original: nil)
    }
    public func saveProfile(_ f: ProfileFields, expected: ProfileFields) async throws -> ProfileFields {
        try await saveProfile(f, original: expected)
    }
    private func saveProfile(_ f: ProfileFields, original: ProfileFields?) async throws -> ProfileFields {
        try await guarded { c in
            try Task.checkCancellation()
            let before = try await settings(c)
            if let original, before.fields != original { throw LetterboxdError.parse("profile changed elsewhere; reload") }
            guard f.givenName == before.fields.givenName, f.familyName == before.fields.familyName,
                  f.location == before.fields.location, f.website == before.fields.website else {
                throw LetterboxdError.invalidInput("Only bio edits are verified")
            }
            guard auth.generation == c.generation else { throw LetterboxdError.cancelled }
            let want = ProfileFields(givenName: f.givenName, familyName: f.familyName, location: f.location, website: f.website, bio: ProfileFields.norm(f.bio))
            let req = WriteRequest(method: "POST", url: URL(string: "https://letterboxd.com/user/update.do")!,
                                   contentType: "application/x-www-form-urlencoded; charset=UTF-8", body: before.body(applying: want),
                                   headers: ["Referer": "https://letterboxd.com/settings/", "X-Requested-With": "XMLHttpRequest", "Accept": "*/*"])
            let r = try await transport.send(req, credentials: c)
            if r.status == 403 || r.status == 429 { throw LetterboxdError.blocked(status: r.status) }
            guard r.status == 200 else { throw LetterboxdError.http(status: r.status) }
            guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], j["result"] as? Bool == true,
                  (j["errorFields"] as? [Any] ?? []).isEmpty else { throw LetterboxdError.parse("profile rejected") }
            guard auth.generation == c.generation else { throw LetterboxdError.cancelled }
            let after = try await settings(c)
            guard after.fields == want, after.untouched == before.untouched else { throw LetterboxdError.parse("profile readback mismatch") }
            return after.fields
        }
    }

    static func csrf(inPage html: String) -> String? {
        guard let r = html.range(of: #"supermodelCSRF\s*=\s*'([A-Za-z0-9]{8,64})'"#, options: .regularExpression) else { return nil }
        let m = String(html[r]); guard let q1 = m.firstIndex(of: "'"), let q2 = m.lastIndex(of: "'"), q1 < q2 else { return nil }
        return String(m[m.index(after: q1)..<q2])
    }
    public func createPrivateList(name: String, description: String) async throws -> CreatedList {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { throw LetterboxdError.invalidInput("list name") }
        let d = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await guarded { c in
            try Task.checkCancellation()
            guard let token = Self.csrf(inPage: try await page("/", c)) else { throw LetterboxdError.parse("list csrf") }
            guard auth.generation == c.generation else { throw LetterboxdError.cancelled }
            let body = try JSONSerialization.data(withJSONObject: ["published": false, "name": n, "sharePolicy": "You", "ranked": false, "description": d, "tags": [String](), "entries": [String]()] as [String: Any])
            let r = try await transport.send(WriteRequest(method: "POST", url: URL(string: "https://letterboxd.com/api/v0/lists")!, contentType: "application/json; charset=UTF-8", body: body,
                                                          headers: ["x-csrf-token": token, "Referer": "https://letterboxd.com/list/new/", "Accept": "*/*"]), credentials: c)
            if r.status == 403 || r.status == 429 { throw LetterboxdError.blocked(status: r.status) }
            guard r.status == 200 || r.status == 201 else { throw LetterboxdError.http(status: r.status) }
            guard let j = try JSONSerialization.jsonObject(with: r.data) as? [String: Any], let data = j["data"] as? [String: Any],
                  let id = data["id"] as? String, id.range(of: "^[A-Za-z0-9]{1,12}$", options: .regularExpression) != nil,
                  data["name"] as? String == n, data["published"] as? Bool == false, data["sharePolicy"] as? String == "You"
            else { throw LetterboxdError.parse("list response") }
            // The server omits description when empty; when it returns one it must be ours.
            if let sd = data["description"] as? String, !sd.isEmpty, ProfileFields.norm(sd).trimmingCharacters(in: .whitespacesAndNewlines) != d { throw LetterboxdError.parse("list readback mismatch") }
            return CreatedList(id: id, name: n, isPrivate: true)
        }
    }
}
extension AccountActions: AccountEditingClient {}
