// AppState.swift — Top-level observable state for the app.
//
// Owns the shared VistaCore objects (store, indexer) and exposes the bits
// the menu bar / future panel UI needs to read. Kept @Observable so SwiftUI
// redraws automatically when indexing progress changes.

import Foundation
import Observation
import VistaCore

@Observable
@MainActor
final class AppState {
    // The indexer drives background scanning + OCR. Nil until the user has
    // granted at least one folder (security-scoped bookmark). Phase 1 uses
    // ~/Desktop directly since full permissions handling is Phase 3.
    var indexer: Indexer?

    // Progress shown in the menu bar tooltip while the initial scan runs.
    var indexingProgress: Indexer.Progress = .idle

    // Set to true when the user pauses indexing from the menu. The indexer
    // observes this and stops enqueueing new work.
    var isPaused: Bool = false

    init() {
        Task { await bootstrap() }
    }

    /// Spins up the store + indexer against the default screenshot folder.
    /// Phase 1 deliberately hard-codes ~/Desktop so we can verify the full
    /// pipeline (watch → OCR → SQLite → FTS5) before wiring preferences.
    private func bootstrap() async {
        do {
            let store = try ScreenshotStore.openDefault()
            let indexer = Indexer(
                store: store,
                ocr: OCRRecognizer(level: .fast),
                watchedFolders: [VistaPaths.defaultScreenshotFolder()]
            )
            self.indexer = indexer

            // Stream progress updates into observable state for the menu.
            Task { [weak self] in
                for await progress in indexer.progressUpdates {
                    await MainActor.run { self?.indexingProgress = progress }
                }
            }

            try await indexer.start()
        } catch {
            // Phase 1 has no alerting UI — just log. Phase 3 surfaces
            // errors in the preferences Permissions tab.
            NSLog("vista: bootstrap failed: \(error)")
        }
    }

    func rescanNow() {
        Task { await indexer?.rescanAll() }
    }

    func togglePause() {
        isPaused.toggle()
        let paused = isPaused
        // setPaused hops onto the Indexer actor; menu actions can't await,
        // so we spawn a fire-and-forget Task here.
        Task { [indexer] in await indexer?.setPaused(paused) }
    }
}
