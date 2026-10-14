import SwiftUI
import WebKit
import LetterboxdKit

/// Account state. The session is trusted only after the server confirms the identity (see LiveAccountService.complete).
@Observable @MainActor
final class AccountModel {
    let service: LiveAccountService
    private let store: SessionStore
    var username: String? { didSet { onUsernameChange?(username) } }
    var failure: String?
    /// Why the last restore could not confirm a stored session (offline etc.); nil otherwise.
    var restoreFailure: String?
    /// Called synchronously whenever the validated username changes (including to nil on sign-out).
    var onUsernameChange: ((String?) -> Void)?
    private let fetch: HomepageFetcher
    enum Gate: Equatable { case checking, restoreFailed(String), signInRequired, ready(String) }
    /// The only thing the UI may use to decide what to show: app content needs a server-validated username.
    var gate: Gate {
        if let u = username { return .ready(u) }
        if validating { return .checking }
        if let r = restoreFailure { return .restoreFailed(r) }
        return .signInRequired
    }
    /// True until the first server validation of any stored session finishes; UI must not show a stored name as signed in.
    var validating = true
    /// Bumped on every auth state change; the root view is rebuilt on it so no model keeps previous-account data.
    private(set) var epoch = 0
    /// Set by the app before restore(); the only holder of credentials used for requests.
    var auth: AuthAuthority?
    /// The web view's data store. Owned here so sign-out clears the store actually used.
    private(set) var webStore = WKWebsiteDataStore.nonPersistent()
    init(store: SessionStore = KeychainSessionStore(), fetch: @escaping HomepageFetcher = AccountModel.fetchHomepage) {
        self.store = store; self.fetch = fetch; service = LiveAccountService(store: store)
    }
    /// Restores a stored session only after cookie attributes and the server both confirm it.
    func restore() async {
        validating = true; restoreFailure = nil
        defer { validating = false }
        let before = username
        let my = service.beginOperation()
        do {
            let r = try await service.restore(fetch: fetch, token: my)
            guard service.isCurrent(my) else { return }
            if let s = r { auth?.setValidated(s); username = s.username }
            else { auth?.revoke(); username = nil }
        } catch { guard service.isCurrent(my) else { return }; auth?.revoke(); username = nil; restoreFailure = "Check your connection and try again, or sign in again." }  // unverifiable (e.g. offline): no credentials sent until validated
        if username != before { epoch += 1 }   // rebuild views only on a real account change
    }
    func complete(with cookies: [HTTPCookie]) async -> Bool {
        let mapped = cookies.map { WebCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate, secure: $0.isSecure) }
        let my = service.beginOperation()
        do {
            let s = try await service.complete(cookies: mapped, fetch: fetch, token: my)
            guard service.isCurrent(my) else { return false }
            auth?.setValidated(s); username = s.username; failure = nil; restoreFailure = nil; epoch += 1; return true
        } catch { failure = "Letterboxd did not confirm a signed-in account yet. Finish signing in on the page, then tap Done."; return false }
    }
    /// Removes the Keychain session and any web data left for the site.
    func signOut() async {
        auth?.revoke()   // stops credentials immediately and invalidates in-flight responses
        username = nil; epoch += 1
        // ONE synchronous commit boundary before any await: obsoletes pending operations and clears the store atomically.
        do { try service.signOutNow() } catch { failure = "Could not remove the stored session." }
        let ds = webStore
        let recs = await ds.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await ds.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: recs.filter { $0.displayName == "letterboxd.com" })
        webStore = .nonPersistent()
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse, newRequest: URLRequest) async -> URLRequest? { nil }
    }
    @Sendable static func fetchHomepage(_ session: Session) async throws -> (status: Int, html: String) {
        let c = URLSessionConfiguration.ephemeral; c.httpCookieStorage = nil; c.httpShouldSetCookies = false
        var r = URLRequest(url: URL(string: "https://letterboxd.com/")!)
        r.setValue(session.header(), forHTTPHeaderField: "Cookie")
        r.setValue("LetterboxdReader/0.1 (personal client; user-triggered)", forHTTPHeaderField: "User-Agent")
        let (d, resp) = try await URLSession(configuration: c, delegate: NoRedirect(), delegateQueue: nil).data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: d, as: UTF8.self))
    }
}

/// The site's own sign-in page. No injected scripts or message handlers, so the app does not intercept or store the password or captcha token.
struct SiteWebView: UIViewRepresentable {
    let store: WKWebsiteDataStore
    let onReady: (WKWebView) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = store
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.navigationDelegate = context.coordinator; v.uiDelegate = context.coordinator
        v.isOpaque = false; v.backgroundColor = .black; v.scrollView.backgroundColor = .black
        v.load(URLRequest(url: URL(string: "https://letterboxd.com/sign-in/")!))
        onReady(v); return v
    }
    func updateUIView(_ v: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction) async -> WKNavigationActionPolicy {
            let ok = NavigationPolicy.allows(a.request.url, mainFrame: a.targetFrame?.isMainFrame ?? true) && a.targetFrame != nil
            #if DEBUG
            NSLog("NAV %@ scheme=%@ host=%@ main=%d target=%@", ok ? "ALLOW" : "CANCEL", a.request.url?.scheme ?? "-", a.request.url?.host ?? "-", (a.targetFrame?.isMainFrame ?? true) ? 1 : 0, a.targetFrame == nil ? "nil" : "frame")
            #endif
            return ok ? .allow : .cancel
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { NSLog("NAV didFail code=%d", (e as NSError).code) }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { NSLog("NAV didFailProv code=%d", (e as NSError).code) }
        func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    }
}

struct SignInScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AccountModel.self) private var account
    @State private var web: WKWebView?
    @State private var checking = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SiteWebView(store: account.webStore) { web = $0 }
                if let f = account.failure {
                    Text(f).font(.footnote).foregroundStyle(Theme.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card)
                }
            }
            .background(Color.black)
            .navigationTitle("Sign in").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await finish() } } label: { if checking { ProgressView() } else { Text("Done").bold() } }.disabled(checking || web == nil)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text("You sign in on letterboxd.com itself. This app hosts the page but does not read or store your password.")
                    .font(.caption2).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity).background(.black)
            }
        }
        .onAppear { account.failure = nil }
    }
    private func finish() async {
        guard let web else { return }
        checking = true; defer { checking = false }
        let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
        if await account.complete(with: cookies) { dismiss() }
    }
}

struct AccountButton: ToolbarContent {
    @Environment(AccountModel.self) private var account
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            if let u = account.username {
                Menu {
                    Text("Signed in as \(u)")
                    Button("Sign out", role: .destructive) { Task { await account.signOut() } }
                } label: { Image(systemName: "person.crop.circle.fill") }
                .accessibilityLabel("Account")
            }
        }
    }
}
