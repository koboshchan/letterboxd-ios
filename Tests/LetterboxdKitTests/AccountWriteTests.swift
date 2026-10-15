import XCTest
@testable import LetterboxdKit

private let settingsHTML: @Sendable (String, String, Bool) -> String = { (bio: String, given: String, adult: Bool) in """
<html><body><script>supermodelCSRF = 'abc123def456';</script>
<form action="/user/update.do" method="post">
<input type="hidden" name="__csrf" value="abc123def456"><input type="hidden" name="completeSettings" value="true">
<input type="text" name="username" value="tester" disabled>
<input type="text" name="givenName" value="\(given)"><input type="text" name="familyName" value="">
<input type="email" name="emailAddress" value="me@example.com"><input type="text" name="location" value="Vancouver"><input type="text" name="website" value="">
<textarea name="bio">\(bio)</textarea>
<select name="pronoun"><option value="He">He</option><option value="They" selected>They</option></select>
<select name="posterMode"><option value="All" selected>All</option></select>
<select name="commentPolicy"><option value="Anyone" selected>Anyone</option></select>
<input type="checkbox" name="privacyIncludeInPeopleSection" value="true" checked>
<input type="checkbox" name="showAdultContent" value="true" \(adult ? "checked" : "")>
<input type="hidden" name="password" value=""><input type="submit" value="Save">
</form>
<form action="/user/password.do"><input type="hidden" name="__csrf" value="zzz"><input type="password" name="currentPassword"></form>
</body></html>
""" }

actor Server {
    var bio = "old"; var given = "Tester"; var posts: [WriteRequest] = []; var reject = false; var ignore = false; var lists: [WriteRequest] = []
    func page(_ path: String) -> HTTPResult {
        if path == "/settings/" || path == "/settings" { return HTTPResult(data: Data(settingsHTML(bio, given, false).utf8), status: 200) }
        return HTTPResult(data: Data("<script>supermodelCSRF = 'listtoken1234';</script>".utf8), status: 200)
    }
    func send(_ r: WriteRequest) -> HTTPResult {
        if r.url.path == "/user/update.do" {
            posts.append(r)
            if reject { return HTTPResult(data: Data(#"{"result":false,"errorFields":["website"],"errorCodes":["x"]}"#.utf8), status: 200) }
            if !ignore {
                let body = String(decoding: r.body, as: UTF8.self)
                for kv in body.split(separator: "&") { let p = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let v = String(p.count > 1 ? p[1] : "").replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
                    if p[0] == "bio" { bio = v.replacingOccurrences(of: "\r\n", with: "\n") }; if p[0] == "givenName" { given = v } }
            }
            return HTTPResult(data: Data(#"{"result":true,"errorFields":[],"errorCodes":["update.user.profile.successful"]}"#.utf8), status: 200)
        }
        lists.append(r)
        let name = (try? JSONSerialization.jsonObject(with: r.body) as? [String: Any])?["name"] as? String ?? ""
        return HTTPResult(data: Data(#"{"data":{"id":"TestL42","name":"\#(name)","published":false,"sharePolicy":"You"},"messages":[]}"#.utf8), status: 200)
    }
    func set(reject: Bool? = nil, ignore: Bool? = nil) { if let reject { self.reject = reject }; if let ignore { self.ignore = ignore } }
}
struct ST: HTTPTransport {
    let s: Server
    func get(_ u: URL, accept: String) async throws -> HTTPResult { await s.page(u.path) }
    func send(_ r: WriteRequest) async throws -> HTTPResult { await s.send(r) }
}
final class AccountWriteTests: XCTestCase {
    func make() -> (AccountActions, Server, AuthAuthority) {
        let a = AuthAuthority(); a.setValidated(Session(username: "tester", cookies: [WebCookie(name: "letterboxd.user.CURRENT", value: "v", domain: "letterboxd.com")]))
        let s = Server(); return (AccountActions(transport: ST(s: s), auth: a), s, a)
    }
    func testFormParsingMatchesBrowserSerialisation() throws {
        let f = try SettingsForm.parse(html: settingsHTML("hi\nthere", "Tester", false))
        XCTAssertEqual(f.controls.map(\.name), ["__csrf","completeSettings","givenName","familyName","emailAddress","location","website","bio","pronoun","posterMode","commentPolicy","privacyIncludeInPeopleSection","password"])
        XCTAssertNil(f.value("username"), "disabled controls are never submitted")
        XCTAssertNil(f.value("showAdultContent"), "unchecked boxes are omitted")
        XCTAssertEqual(f.value("pronoun"), "They")
        XCTAssertNil(f.value("currentPassword"), "other forms on the page are ignored")
    }
    func testSaveSendsWholeFormAndPreservesUntouchedFields() async throws {
        let (a, s, _) = make()
        let r = try await a.saveProfile(ProfileFields(givenName: "Tester", familyName: "", location: "Vancouver", website: "", bio: "new bio\nline 2"))
        XCTAssertEqual(r.bio, "new bio\nline 2")
        let p = await s.posts[0]; let b = String(decoding: p.body, as: UTF8.self)
        XCTAssertEqual(p.headers["X-Requested-With"], "XMLHttpRequest"); XCTAssertEqual(p.headers["Accept"], "*/*")
        XCTAssertEqual(p.method, "POST"); XCTAssertEqual(p.url.absoluteString, "https://letterboxd.com/user/update.do")
        XCTAssertEqual(b, "__csrf=abc123def456&completeSettings=true&givenName=Tester&familyName=&emailAddress=me%40example.com&location=Vancouver&website=&bio=new+bio%0D%0Aline+2&pronoun=They&posterMode=All&commentPolicy=Anyone&privacyIncludeInPeopleSection=true&password=")
    }
    func testServerRejectionAndIgnoredWriteAreErrors() async throws {
        let (a, s, _) = make(); let f = ProfileFields(givenName: "Tester", familyName: "", location: "Vancouver", website: "", bio: "x")
        await s.set(reject: true); do { _ = try await a.saveProfile(f); XCTFail() } catch {}
        await s.set(reject: false, ignore: true)
        do { _ = try await a.saveProfile(f); XCTFail() } catch { XCTAssertTrue("\(error)".contains("readback")) }
    }
    func testSignedOutAndAccountSwitchSendNothing() async throws {
        let (a, s, au) = make(); au.revoke()
        do { _ = try await a.saveProfile(ProfileFields(givenName: "a", familyName: "", location: "", website: "", bio: "")); XCTFail() } catch {}
        do { _ = try await a.createPrivateList(name: "x", description: ""); XCTFail() } catch {}
        let n = await s.posts.count + s.lists.count; XCTAssertEqual(n, 0)
    }
    func testCreateListWireFormatAndValidation() async throws {
        let (a, s, _) = make()
        let l = try await a.createPrivateList(name: "  Rainy  ", description: " d ")
        XCTAssertEqual(l, CreatedList(id: "TestL42", name: "Rainy", isPrivate: true))
        let q = await s.lists[0]
        XCTAssertEqual(q.method, "POST"); XCTAssertEqual(q.contentType, "application/json; charset=UTF-8")
        XCTAssertEqual(q.headers["Referer"], "https://letterboxd.com/list/new/")
        XCTAssertEqual(q.headers["Accept"], "*/*")
        XCTAssertEqual(q.url.absoluteString, "https://letterboxd.com/api/v0/lists"); XCTAssertEqual(q.headers["x-csrf-token"], "listtoken1234")
        let j = try JSONSerialization.jsonObject(with: q.body) as! [String: Any]
        XCTAssertEqual(j["published"] as? Bool, false); XCTAssertEqual(j["sharePolicy"] as? String, "You"); XCTAssertEqual(j["description"] as? String, "d")
        XCTAssertEqual(j["name"] as? String, "Rainy")
        do { _ = try await a.createPrivateList(name: "   ", description: ""); XCTFail() } catch {}
    }
}
