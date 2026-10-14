import SwiftUI
import LetterboxdKit

enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? { switch self { case .system: nil; case .light: .light; case .dark: .dark } }
    static let key = "appearance"
    /// Unknown or missing stored values fall back to following the system.
    static func resolve(_ raw: String?) -> AppearanceChoice { raw.flatMap(AppearanceChoice.init(rawValue:)) ?? .system }
}

/// Appearance and cache only. Nothing here touches the Letterboxd account.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var env
    @AppStorage(AppearanceChoice.key) private var raw = AppearanceChoice.system.rawValue
    @State private var clearing = false
    @State private var cleared = false
    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: Binding(get: { AppearanceChoice.resolve(raw) }, set: { raw = $0.rawValue })) {
                    ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("appearance-picker")
            }
            Section {
                Button {
                    Task { clearing = true; cleared = false; await env.clearCaches(); clearing = false; cleared = true }
                } label: { HStack { Text("Clear Cache"); Spacer(); if clearing { ProgressView() } } }
                    .disabled(clearing).accessibilityIdentifier("clear-cache")
                if cleared { Label("Cache cleared", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.green).accessibilityIdentifier("cache-cleared") }
            } header: { Text("Storage") } footer: { Text("Removes saved posters, photos and page data from this device. Your account and sign-in are not affected.") }
        }
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
    }
}

struct SettingsRoute: Hashable {}
