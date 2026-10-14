import SwiftUI
import LetterboxdKit

/// Read-only reviews of a film (GET /film/<slug>/reviews/). Native; no write actions.
struct FilmReviewsScreen: View {
    @Environment(AppEnvironment.self) private var env
    let film: FilmSummary
    @State private var loader: PagedLoader<FilmReview>?
    var body: some View {
        List {
            if let l = loader {
                ForEach(l.items) { r in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            NavigationLink(value: MemberRoute(username: r.username)) { Text(r.author).font(.subheadline.weight(.semibold)) }.buttonStyle(.plain)
                            if let s = r.rating { Label(String(format: "%.1f", s), systemImage: "star.fill").font(.caption).foregroundStyle(Theme.green) }
                            Spacer()
                            if let d = r.date { Text(d, style: .date).font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(r.text).font(.body).lineLimit(12)
                        Link(destination: r.link) { Label("Open on Letterboxd", systemImage: "safari").font(.caption) }
                    }.padding(.vertical, 4).task { await l.loadMore(current: r) }
                }
                if l.isEmptyLoaded { EmptyCard(symbol: "text.bubble", title: "No reviews yet", text: "Nobody has reviewed this film.").listRowBackground(Color.clear) }
                if let e = l.error { ErrorCard(error: e, retry: { Task { await l.loadFirst(refresh: true) } }).listRowBackground(Color.clear) }
                if l.isLoading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Reviews").navigationBarTitleDisplayMode(.inline)
        .refreshable { await loader?.loadFirst(refresh: true) }
        .task {
            if loader == nil { let s = env.service, slug = film.slug; loader = PagedLoader { p, r in try await s.filmReviews(slug: slug, page: p, refresh: r) } }
            await loader?.loadFirst()
        }
    }
}

/// Lists that contain a film (GET /film/<slug>/lists/), reusing ListsView.
struct FilmListsScreen: View {
    @Environment(AppEnvironment.self) private var env
    let film: FilmSummary
    @State private var loader: PagedLoader<ListSummary>?
    var body: some View {
        Group { if let l = loader { ListsView(loader: l) } else { ProgressView() } }
            .navigationTitle("Lists").navigationBarTitleDisplayMode(.inline)
            .task { if loader == nil { let s = env.service, slug = film.slug; loader = PagedLoader { p, r in try await s.filmLists(slug: slug, page: p, refresh: r) } } }
    }
}
