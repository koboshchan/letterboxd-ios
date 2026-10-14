import SwiftUI
import LetterboxdKit

struct FilmScreen: View {
    @Environment(AppEnvironment.self) private var env
    let summary: FilmSummary
    @State private var loader: ValueLoader<FilmDetail>?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                BackdropHero(url: loader?.value?.backdropURL, loading: loader?.value == nil && loader?.error == nil)
                    .padding(.horizontal, -20).padding(.top, -20)
                HStack(alignment: .bottom, spacing: 16) {
                    PosterView(film: summary).frame(width: 130)
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary.title).font(Theme.serif(28, weight: .bold))
                        if let y = summary.year { Text(String(y)).foregroundStyle(.secondary) }
                        if let d = loader?.value {
                            if let m = d.runtimeMinutes { Text("\(m) min").font(.subheadline).foregroundStyle(.secondary) }
                            if let a = d.averageRating { Label(String(format: "%.2f", a), systemImage: "star.fill").font(.subheadline).foregroundStyle(Theme.green) }
                        }
                    }
                }
                .padding(.top, -96).zIndex(1)   // poster rises over the hero's lower edge
                if let d = loader?.value {
                    if let t = d.tagline { Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1) }
                    if let s = d.synopsis { Text(s).font(.body).lineSpacing(3) }
                    if d.credits.isEmpty {
                        if !d.directors.isEmpty { section("Directed by", d.directors.map(\.name)) }
                        if !d.cast.isEmpty { section("Cast", d.cast.prefix(12).map(\.name)) }
                    } else {
                        CreditSection(title: "Directed by", credits: d.credits.filter { $0.role == .director })
                        CreditSection(title: "Cast", credits: Array(d.credits.filter { $0.role == .actor }.prefix(24)))
                        CreditSection(title: "Crew", credits: d.credits.filter { $0.role != .director && $0.role != .actor })
                    }
                } else if let e = loader?.error {
                    ErrorCard(error: e, retry: { Task { await loader?.load(refresh: true) } }, link: summary.pageURL)
                } else { ProgressView().frame(maxWidth: .infinity).padding() }
                FilmActionBar(model: FilmActionsModel(client: env.actions, auth: env.auth, slug: summary.slug))
                UnverifiedWriteRows(features: [.logDiary, .rate, .review, .addToList])
                NavigationLink { FilmReviewsScreen(film: summary) } label: { Label("Reviews", systemImage: "text.bubble") }.buttonStyle(.bordered)
                NavigationLink { FilmListsScreen(film: summary) } label: { Label("Lists featuring this film", systemImage: "list.bullet.rectangle") }.buttonStyle(.bordered)
            }.padding(20)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { FloatingCircle(symbol: "chevron.left", label: "Back") { dismiss() } }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: summary.pageURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.url = summary.pageURL } label: { Label("Copy link", systemImage: "link") }
                    Link(destination: summary.pageURL) { Label("Open on Letterboxd", systemImage: "safari") }
                } label: { FloatingCircleLabel(symbol: "ellipsis") }
                .accessibilityLabel("More")
            }
        }
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            let s = env.service, slug = summary.slug
            if loader == nil { loader = ValueLoader { r in try await s.film(slug: slug, refresh: r) } }
            await loader?.load()
        }
    }
    private func section(_ t: String, _ names: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t).font(Theme.serif(20))
            Text(names.joined(separator: ", ")).font(.subheadline)
        }
    }
}

/// Wide backdrop that fades into the screen background. Missing/loading art keeps the same height with a neutral wash.
struct BackdropHero: View {
    let url: URL?
    let loading: Bool
    var body: some View {
        Color(.secondarySystemBackground)
            .frame(height: 300)
            .overlay {
                if let url {
                    AsyncImage(url: url) { ph in
                        if let i = ph.image { i.resizable().scaledToFill() } else { Color.clear }
                    }
                } else if loading { ProgressView() }
            }
            .clipped()
            .overlay(alignment: .top) { LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110) }
            .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom).frame(height: 160) }
            .accessibilityHidden(true)
    }
}

struct FloatingCircleLabel: View {
    let symbol: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle()).contentShape(Circle())
    }
}
struct FloatingCircle: View {
    let symbol: String, label: String, action: () -> Void
    var body: some View { Button(action: action) { FloatingCircleLabel(symbol: symbol) }.accessibilityLabel(label) }
}
