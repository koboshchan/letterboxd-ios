import SwiftUI
import LetterboxdKit

struct BrowseScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var kind: BrowseKind = .popular
    @State private var store = BrowseStore()
    var body: some View {
        VStack(spacing: 0) {
            Picker("List", selection: $kind) { ForEach(BrowseKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).padding(16)
            PosterGrid(loader: loader(kind), emptyTitle: "Nothing here", emptyBody: "Letterboxd returned no films for this list.")
                .id(kind)
        }
        .navigationTitle("Browse")
    }
    private func loader(_ k: BrowseKind) -> PagedLoader<FilmSummary> { store.loader(k, service: env.service) }
}

@MainActor final class BrowseStore {
    private var loaders: [BrowseKind: PagedLoader<FilmSummary>] = [:]
    func loader(_ k: BrowseKind, service svc: LetterboxdService) -> PagedLoader<FilmSummary> {
        if let l = loaders[k] { return l }
        let l = PagedLoader<FilmSummary> { p, r in try await svc.browse(k, page: p, refresh: r) }
        loaders[k] = l; return l
    }
}

struct SearchScreen: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query = ""
    @State private var submitted = ""
    @State private var filmLoader: PagedLoader<FilmSummary>?
    var body: some View {
        Group {
            if submitted.isEmpty {
                EmptyCard(symbol: "magnifyingglass", title: "Search Letterboxd", text: "Find films. Search runs only when you press return.")
            } else if let l = filmLoader {
                PosterGrid(loader: l, emptyTitle: "No films found", emptyBody: "Nothing matched \u{201C}\(submitted)\u{201D}.").id(submitted)
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, prompt: "Films")
        .onSubmit(of: .search) { run() }
        .navigationDestination(for: NetworkRoute.self) { MemberListScreen(route: $0) }
    }
    private func run() {
        let q = query.trimmingCharacters(in: .whitespaces); guard !q.isEmpty else { return }
        submitted = q
        let svc = env.service
        filmLoader = PagedLoader { p, _ in try await svc.searchFilms(query: q, page: p) }
    }
}
