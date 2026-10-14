import SwiftUI
import UIKit
import LetterboxdKit

/// Shared image path for posters, backdrops and people photos. Decoded images live in NSCache (read synchronously so a
/// revisit paints on the first frame, no placeholder flash); bytes live in the bounded public ImageStore on disk.
/// Public CDN images only: no credentials ever pass through here.
@MainActor
final class ImagePipeline {
    static let shared = ImagePipeline()
    let store: ImageStore
    private let decoded = NSCache<NSURL, UIImage>()
    /// Test/diagnostic counters (deterministic, shown by the debug overlay in UI-test host).
    private(set) var decodedHits = 0, loads = 0
    private var prefetchTasks: [URL: Task<Void, Never>] = [:]
    private var visible: [URL: Int] = [:]
    private let prefetchCap = 12

    init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("LetterboxdImages", isDirectory: true)
        store = ImageStore(directory: dir)
        decoded.countLimit = 150; decoded.totalCostLimit = 48 << 20
    }

    func cachedImage(_ u: URL?) -> UIImage? {
        guard let u, let i = decoded.object(forKey: u as NSURL) else { return nil }
        decodedHits += 1; return i
    }
    func image(_ u: URL) async -> UIImage? {
        if let i = cachedImage(u) { return i }
        guard let d = try? await store.data(for: u), !Task.isCancelled else { return nil }
        loads += 1
        guard let img = UIImage(data: d) else { return nil }
        let cost = Int(img.size.width * img.size.height * img.scale * img.scale * 4)
        decoded.setObject(img, forKey: u as NSURL, cost: cost)
        return img
    }

    // MARK: visible-consumer tracking + bounded prefetch
    func didShow(_ u: URL) { visible[u, default: 0] += 1 }
    func didHide(_ u: URL) { if let n = visible[u] { n <= 1 ? (visible[u] = nil) : (visible[u] = n - 1) } }

    /// Prefetch only the given nearby URLs (caller passes a small window). Obsolete prefetches are cancelled unless an
    /// on-screen view is consuming that URL; the in-flight store request is shared, so cancelling a prefetch cannot starve a viewer.
    func prefetch(_ urls: [URL]) {
        let want = Array(urls.prefix(prefetchCap))
        let wantSet = Set(want)
        for (u, t) in prefetchTasks where !wantSet.contains(u) && visible[u] == nil { t.cancel(); prefetchTasks[u] = nil }
        for u in want where prefetchTasks[u] == nil && cachedImage(u) == nil {
            prefetchTasks[u] = Task { [weak self] in
                _ = await self?.image(u)
                self?.prefetchTasks[u] = nil
            }
        }
    }
    /// Purges decoded + disk images and cancels prefetches; the store fences in-flight fetches so nothing is written back.
    func clearAll() async {
        for t in prefetchTasks.values { t.cancel() }; prefetchTasks = [:]
        decoded.removeAllObjects()
        await store.clear()
    }
    var prefetchInFlight: Int { prefetchTasks.count }
}

/// Replacement for AsyncImage. Synchronous decoded-cache hit on first render; stable identity per URL.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url; self.placeholder = placeholder
        _image = State(initialValue: MainActor.assumeIsolated { ImagePipeline.shared.cachedImage(url) })
    }
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() } else { placeholder() }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            ImagePipeline.shared.didShow(url)
            if let hit = ImagePipeline.shared.cachedImage(url) { image = hit }
            else if let img = await ImagePipeline.shared.image(url) { image = img }   // keeps prior image until the new one is ready
            // visible stays registered until the view goes away
        }
        .onDisappear { if let url { ImagePipeline.shared.didHide(url) } }
    }
}
