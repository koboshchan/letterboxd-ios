import SwiftUI
import LetterboxdKit

struct BrowseScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var kind: BrowseKind = .popular
    @State private var loaders: [BrowseKind: PagedLoader<FilmSummary>] = [:]
    var body: some View {
        VStack(spacing: 0) {
            Picker("List", selection: $kind) { ForEach(BrowseKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).padding(16)
            PosterGrid(loader: loader(kind), emptyTitle: "Nothing here", emptyBody: "Letterboxd returned no films for this list.")
                .id(kind)
        }
        .background(Color.black).navigationTitle("Browse")
    }
    private func loader(_ k: BrowseKind) -> PagedLoader<FilmSummary> {
        if let l = loaders[k] { return l }
        let svc = env.service
        let l = PagedLoader<FilmSummary> { p, r in try await svc.browse(k, page: p, refresh: r) }
        DispatchQueue.main.async { loaders[k] = l }
        return l
    }
}

enum SearchScope: String, CaseIterable { case films = "Films", members = "Members" }

struct SearchScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var submitted = ""
    @State private var scope: SearchScope = .films
    @State private var filmLoader: PagedLoader<FilmSummary>?
    @State private var memberLoader: PagedLoader<MemberSummary>?
    var body: some View {
        Group {
            if submitted.isEmpty {
                EmptyCard(symbol: "magnifyingglass", title: "Search Letterboxd", text: "Find films or members. Search runs only when you press return.")
            } else if scope == .films, let l = filmLoader {
                PosterGrid(loader: l, emptyTitle: "No films found", emptyBody: "Nothing matched \u{201C}\(submitted)\u{201D}.").id(submitted)
            } else if scope == .members, let l = memberLoader {
                MemberList(loader: l, query: submitted).id(submitted)
            }
        }
        .background(Color.black)
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Films or members")
        .searchScopes($scope) { ForEach(SearchScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
        .onSubmit(of: .search) { run() }
        .onChange(of: scope) { _, _ in if !submitted.isEmpty { run() } }
    }
    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return }
        submitted = q
        let svc = env.service
        filmLoader = PagedLoader { p, _ in try await svc.searchFilms(query: q, page: p) }
        memberLoader = PagedLoader { p, _ in try await svc.searchMembers(query: q, page: p) }
    }
}

struct MemberList: View {
    @Environment(AppEnvironment.self) private var env
    let loader: PagedLoader<MemberSummary>
    let query: String
    var body: some View {
        List {
            ForEach(loader.items) { m in
                Button { env.username = m.username } label: {
                    HStack(spacing: 12) { AvatarView(url: m.avatarURL); VStack(alignment: .leading) { Text(m.displayName).font(.headline); Text("@" + m.username).font(.caption).foregroundStyle(.secondary) } }
                }.listRowBackground(Color.black)
            }
            if loader.isEmptyLoaded { EmptyCard(symbol: "person.2", title: "No members found", text: "Nothing matched \u{201C}\(query)\u{201D}.").listRowBackground(Color.clear) }
            if let e = loader.error { ErrorCard(error: e, retry: { Task { await loader.loadFirst(refresh: true) } }, link: URL(string: "https://letterboxd.com/members/")).listRowBackground(Color.clear) }
            if loader.isLoading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
        }.listStyle(.plain).scrollContentBackground(.hidden).task { await loader.loadFirst() }
    }
}
