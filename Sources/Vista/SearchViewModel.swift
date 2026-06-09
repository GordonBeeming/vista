// SearchViewModel.swift — Glue between the search TextField and the store.
//
// Owns the query string, runs searches on a debounced timer, holds the
// result set, and tracks selection. The view stays thin — it renders
// whatever the view-model reports.

import Foundation
import Observation
import VistaCore

@Observable
@MainActor
public final class SearchViewModel {
    /// Live contents of the search TextField.
    public var queryText: String = "" {
        didSet { scheduleQuery() }
    }

    /// Results of the most-recent search. Ordered newest-first by
    /// captured_at (ScreenshotStore.search does the ordering).
    public private(set) var results: [ScreenshotRecord] = []

    /// Index into `results` of the highlighted row. Clamped on every
    /// update so the UI can rely on it being valid when results change.
    public var selectedIndex: Int = 0

    /// True while a `loadMore()` page fetch is in flight. Guards against the
    /// grid's trailing-cell `onAppear` firing a second fetch before the
    /// first appends.
    public private(set) var isLoadingMore: Bool = false

    /// False once a page comes back short of `pageSize` — we've reached the
    /// end of the index and further `loadMore()` calls are no-ops.
    public private(set) var canLoadMore: Bool = true

    /// Rows fetched per page. The grid pages in more as the user scrolls
    /// rather than loading the whole index up front.
    private let pageSize = 200

    private let store: ScreenshotStore
    private var debounceTask: Task<Void, Never>?

    /// Bumped on every query. Each in-flight search captures the value at
    /// launch and only applies its results if it's still current — so a
    /// slower earlier search can't land on top of a newer one when several
    /// reloads / keystrokes overlap.
    private var queryGeneration = 0

    public init(store: ScreenshotStore) {
        self.store = store
        reload()
    }

    /// Re-runs the current query against the store. Called on panel show
    /// to catch up on anything the indexer added while the panel was
    /// hidden.
    public func reload() {
        runQuery(queryText)
    }

    /// Wipes the query, scroll, and selection back to a clean "first
    /// open" state. Called by PanelController when the panel has been
    /// hidden longer than the user's reset timeout.
    ///
    /// Setting `queryText` schedules a debounced query, but we cancel
    /// it and run the empty query synchronously instead. Without the
    /// cancel we'd hit `store.search` twice — once now, once again
    /// ~120 ms later — which is noticeable on large indexes.
    public func resetState() {
        queryText = ""
        debounceTask?.cancel()
        debounceTask = nil
        runQuery("")
    }

    public var selectedRecord: ScreenshotRecord? {
        guard results.indices.contains(selectedIndex) else { return nil }
        return results[selectedIndex]
    }

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = max(0, min(results.count - 1, selectedIndex + delta))
    }

    // MARK: - Private

    private func scheduleQuery() {
        debounceTask?.cancel()
        // 120 ms is short enough to feel instant while batching together
        // the rapid keystrokes of fast typists.
        debounceTask = Task { [weak self, text = queryText] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.runQuery(text) }
        }
    }

    private func runQuery(_ text: String) {
        queryGeneration &+= 1
        let generation = queryGeneration
        let query = QueryParser.parse(text)
        Task { [weak self, store, pageSize] in
            do {
                // Run the read off the main actor: `store`'s serial queue is
                // shared with the indexer's writes, so a synchronous search on
                // the main thread can stall the UI behind a write batch — and
                // this now runs on every panel show, not just on keystrokes.
                let page = try await Task.detached(priority: .userInitiated) {
                    try store.search(query, limit: pageSize)
                }.value
                guard let self, generation == self.queryGeneration else { return }
                self.results = page
                self.selectedIndex = 0
                // A full page means there may be more behind it; a short page
                // (or empty) means we've hit the end of the index.
                self.canLoadMore = page.count == pageSize
                self.isLoadingMore = false
            } catch {
                guard let self, generation == self.queryGeneration else { return }
                NSLog("vista: search failed: \(error)")
                self.results = []
                self.canLoadMore = false
                self.isLoadingMore = false
            }
        }
    }

    /// Appends the next page of results below the last row currently shown.
    /// Driven by the grid's trailing-cell `onAppear` for infinite scroll.
    /// Selection is left untouched so paging in older rows never yanks the
    /// highlight away from where the user is.
    ///
    /// The query runs off the main actor: `store`'s serial queue is shared
    /// with the background indexer's upserts, so a synchronous `search` here
    /// could block the main thread behind a write batch — visible as scroll
    /// jank exactly when paging fires. We hop to a detached task for the read
    /// and only touch `results` back on the main actor.
    public func loadMore() {
        guard canLoadMore, !isLoadingMore, let last = results.last else { return }
        isLoadingMore = true
        let query = QueryParser.parse(queryText)
        let cursor = ScreenshotStore.Cursor(capturedAt: last.capturedAt.timeIntervalSince1970, id: last.id)
        Task { [store, pageSize] in
            defer { isLoadingMore = false }
            do {
                let page = try await Task.detached(priority: .userInitiated) {
                    try store.search(query, limit: pageSize, after: cursor)
                }.value
                // The await above is a suspension point: a fresh query or
                // reload may have replaced `results` while we were reading.
                // If the tail moved, this page is stale — drop it rather than
                // appending rows that no longer follow what's on screen.
                guard last.id == results.last?.id else { return }
                results.append(contentsOf: page)
                canLoadMore = page.count == pageSize
            } catch {
                NSLog("vista: loadMore failed: \(error)")
                canLoadMore = false
            }
        }
    }
}
