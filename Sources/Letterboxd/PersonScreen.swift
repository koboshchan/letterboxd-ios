import SwiftUI
import LetterboxdKit

/// Tappable cast/crew chips. Each one is a parsed, validated Letterboxd person link.
struct CreditSection: View {
    let title: String
    let credits: [Credit]
    var body: some View {
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
                FlowLayout(spacing: 8) {
                    ForEach(credits) { c in
                        NavigationLink(value: c) {
                            Text(c.name).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                                .background(.thinMaterial, in: Capsule())
                        }.buttonStyle(.plain).accessibilityLabel("\(c.name), \(c.role.rawValue)")
                    }
                }
            }
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > w { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing; row = max(row, s.height)
        }
        return CGSize(width: w, height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > b.maxX { x = b.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

/// Read-only filmography for a cast or crew member. Never touches the signed-in identity.
struct PersonScreen: View {
    @Environment(AppEnvironment.self) private var env
    let credit: Credit
    @State private var loader: PagedLoader<FilmSummary>?
    @State private var portrait: URL?
    var body: some View {
        Group {
            if let loader {
                VStack(spacing: 0) {
                    if let portrait {
                        AsyncImage(url: portrait) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                            .frame(width: 96, height: 128).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .padding(.top, 8).accessibilityLabel(credit.name)
                    }
                PosterGrid(loader: loader, emptyTitle: "No films", emptyBody: "Letterboxd lists no films for \(credit.name).")
                }
            } else { ProgressView() }
        }
        .navigationTitle(credit.name).navigationBarTitleDisplayMode(.inline)
        .task {
            guard loader == nil else { return }
            let s = env.service, r = credit.role, slug = credit.slug
            Task { portrait = await s.personPortrait(role: r, slug: slug) }
            loader = PagedLoader { p, refresh in try await s.personFilms(role: r, slug: slug, page: p, refresh: refresh) }
        }
    }
}
