import SwiftUI
import LetterboxdKit

struct FilmScreen: View {
    @Environment(AppEnvironment.self) private var env
    let summary: FilmSummary
    @State private var loader: ValueLoader<FilmDetail>?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 16) {
                    PosterView(film: summary).frame(width: 130)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title).font(.title.bold())
                        if let y = summary.year { Text(String(y)).foregroundStyle(.secondary) }
                        if let d = loader?.value {
                            if let m = d.runtimeMinutes { Text("\(m) min").font(.subheadline).foregroundStyle(.secondary) }
                            if let a = d.averageRating { Label(String(format: "%.2f", a), systemImage: "star.fill").font(.subheadline).foregroundStyle(Theme.green) }
                        }
                    }
                }
                if let d = loader?.value {
                    if let t = d.tagline { Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1) }
                    if let s = d.synopsis { Text(s).font(.body) }
                    if !d.directors.isEmpty { section("Directed by", d.directors.map(\.name)) }
                    if !d.cast.isEmpty { section("Cast", d.cast.prefix(12).map(\.name)) }
                } else if let e = loader?.error {
                    ErrorCard(error: e, retry: { Task { await loader?.load(refresh: true) } }, link: summary.pageURL)
                } else { ProgressView().frame(maxWidth: .infinity).padding() }
                Link(destination: summary.pageURL) { Label("Reviews and lists on Letterboxd", systemImage: "safari") }.buttonStyle(.bordered)
            }.padding(20)
        }
        .background(Color.black).navigationBarTitleDisplayMode(.inline)
        .task {
            let s = env.service, slug = summary.slug
            if loader == nil { loader = ValueLoader { r in try await s.film(slug: slug, refresh: r) } }
            await loader?.load()
        }
    }
    private func section(_ t: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(names.joined(separator: ", ")).font(.subheadline)
        }
    }
}

struct AboutScreen: View {
    @Environment(AppEnvironment.self) private var env
    var body: some View {
        ScrollViewReader { proxy in List {
            Section("Read-only") { Text("Browsing uses public pages only. You can sign in on letterboxd.com itself (the app never sees your password), but sign-in is not yet verified end to end, and posting, rating, watchlist and list changes are not supported.") }
            Section("Data source") {
                Text("Letterboxd's official API is approval-only and is not being granted for personal projects, so this app does not use it and is not an official client.")
                Text("Diary and reviews come from each member's public RSS feed. Films, watchlist, lists and search use public web pages, fetched only when you open or refresh a screen, cached for five minutes. Challenges or blocks are never bypassed; when Letterboxd declines a request you'll see an error and a link to the website.")
                Text("Letterboxd's terms prohibit automated gathering without authorization. Use this at your own discretion.")
            }
            Section("Mode") { Text(env.isFixtureMode ? "Fixture data (UI test mode)" : "Live public data") }
            Section { Link("letterboxd.com", destination: URL(string: "https://letterboxd.com/")!).id("end") }
        }.contentMargins(.bottom, 96, for: .scrollContent).scrollContentBackground(.hidden).background(Color.black).navigationTitle("About")
        .task { if AppEnvironment.arg("-UIScrollBottom") != nil { try? await Task.sleep(nanoseconds: 800_000_000); proxy.scrollTo("end", anchor: .bottom) } } }
    }
}
