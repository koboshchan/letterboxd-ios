import XCTest
@testable import LetterboxdKit

// Entirely synthetic values. The control order/type and successful-control behavior
// follow the captured profile POST, not the user's private form content.
private func auditSettings(bio: String = "before", token: String = "formtoken1234",
                           email: String = "fixture@example.com", outsideChecked: Bool = true,
                           hiddenPassword: String = "", pronoun: String = "They") -> String {
    """
    <form action="/user/update.do" method="post">
    <input name="__csrf" type="hidden" value="\(token)">
    <input name="completeSettings" type="hidden" value="true">
    <input name="username" value="fixture" disabled>
    <input name="givenName" value="Fixture"><input name="familyName" value="">
    <input name="emailAddress" value="\(email)"><input name="location" value=""><input name="website" value="">
    <textarea name="bio">\(bio)</textarea>
    <select name="pronoun"><option>He</option><option selected>\(pronoun)</option></select>
    <select name="posterMode"><option selected value="All">All</option></select>
    <select name="commentPolicy"><option selected value="Anyone">Anyone</option></select>
    <input name="privacyIncludeInPeopleSection" type="checkbox" value="true" checked>
    <input name="showAdultContent" type="checkbox" value="true">
    <input name="password" type="hidden" value="\(hiddenPassword)">
    </form>
    <form action="/user/password.do"><input name="__csrf" value="other1234">
    <input name="currentPassword" type="password" value=""><input name="newPassword" type="password" value=""></form>
    <form action="/user/notifications.do"><input name="notifyWhenFollowed" type="checkbox" value="true" \(outsideChecked ? "checked" : "")>
    <input name="authenticationCode" value="" disabled></form>
    """
}
private actor AuditWire {
    var pages: [String]
    var gets: [String] = []
    var requests: [WriteRequest] = []
    var cookies: [String] = []
    var response: HTTPResult
    let barrier: AuditBarrier?
    let pauseAt: String?
    init(pages: [String], response: HTTPResult, barrier: AuditBarrier? = nil, pauseAt: String? = nil) {
        self.pages = pages; self.response = response; self.barrier = barrier; self.pauseAt = pauseAt
    }
    func get(_ url: URL, _ c: RequestCredentials) async -> HTTPResult {
        gets.append(url.path); cookies.append(c.cookie)
        if pauseAt == "get" { await barrier?.pause() }
        return HTTPResult(data: Data(pages.removeFirst().utf8), status: 200)
    }
    func send(_ r: WriteRequest, _ c: RequestCredentials) async -> HTTPResult {
        requests.append(r); cookies.append(c.cookie)
        if pauseAt == "send" { await barrier?.pause() }
        return response
    }
}
private actor AuditBarrier {
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true; arrival?.resume(); arrival = nil
        await withCheckedContinuation { release = $0 }
    }
    func wait() async { if !entered { await withCheckedContinuation { arrival = $0 } } }
    func resume() { release?.resume(); release = nil }
}
private struct AuditTransport: HTTPTransport {
    let wire: AuditWire
    func get(_ url: URL, accept: String) async throws -> HTTPResult { XCTFail("Unpinned GET"); throw LetterboxdError.cancelled }
    func send(_ r: WriteRequest) async throws -> HTTPResult { XCTFail("Unpinned POST"); throw LetterboxdError.cancelled }
    func get(_ url: URL, accept: String, credentials: RequestCredentials) async throws -> HTTPResult { await wire.get(url, credentials) }
    func send(_ r: WriteRequest, credentials: RequestCredentials) async throws -> HTTPResult { await wire.send(r, credentials) }
}
final class AccountWireAuditTests: XCTestCase {
    private func auth() -> AuthAuthority {
        let a = AuthAuthority(); a.setValidated(session("alice")); return a
    }
    private func session(_ value: String) -> Session {
        Session(username: value, cookies: [WebCookie(name: SessionCookies.sessionCookieName, value: value, domain: "letterboxd.com")])
    }
    private let fields = ProfileFields(givenName: "Fixture", familyName: "", location: "", website: "", bio: "after")
    private func result(_ body: String, status: Int = 200) -> HTTPResult { HTTPResult(data: Data(body.utf8), status: status) }

    func testProfileExactCapturedOrderedWireShapeAndRotatingCSRFReadback() async throws {
        let wire = AuditWire(pages: [auditSettings(), auditSettings(bio: "after", token: "rotated1234")],
                             response: result(#"{"result":true,"errorFields":[],"errorCodes":["update.user.profile.successful"]}"#))
        let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
        let confirmed = try await client.saveProfile(fields)
        XCTAssertEqual(confirmed, fields)
        let request = await wire.requests[0]
        XCTAssertEqual(request.url.path, "/user/update.do")
        XCTAssertEqual(request.contentType, "application/x-www-form-urlencoded; charset=UTF-8")
        XCTAssertEqual(request.headers["X-Requested-With"], "XMLHttpRequest")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self),
                       "__csrf=formtoken1234&completeSettings=true&givenName=Fixture&familyName=&emailAddress=fixture%40example.com&location=&website=&bio=after&pronoun=They&posterMode=All&commentPolicy=Anyone&privacyIncludeInPeopleSection=true&password=")
    }
    func testReadbackRejectsEmailAndOutsideFormUncheckedStateChanges() async throws {
        for after in [auditSettings(bio: "after", email: "changed@example.com"),
                      auditSettings(bio: "after", outsideChecked: false)] {
            let wire = AuditWire(pages: [auditSettings(), after], response: result(#"{"result":true,"errorFields":[]}"#))
            let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
            do { _ = try await client.saveProfile(fields); XCTFail("Must reject unrelated field drift") }
            catch { XCTAssertEqual(error as? LetterboxdError, .parse("profile readback mismatch")) }
        }
    }
    func testNonemptyHiddenPasswordAndWrongFormTargetFailBeforeMutation() async throws {
        for page in [auditSettings(hiddenPassword: "not-empty"),
                     auditSettings().replacingOccurrences(of: "/user/update.do", with: "/user/password.do")] {
            let wire = AuditWire(pages: [page], response: result("{}"))
            let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
            do { _ = try await client.saveProfile(fields); XCTFail() } catch {}
            let count = await wire.requests.count; XCTAssertEqual(count, 0)
        }
    }
    func testAllEditableProfileFieldsPostAndConfirmWithoutChangingOtherSettings() async throws {
        var changed = fields
        changed.givenName = "New & Name"; changed.location = "Vancouver"; changed.website = "https://example.com/"
        let after = auditSettings(bio: "after")
            .replacingOccurrences(of: "value=\"Fixture\"", with: "value=\"New &amp; Name\"")
            .replacingOccurrences(of: "name=\"location\" value=\"\"", with: "name=\"location\" value=\"Vancouver\"")
            .replacingOccurrences(of: "name=\"website\" value=\"\"", with: "name=\"website\" value=\"https://example.com/\"")
        let wire = AuditWire(pages: [auditSettings(), after], response: result(#"{"result":true,"errorFields":[]}"#))
        let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
        let confirmed = try await client.saveProfile(changed)
        XCTAssertEqual(confirmed, changed)
        let request = await wire.requests[0]
        let body = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(body.contains("givenName=New+%26+Name&familyName="))
        XCTAssertTrue(body.contains("location=Vancouver&website=https%3A%2F%2Fexample.com%2F"))
        XCTAssertTrue(body.contains("emailAddress=fixture%40example.com"))
    }
    func testConcurrentProfileDraftChangeBlocksBeforePOST() async throws {
        let wire = AuditWire(pages: [auditSettings(bio: "changed elsewhere")], response: result("{}"))
        let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
        let original = ProfileFields(givenName: "Fixture", familyName: "", location: "", website: "", bio: "before")
        do { _ = try await client.saveProfile(fields, expected: original); XCTFail() }
        catch { XCTAssertEqual(error as? LetterboxdError, .parse("profile changed elsewhere; reload")) }
        let count = await wire.requests.count; XCTAssertEqual(count, 0)
    }
    func testPrivateListUsesCapturedHomeTokenNotUnprovenNewListPage() async throws {
        let wire = AuditWire(pages: ["<script>supermodelCSRF = 'syntheticToken123';</script>"],
                             response: result(#"{"data":{"id":"TestL42","name":"Fixture","published":false,"sharePolicy":"You"},"messages":[]}"#))
        let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
        let confirmed = try await client.createPrivateList(name: "Fixture", description: "")
        XCTAssertEqual(confirmed.id, "TestL42")
        let paths = await wire.gets; XCTAssertEqual(paths, ["/"])
        let request = await wire.requests[0]
        XCTAssertEqual(request.headers["x-csrf-token"], "syntheticToken123")
        XCTAssertEqual(request.headers["Referer"], "https://letterboxd.com/list/new/")
        let payload = try JSONSerialization.jsonObject(with: request.body) as! NSDictionary
        XCTAssertEqual(payload, ["published": false, "name": "Fixture", "sharePolicy": "You", "ranked": false,
                                 "description": "", "tags": [], "entries": []] as NSDictionary)
    }
    func testMissingTokenNeverPostsAnd403NeverConfirmsList() async throws {
        for (page, status) in [("<html>No token</html>", 200),
                               ("<script>supermodelCSRF = 'synthetic1234';</script>", 403)] {
            let wire = AuditWire(pages: [page], response: result("{}", status: status))
            let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
            do { _ = try await client.createPrivateList(name: "Fixture", description: ""); XCTFail() } catch {}
            let count = await wire.requests.count; XCTAssertEqual(count, status == 403 ? 1 : 0)
        }
    }
    func testListResponseMustConfirmPrivateNameAndSharePolicy() async throws {
        for body in [
            #"{"data":{"id":"TestL42","name":"Fixture","published":true,"sharePolicy":"You"}}"#,
            #"{"data":{"id":"TestL42","name":"Fixture","published":false,"sharePolicy":"Everyone"}}"#,
            #"{"data":{"id":"TestL42","name":"Wrong","published":false,"sharePolicy":"You"}}"#
        ] {
            let wire = AuditWire(pages: ["<script>supermodelCSRF = 'synthetic1234';</script>"], response: result(body))
            let client = AccountActions(transport: AuditTransport(wire: wire), auth: auth())
            do { _ = try await client.createPrivateList(name: "Fixture", description: ""); XCTFail() } catch {}
        }
    }
    func testProfileAndListSwitchAtGETOrPOSTRemainBoundToOriginatingAccount() async throws {
        for profile in [true, false] {
            for phase in ["get", "send"] {
                let a = auth(); let barrier = AuditBarrier()
                let page = profile ? auditSettings() : "<script>supermodelCSRF = 'synthetic1234';</script>"
                let wire = AuditWire(pages: [page], response: result("{}"), barrier: barrier, pauseAt: phase)
                let client = AccountActions(transport: AuditTransport(wire: wire), auth: a)
                let fields = self.fields
                let task = Task {
                    if profile { _ = try await client.saveProfile(fields) }
                    else { _ = try await client.createPrivateList(name: "Fixture", description: "") }
                }
                await barrier.wait(); a.setValidated(session("bob")); await barrier.resume()
                do { try await task.value; XCTFail() } catch {}
                let cookies = await wire.cookies
                XCTAssertTrue(cookies.allSatisfy { $0 == "letterboxd.user.CURRENT=alice" })
                let count = await wire.requests.count; XCTAssertEqual(count, phase == "get" ? 0 : 1)
            }
        }
    }
}
