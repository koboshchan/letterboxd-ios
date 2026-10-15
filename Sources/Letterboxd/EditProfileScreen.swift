import SwiftUI
import LetterboxdKit

/// Edit Profile and New List. Both talk to AccountEditingClient (production AccountActions, UI-test mock). Nothing is shown as
/// saved until the server's own readback matched; an account change mid-request discards the result.
enum AccountWriteNotice: Equatable { case none, signIn, blocked, failed(String) }
private func describe(_ error: Error) -> AccountWriteNotice {
    switch error {
    case AuthError.notSignedIn: .signIn
    case LetterboxdError.blocked: .blocked
    case LetterboxdError.invalidInput: .failed("Check the form and try again.")
    case LetterboxdError.parse(let w) where w.contains("changed elsewhere"): .failed("Your profile changed elsewhere. Reload before saving.")
    case LetterboxdError.parse(let w) where w.contains("readback"): .failed("Letterboxd didn’t show the change afterwards. Pull to refresh your profile and check before retrying.")
    case LetterboxdError.parse: .failed("Letterboxd rejected this. Open it on letterboxd.com to check.")
    default: .failed("Couldn’t reach Letterboxd. Try again.")
    }
}
private func text(_ n: AccountWriteNotice) -> String? {
    switch n {
    case .none: nil
    case .signIn: "Sign in again to do this."
    case .blocked: "Letterboxd asked for a human check. Do it on letterboxd.com, then retry."
    case .failed(let s): s
    }
}

@Observable @MainActor
final class EditProfileModel {
    enum Phase: Equatable { case loading, ready, failed }
    private(set) var phase = Phase.loading
    var fields = ProfileFields(givenName: "", familyName: "", location: "", website: "", bio: "")
    private(set) var saved: ProfileFields?
    private(set) var saving = false
    private(set) var notice = AccountWriteNotice.none
    private(set) var didSave = false
    private let client: AccountEditingClient?, auth: AuthAuthority, invalidate: () async -> Void
    init(client: AccountEditingClient?, auth: AuthAuthority, invalidate: @escaping () async -> Void) { self.client = client; self.auth = auth; self.invalidate = invalidate }
    var changed: Bool { saved.map { $0 != fields } ?? false }
    var noticeText: String? { text(notice) }

    func load() async {
        guard let client, phase != .ready else { return }
        phase = .loading; notice = .none
        let g = auth.generation
        do {
            let f = try await client.loadProfile()
            guard auth.generation == g else { return }
            fields = f; saved = f; phase = .ready
        } catch is CancellationError { return }
        catch LetterboxdError.cancelled { return }
        catch { guard auth.generation == g else { return }; phase = .failed; notice = describe(error) }
    }
    func reload() { guard !saving else { return }; phase = .loading; saved = nil; didSave = false }
    func save() async {
        guard let client, let original = saved, !saving, changed else { return }
        saving = true; notice = .none; didSave = false
        let g = auth.generation
        defer { saving = false }
        do {
            let confirmed = try await client.saveProfile(fields, expected: original)
            guard auth.generation == g else { return }
            await invalidate()
            guard auth.generation == g else { return }
            fields = confirmed; saved = confirmed; didSave = true
        } catch is CancellationError { return }
        catch LetterboxdError.cancelled { return }
        catch { guard auth.generation == g else { return }; notice = describe(error) }
    }
}

struct EditProfileScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var model: EditProfileModel?
    var body: some View {
        Group {
            if let m = model { content(m) } else { ProgressView() }
        }
        .navigationTitle("Edit Profile").navigationBarTitleDisplayMode(.inline)

        .task {
            if model == nil { model = EditProfileModel(client: env.account, auth: env.auth, invalidate: { [env] in await env.invalidateReads() }) }
            await model?.load()
        }
    }
    @ViewBuilder private func content(_ m: EditProfileModel) -> some View {
        @Bindable var m = m
        switch m.phase {
        case .loading: ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("edit-profile-loading")
        case .failed:
            VStack(spacing: 12) {
                Text(m.noticeText ?? "Couldn’t load your profile.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Try again") { Task { await m.load() } }.buttonStyle(.bordered).accessibilityIdentifier("edit-profile-retry")
            }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            Form {
                Section("Profile") {
                    LabeledContent("Name") {
                        TextField("Name", text: $m.fields.givenName)
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("profile-given-name")
                    }
                    if !m.fields.familyName.isEmpty {
                        LabeledContent("Last Name") {
                            TextField("Last Name", text: $m.fields.familyName)
                                .multilineTextAlignment(.trailing).accessibilityIdentifier("profile-family-name")
                        }
                    }
                    LabeledContent("Location") {
                        TextField("Not set", text: $m.fields.location)
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("profile-location")
                    }
                    LabeledContent("Website") {
                        TextField("Not set", text: $m.fields.website)
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .multilineTextAlignment(.trailing).accessibilityIdentifier("profile-website")
                    }
                }
                Section("Bio") {
                    TextField("Bio", text: $m.fields.bio, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("profile-bio")
                }
                Section {
                    Button { Task { await m.save() } } label: { HStack { Text("Save Changes"); Spacer(); if m.saving { ProgressView() } } }
                        .disabled(!m.changed || m.saving).accessibilityIdentifier("profile-save")
                    if m.didSave { Label("Saved on Letterboxd", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityIdentifier("profile-saved") }
                    if let t = m.noticeText { Text(t).font(.footnote).foregroundStyle(Theme.orange).accessibilityIdentifier("profile-notice") }
                    if m.notice != .none {
                        Button("Reload") { Task { m.reload(); await m.load() } }.accessibilityIdentifier("profile-reload")
                    }
                } footer: { Text("Your profile changes are confirmed with Letterboxd before showing as saved. Other settings stay as they are.") }
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(m.saving)
        }
    }
}

@Observable @MainActor
final class CreateListModel {
    var name = ""
    var details = ""
    private(set) var creating = false
    private(set) var created: CreatedList?
    private(set) var notice = AccountWriteNotice.none
    private let client: AccountEditingClient?, auth: AuthAuthority, invalidate: () async -> Void
    init(client: AccountEditingClient?, auth: AuthAuthority, invalidate: @escaping () async -> Void) { self.client = client; self.auth = auth; self.invalidate = invalidate }
    var canCreate: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !creating && created == nil }
    var noticeText: String? { text(notice) }
    func create() async {
        guard let client, canCreate else { return }
        creating = true; notice = .none
        let g = auth.generation
        defer { creating = false }
        do {
            let l = try await client.createPrivateList(name: name, description: details)
            guard auth.generation == g else { return }
            await invalidate()
            guard auth.generation == g else { return }
            created = l
        } catch is CancellationError { return }
        catch LetterboxdError.cancelled { return }
        catch { guard auth.generation == g else { return }; notice = describe(error) }
    }
}

struct CreateListSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var model: CreateListModel?
    var body: some View {
        NavigationStack {
            Group { if let m = model { content(m) } else { ProgressView() } }
                .navigationTitle("New List").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(model?.created == nil ? "Cancel" : "Done") { dismiss() }.accessibilityIdentifier("list-cancel") }
                    if let m = model, m.created == nil {
                        ToolbarItem(placement: .confirmationAction) { Button("Create") { Task { await m.create() } }.disabled(!m.canCreate).accessibilityIdentifier("list-create") }
                    }
                }
        }
        .task { if model == nil { model = CreateListModel(client: env.account, auth: env.auth, invalidate: { [env] in await env.invalidateReads() }) } }
    }
    @ViewBuilder private func content(_ m: CreateListModel) -> some View {
        @Bindable var m = m
        Form {
            if let l = m.created {
                Section {
                    Label("Created “\(l.name)”", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityIdentifier("list-created")
                    if let u = env.username.isEmpty ? nil : URL(string: "https://letterboxd.com/\(env.username)/lists/") {
                        Link(destination: u) { Label("View your lists on Letterboxd", systemImage: "safari") }
                    }
                } footer: { Text("It’s private, so it only shows to you on Letterboxd, not in this app’s public Lists tab.") }
            } else {
                Section {
                    TextField("Name", text: $m.name).accessibilityIdentifier("list-name")
                    TextField("Description", text: $m.details, axis: .vertical).lineLimit(2...6).accessibilityIdentifier("list-description")
                }
                Section {
                    Label("Private, only you can see it", systemImage: "lock.fill").accessibilityIdentifier("list-privacy")
                } header: { Text("Privacy") } footer: { Text("Public and friends-only lists aren’t supported yet; only private lists were verified against Letterboxd.") }
                Section {
                    if m.creating { HStack { Text("Creating"); Spacer(); ProgressView() } }
                    if let t = m.noticeText { Text(t).font(.footnote).foregroundStyle(Theme.orange).accessibilityIdentifier("list-notice") }
                }
            }
        }
        .interactiveDismissDisabled(m.creating)
    }
}
