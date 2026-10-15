import SwiftUI
import LetterboxdKit

/// Tappable cast/crew chips. Each one is a parsed, validated Letterboxd person link.
/// Shelf-style person tiles: 76pt circular photo, 2-line centered name (80pt wide), role/character caption, horizontal scroll.
struct CreditSection: View {
    let title: String
    let credits: [Credit]
    var body: some View {
        if !credits.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).tracking(1)
                ScrollView(.horizontal, showsIndicators: false) {
                    // Lazy: portraits are fetched only for tiles that scroll on screen.
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(credits) { c in
                            NavigationLink(value: c) { CreditTile(credit: c) }.buttonStyle(.plain)
                                .accessibilityLabel("\(c.name), \(c.role.rawValue)").accessibilityIdentifier("credit-\(c.role.rawValue)-\(c.slug)")
                        }
                    }
                }
            }
        }
    }
}

/// Caps simultaneous person-page reads so a long cast list can't fan out.
actor PortraitLimiter {
    static let shared = PortraitLimiter()
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async { if running < 3 { running += 1 } else { await withCheckedContinuation { waiters.append($0) } } }
    func release() { if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() } }
}

struct CreditTile: View {
    @Environment(AppEnvironment.self) private var env
    let credit: Credit
    @State private var portrait: URL?
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Color.secondary.opacity(0.18)
                if let portrait {
                    CachedImage(url: portrait) { Color.clear }
                } else {
                    Image(systemName: "person.fill").font(.title3).foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .frame(width: 76, height: 76).clipShape(Circle())
            Text(credit.name).font(.caption).lineLimit(2, reservesSpace: true).multilineTextAlignment(.center).frame(width: 80)
            Text(credit.role.rawValue.capitalized).font(.caption2).foregroundStyle(.secondary).lineLimit(1).frame(width: 80)
        }
        .task(id: credit.id) {
            guard portrait == nil else { return }
            await PortraitLimiter.shared.acquire()
            let u = await env.service.personPortrait(role: credit.role, slug: credit.slug)
            await PortraitLimiter.shared.release()
            portrait = u
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

/// Shelf-style read-only person detail with a single, continuous filmography scroll.
struct PersonScreen: View {
    @Environment(AppEnvironment.self) private var env
    let credit: Credit
    @State private var loader: PagedLoader<FilmSummary>?
    @State private var details: PersonDetails?
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 16) {
                    CachedImage(url: details?.portraitURL) {
                        ZStack { Theme.card; Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary) }
                    }
                    .frame(width: 112, height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityLabel(credit.name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(credit.name).font(Theme.serif(26)).lineLimit(3)
                        Text(credit.role.rawValue.capitalized).font(.subheadline).foregroundStyle(.secondary)
                        if let count = details?.filmCount {
                            Text("\(count) films").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                if let roles = details?.roles, !roles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(roles, id: \.self) { role in
                                Text(role).font(.footnote).padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Theme.green.opacity(0.12), in: Capsule())
                            }
                        }
                    }
                }
                if let bio = details?.biography, !bio.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("About").font(Theme.serif(22))
                        PersonBiography(text: bio)
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Films").font(Theme.serif(22)).accessibilityAddTraits(.isHeader)
                    if let loader {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(loader.items) { film in
                                NavigationLink(value: film) { PosterView(film: film) }
                                    .buttonStyle(.plain).filmContextMenu(film)
                                    .task { await loader.loadMore(current: film) }
                            }
                        }
                        if loader.isLoading { ProgressView().frame(maxWidth: .infinity).padding() }
                        if let error = loader.error {
                            ErrorCard(error: error, retry: { Task { await loader.loadFirst(refresh: true) } })
                        }
                        if loader.isEmptyLoaded {
                            EmptyCard(symbol: "film", title: "No films", text: "Letterboxd lists no films for \(credit.name).")
                        }
                    }
                }
            }.padding(20)
        }
        .navigationTitle(credit.name).navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: FilmSummary.self) { FilmScreen(summary: $0) }
        .refreshable { await loader?.loadFirst(refresh: true) }
        .task(id: credit.id) {
            guard loader == nil else { return }
            let service = env.service, role = credit.role, slug = credit.slug
            let films = PagedLoader { p, refresh in try await service.personFilms(role: role, slug: slug, page: p, refresh: refresh) }
            loader = films
            async let info = service.personDetails(role: role, slug: slug)
            await films.loadFirst()
            details = await info
        }
    }
}

/// Measures both layouts at the actual Dynamic Type size; More is never shown for short biographies.
struct PersonBiography: View {
    let text: String
    @State private var expanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var collapsedHeight: CGFloat = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 5)
                .background {
                    Text(text).font(.subheadline).lineLimit(5)
                        .background(GeometryReader { proxy in Color.clear.onAppear { collapsedHeight = proxy.size.height }.onChange(of: proxy.size.height) { _, h in collapsedHeight = h } })
                        .hidden()
                }
                .overlay(alignment: .topLeading) {
                    Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { proxy in Color.clear.onAppear { fullHeight = proxy.size.height }.onChange(of: proxy.size.height) { _, h in fullHeight = h } })
                        .hidden().allowsHitTesting(false)
                }
            if fullHeight > collapsedHeight + 1 {
                Button(expanded ? "Less" : "More") { withAnimation { expanded.toggle() } }
                    .font(.subheadline.weight(.medium)).tint(Theme.green)
            }
        }
    }
}
