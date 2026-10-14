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
                Color.clear.frame(height: 190)   // room for the backdrop; the hero is its background, inside the scroll content so it scrolls away with it
                    .background(alignment: .top) {
                        BackdropHero(url: loader?.value?.backdropURL, loading: loader?.value == nil && loader?.error == nil)
                    }
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
                FilmActionBar(model: env.actionModel(slug: summary.slug))
                if let d = loader?.value {
                    if let t = d.tagline { Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1) }
                    if let s = d.synopsis { ExpandableText(text: s, lines: 5).id(summary.slug + s) }
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
                NavigationLink { FilmReviewsScreen(film: summary).hidesBottomNav() } label: { Label("Reviews", systemImage: "text.bubble") }.buttonStyle(.bordered)
                NavigationLink { FilmListsScreen(film: summary).hidesBottomNav() } label: { Label("Lists featuring this film", systemImage: "list.bullet.rectangle") }.buttonStyle(.bordered)
            }.padding(20)
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarBackButtonHidden(true)
        .hidesBottomNav()
        .enableInteractivePop()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Single native toolbar glass surface; no custom background stacked on it.
                Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: summary.pageURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { UIPasteboard.general.url = summary.pageURL } label: { Label("Copy link", systemImage: "link") }
                    Link(destination: summary.pageURL) { Label("Open on Letterboxd", systemImage: "safari") }
                } label: { Image(systemName: "ellipsis") }
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
                    CachedImage(url: url) { Color.clear }
                } else if loading { ProgressView() }
            }
            .clipped()
            .overlay(alignment: .top) { LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom).frame(height: 110) }
            .overlay(alignment: .bottom) { LinearGradient(colors: [.clear, Color(.systemBackground)], startPoint: .top, endPoint: .bottom).frame(height: 160) }
            .accessibilityHidden(AppEnvironment.arg("-UIExposeBackdrop") == nil)
            .accessibilityIdentifier("film-backdrop")
    }
}


/// Hiding the system back button disables UIKit's edge-swipe pop; re-enable it only while this screen is visible,
/// and put the previous delegate/enabled state back when it goes away.
private struct InteractivePopEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ vc: Probe, context: Context) {}
    final class Probe: UIViewController, UIGestureRecognizerDelegate {
        private weak var gesture: UIGestureRecognizer?
        private weak var prevDelegate: UIGestureRecognizerDelegate?
        private var prevEnabled = true
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard gesture == nil, let g = navigationController?.interactivePopGestureRecognizer else { return }
            gesture = g; prevDelegate = g.delegate; prevEnabled = g.isEnabled
            g.isEnabled = true; g.delegate = self
        }
        override func viewWillDisappear(_ animated: Bool) { super.viewWillDisappear(animated); restore() }
        deinit { MainActor.assumeIsolated { restore() } }
        private func restore() {
            guard let g = gesture else { return }
            g.delegate = prevDelegate; g.isEnabled = prevEnabled; gesture = nil
        }
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { (navigationController?.viewControllers.count ?? 0) > 1 }
    }
}
extension View {
    func enableInteractivePop() -> some View { background(InteractivePopEnabler().frame(width: 0, height: 0)) }
}

/// Collapses to `lines` lines; shows "more" only when the text really overflows at the current width and Dynamic Type size.
struct ExpandableText: View {
    let text: String
    let lines: Int
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var limitedHeight: CGFloat = 0
    private var overflows: Bool { fullHeight > limitedHeight + 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(.body).lineSpacing(3)
                .lineLimit(expanded ? nil : lines)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { limitedHeight = $0 }
                .background {
                    // Unconstrained twin used only to measure; hidden from accessibility and layout.
                    Text(text).font(.body).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .hidden().accessibilityHidden(true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
                .accessibilityIdentifier("synopsis-text")
            if overflows {
                Button(expanded ? "less" : "more") { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                    .font(.body.weight(.semibold)).foregroundStyle(Theme.green)
                    .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
                    .accessibilityLabel(expanded ? "Show less of the synopsis" : "Show full synopsis")
                    .accessibilityIdentifier("synopsis-more")
            }
        }
    }
}
