import SwiftUI
import LetterboxdKit

/// Native film grid of one public list (GET /<user>/list/<slug>/), paged. No write actions.
struct ListDetailScreen: View {
    @Environment(AppEnvironment.self) private var env
    let list: ListSummary
    @State private var loader: PagedLoader<FilmSummary>?
    var body: some View {
        Group {
            if let l = loader { PosterGrid(loader: l, emptyTitle: "Empty list", emptyBody: "This list has no films.") } else { ProgressView() }
        }
        .navigationTitle(list.title).navigationBarTitleDisplayMode(.inline)
        .task {
            if loader == nil { let s = env.service, u = list.url; loader = PagedLoader { p, r in try await s.listFilms(list: u, page: p, refresh: r) } }
        }
    }
}
