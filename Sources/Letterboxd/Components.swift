import SwiftUI
import LetterboxdKit

/// Limits poster lookups so a grid never fans out into a burst of requests.
actor PosterGate {
    static let shared = PosterGate()
    private var cache: [String: URL?] = [:]
    private var active = 0
    func url(for slug: String, using s: LetterboxdService) async -> URL? {
        if let c = cache[slug] { return c }
        while active >= 2 { try? await Task.sleep(nanoseconds: 150_000_000); if Task.isCancelled { return nil } }
        if let c = cache[slug] { return c }
        active += 1; defer { active -= 1 }
        let u = await s.poster(for: slug)
        if !Task.isCancelled { cache[slug] = .some(u) }
        return u
    }
}

struct PosterView: View {
    @Environment(AppEnvironment.self) private var env
    let film: FilmSummary
    @State private var resolved: URL?
    private var titleCard: some View {
        VStack(spacing: 4) {
            Text(film.title).font(.caption.weight(.semibold)).multilineTextAlignment(.center).lineLimit(4)
            if let y = film.year { Text(String(y)).font(.caption2).foregroundStyle(.secondary) }
        }.padding(8)
    }
    var body: some View {
        Theme.card
            .aspectRatio(2.0/3.0, contentMode: .fit)
            .overlay {
                if let u = film.posterURL ?? resolved {
                    AsyncImage(url: u) { phase in
                        if let img = phase.image { img.resizable().scaledToFill() } else { titleCard }
                    }
                } else {
                    titleCard
                }
            }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
        .accessibilityLabel(film.title)
        .task(id: film.slug) {
            guard film.posterURL == nil, !env.isFixtureMode else { return }
            resolved = await PosterGate.shared.url(for: film.slug, using: env.service)
        }
    }
}

struct PosterGrid: View {
    let loader: PagedLoader<FilmSummary>
    let emptyTitle: String
    let emptyBody: String
    private let cols = [GridItem(.adaptive(minimum: 104), spacing: 10)]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 12) {
                ForEach(loader.items) { f in
                    NavigationLink(value: f) { PosterView(film: f) }.buttonStyle(.plain)
                        .task { await loader.loadMore(current: f) }
                }
            }.padding(.horizontal, 16)
            if loader.isLoading { ProgressView().padding(24) }
            if let e = loader.error { ErrorCard(error: e, retry: { Task { await loader.loadFirst(refresh: true) } }).padding() }
            if loader.isEmptyLoaded { EmptyCard(symbol: "film", title: emptyTitle, text: emptyBody).padding() }
        }
        .contentMargins(.bottom, 24, for: .scrollContent).defaultScrollAnchor(AppEnvironment.arg("-UIScrollBottom") != nil ? .bottom : .top)
        .refreshable { await loader.loadFirst(refresh: true) }
        .task { await loader.loadFirst() }
        .navigationDestination(for: FilmSummary.self) { FilmScreen(summary: $0) }
        .background(Color.black)
    }
}

struct EmptyCard: View {
    let symbol: String, title: String, text: String
    var body: some View {
        ContentUnavailableView { Label(title, systemImage: symbol) } description: { Text(text) }
    }
}

struct ErrorCard: View {
    let error: LetterboxdError
    let retry: () -> Void
    var link: URL? = nil
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(Theme.orange)
            Text(error.localizedDescription).font(.subheadline).multilineTextAlignment(.center)
            HStack {
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
                Link("Open Letterboxd", destination: link ?? URL(string: "https://letterboxd.com/")!).buttonStyle(.bordered)
            }
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct StarsView: View {
    let rating: Double
    var body: some View {
        let full = Int(rating); let half = rating - Double(full) >= 0.5
        HStack(spacing: 1) {
            ForEach(0..<full, id: \.self) { _ in Image(systemName: "star.fill") }
            if half { Image(systemName: "star.leadinghalf.filled") }
        }.font(.caption).foregroundStyle(Theme.green).accessibilityLabel("\(rating) stars")
    }
}

struct AvatarView: View {
    let url: URL?; var size: CGFloat = 44
    var body: some View {
        AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Image(systemName: "person.fill").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.card) }
            .frame(width: size, height: size).clipShape(Circle())
    }
}
