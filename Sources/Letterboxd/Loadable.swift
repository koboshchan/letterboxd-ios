import SwiftUI
import LetterboxdKit

enum Phase<T> { case idle, loading, loaded(T), failed(LetterboxdError) }

/// Paged loader with cancellation, refresh and honest failure state.
@Observable @MainActor
final class PagedLoader<Item: Identifiable & Sendable> where Item.ID: Sendable {
    var items: [Item] = []
    var phase: Phase<Void> = .idle
    var hasNext = false
    private var page = 0
    private var task: Task<Void, Never>?
    private let fetch: @Sendable (Int, Bool) async throws -> Page<Item>
    init(_ fetch: @escaping @Sendable (Int, Bool) async throws -> Page<Item>) { self.fetch = fetch }

    var isLoading: Bool { if case .loading = phase { true } else { false } }
    var error: LetterboxdError? { if case .failed(let e) = phase { e } else { nil } }
    var isEmptyLoaded: Bool { if case .loaded = phase { items.isEmpty } else { false } }

    func loadFirst(refresh: Bool = false) async {
        if !refresh, case .loaded = phase { return }
        task?.cancel()
        phase = .loading
        await run(page: 1, refresh: refresh, replace: true)
    }
    func loadMore(current: Item) async {
        guard hasNext, !isLoading, items.last?.id == current.id else { return }
        phase = .loading
        await run(page: page + 1, refresh: false, replace: false)
    }
    private func run(page p: Int, refresh: Bool, replace: Bool) async {
        do {
            let r = try await fetch(p, refresh)
            var progressed = true
            if replace { items = r.items } else {
                let fresh = r.items.filter { n in !items.contains { $0.id == n.id } }
                progressed = !fresh.isEmpty; items += fresh
            }
            page = p; hasNext = r.hasNext && progressed; phase = .loaded(())
        } catch is CancellationError { phase = replace && items.isEmpty ? .idle : .loaded(())
        } catch let e as LetterboxdError {
            if e == .cancelled { phase = items.isEmpty ? .idle : .loaded(()) } else { phase = .failed(e) }
        } catch { phase = .failed(.network(error.localizedDescription)) }
    }
}

@Observable @MainActor
final class ValueLoader<T: Sendable> {
    var value: T?
    var phase: Phase<Void> = .idle
    private let fetch: @Sendable (Bool) async throws -> T
    init(_ f: @escaping @Sendable (Bool) async throws -> T) { fetch = f }
    var error: LetterboxdError? { if case .failed(let e) = phase { e } else { nil } }
    var isLoading: Bool { if case .loading = phase { true } else { false } }
    func load(refresh: Bool = false) async {
        if !refresh, value != nil { return }
        phase = .loading
        do { value = try await fetch(refresh); phase = .loaded(()) }
        catch is CancellationError { phase = value == nil ? .idle : .loaded(()) }
        catch let e as LetterboxdError { phase = e == .cancelled ? (value == nil ? .idle : .loaded(())) : .failed(e) }
        catch { phase = .failed(.network(error.localizedDescription)) }
    }
}
