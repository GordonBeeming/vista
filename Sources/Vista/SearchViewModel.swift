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

    private let store: ScreenshotStore
    private var debounceTask: Task<Void, Never>?

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
        do {
            let query = QueryParser.parse(text)
            self.results = try store.search(query, limit: 400)
            self.selectedIndex = 0
        } catch {
            NSLog("vista: search failed: \(error)")
            self.results = []
        }
    }
}
