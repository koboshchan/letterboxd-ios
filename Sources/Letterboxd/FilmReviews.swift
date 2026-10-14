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
                    NavigationLink(value: r) { ReviewRow(review: r) }.task { await l.loadMore(current: r) }
                }
                if l.isEmptyLoaded { EmptyCard(symbol: "text.bubble", title: "No reviews yet", text: "Nobody has reviewed this film.").listRowBackground(Color.clear) }
                if let e = l.error { ErrorCard(error: e, retry: { Task { await l.loadFirst(refresh: true) } }).listRowBackground(Color.clear) }
                if l.isLoading { HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear) }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Reviews").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FilmReview.self) { ReviewDetailScreen(review: $0, film: film) }
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

struct ReviewRow: View {
    let review: FilmReview
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(review.author).font(.subheadline.weight(.semibold))
                if let s = review.rating { StarsView(rating: s) }
                Spacer()
                if let d = review.date { Text(d, format: .dateTime.month(.abbreviated).day().year()).font(.caption).foregroundStyle(.secondary) }
            }
            Text(review.text).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
        }.padding(.vertical, 4)
    }
}

/// One review in full. Text is the list excerpt; the full-text endpoint is not integrated, so long reviews link out.
struct ReviewDetailScreen: View {
    let review: FilmReview
    let film: FilmSummary
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(film.title).font(Theme.serif(30, weight: .bold))
                NavigationLink(value: MemberRoute(username: review.username)) { Text("Review by \(review.author)").font(.headline) }
                if let s = review.rating { StarsView(rating: s) }
                Text(review.text).font(.body).lineSpacing(3).textSelection(.enabled)
                if review.fullTextPath != nil { Text("This review may be longer on Letterboxd.").font(.footnote).foregroundStyle(.secondary) }
                Link(destination: review.link) { Label("Open on Letterboxd", systemImage: "safari") }.buttonStyle(.bordered)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationBarTitleDisplayMode(.inline)
    }
}
