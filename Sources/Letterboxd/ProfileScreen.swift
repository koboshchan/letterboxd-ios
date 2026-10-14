import SwiftUI
import LetterboxdKit

enum ProfileTab: String, CaseIterable, Identifiable { case films = "Films", diary = "Diary", reviews = "Reviews", watchlist = "Watchlist", lists = "Lists"
    var id: String { rawValue } }

struct ProfileScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var tab: ProfileTab = ProfileTab.allCases[Int(AppEnvironment.arg("-UISegment") ?? "0") ?? 0]
    @State private var profile: ValueLoader<Profile>?
    @State private var films: PagedLoader<FilmSummary>?
    @State private var watch: PagedLoader<FilmSummary>?
    @State private var diary: ValueLoader<[ActivityEntry]>?
    @State private var reviews: ValueLoader<[ActivityEntry]>?
    @State private var lists: PagedLoader<ListSummary>?

    var body: some View {
        let u = env.username
        VStack(spacing: 0) {
            header
            Picker("Section", selection: $tab) { ForEach(ProfileTab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 8)
            content
        }
        .navigationTitle(u).navigationBarTitleDisplayMode(.inline)
        .onAppear { if profile == nil { reset() } }
        .onChange(of: env.username) { _, _ in reset() }
        .navigationDestination(for: ActivityEntry.self) { EntryScreen(entry: $0) }
        .id(u)
    }

    private func reset() {
        let svc = env.service, u = env.username
        profile = ValueLoader { r in try await svc.profile(username: u, refresh: r) }
        films = PagedLoader { p, r in try await svc.films(username: u, page: p, refresh: r) }
        watch = PagedLoader { p, r in try await svc.watchlist(username: u, page: p, refresh: r) }
        diary = ValueLoader { r in try await svc.diary(username: u, refresh: r) }
        reviews = ValueLoader { r in try await svc.reviews(username: u, refresh: r) }
        lists = PagedLoader { p, r in try await svc.lists(username: u, page: p, refresh: r) }
    }

    @ViewBuilder private var header: some View {
        if let p = profile {
            HStack(spacing: 14) {
                AvatarView(url: p.value?.avatarURL, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.value?.displayName ?? env.username).font(Theme.serif(26, weight: .bold))
                    if let v = p.value {
                        HStack(spacing: 14) {
                            stat(v.filmCount, "Films"); stat(v.followingCount, "Following"); stat(v.followersCount, "Followers")
                        }
                    } else if let e = p.error { Text(e.localizedDescription).font(.caption).foregroundStyle(Theme.orange).lineLimit(2) }
                    else { Text("Loading").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .task { await p.load() }
        }
    }
    private func stat(_ n: Int?, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(n.map(String.init) ?? "-").font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(l.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .films: if let l = films { PosterGrid(loader: l, emptyTitle: "No films yet", emptyBody: "\(env.username) hasn't logged any films.") }
        case .watchlist: if let l = watch { PosterGrid(loader: l, emptyTitle: "Watchlist is empty", emptyBody: "Nothing on \(env.username)'s watchlist yet.") }
        case .diary: if let l = diary { EntryList(loader: l, emptyTitle: "Diary is empty", emptyBody: "No diary entries in the public feed. Letterboxd's RSS shows only recent entries.") }
        case .reviews: if let l = reviews { EntryList(loader: l, emptyTitle: "No reviews", emptyBody: "No written reviews in the public feed yet.") }
        case .lists: if let l = lists { ListsView(loader: l) }
        }
    }
}

struct EntryList: View {
    let loader: ValueLoader<[ActivityEntry]>
    let emptyTitle: String, emptyBody: String
    var body: some View {
        List {
            if let items = loader.value {
                if items.isEmpty { EmptyCard(symbol: "book.closed", title: emptyTitle, text: emptyBody).listRowBackground(Color.clear) }
                ForEach(items) { e in
                    NavigationLink(value: e) { EntryRow(entry: e) }
                }
            }
            if let e = loader.error { ErrorCard(error: e, retry: { Task { await loader.load(refresh: true) } }).listRowBackground(Color.clear).listRowSeparator(.hidden) }
            if loader.isLoading && loader.value == nil { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
        }
        .listStyle(.plain)
        .refreshable { await loader.load(refresh: true) }
        .task { await loader.load() }
    }
}

struct EntryRow: View {
    let entry: ActivityEntry
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Theme.card.frame(width: 52, height: 78)
                .overlay { AsyncImage(url: entry.posterURL) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline)).shadow(color: .black.opacity(0.18), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.filmTitle).font(Theme.serif(17)).lineLimit(2)
                    if let y = entry.filmYear { Text(String(y)).font(.subheadline).foregroundStyle(.secondary) }
                }
                HStack(spacing: 8) {
                    if let r = entry.rating { StarsView(rating: r) }
                    if entry.rewatch { Image(systemName: "arrow.2.squarepath").font(.caption).foregroundStyle(.secondary).accessibilityLabel("Rewatch") }
                    if let d = entry.watchedDate { Text(d, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(.secondary) }
                }
                if let rv = entry.review { Text(rv).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            }
        }.padding(.vertical, 4)
    }
}

struct EntryScreen: View {
    let entry: ActivityEntry
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(entry.filmTitle).font(Theme.serif(34, weight: .bold))
                if let r = entry.rating { StarsView(rating: r) }
                if let rv = entry.review { Text(rv).font(.body) } else { Text("No written review.").foregroundStyle(.secondary) }
                Link(destination: entry.link) { Label("Open on Letterboxd", systemImage: "safari") }.buttonStyle(.bordered)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationBarTitleDisplayMode(.inline)
    }
}

struct ListsView: View {
    let loader: PagedLoader<ListSummary>
    var body: some View {
        List {
            ForEach(loader.items) { l in
                Link(destination: l.url) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(l.title).font(Theme.serif(17))
                        if let c = l.filmCount { Text("\(c) films").font(.caption).foregroundStyle(Theme.green) }
                        if let b = l.blurb { Text(b).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                    }
                }.task { await loader.loadMore(current: l) }
            }
            if loader.isEmptyLoaded { EmptyCard(symbol: "list.bullet.rectangle", title: "No public lists", text: "This member hasn't published any lists.").listRowBackground(Color.clear) }
            if let e = loader.error { ErrorCard(error: e, retry: { Task { await loader.loadFirst(refresh: true) } }).listRowBackground(Color.clear) }
            if loader.isLoading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
        }
        .listStyle(.plain)
        .refreshable { await loader.loadFirst(refresh: true) }
        .task { await loader.loadFirst() }
    }
}
