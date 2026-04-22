// AppState.swift — Top-level observable state for the app.
//
// Owns Preferences, the VistaCore objects (store, indexer), the thumbnail
// cache, the hotkey manager, and the panel controller. Observes
// Preferences.changes and propagates updates to the right component.

import Foundation
import Observation
import AppKit
import VistaCore

@Observable
@MainActor
final class AppState {

    // MARK: - Observable surface

    var indexingProgress: Indexer.Progress = .idle
    var isPaused: Bool = false

    /// How many screenshots are currently in the index. Convenience for
    /// the Permissions tab.
    var indexedCount: Int {
        if case .watching(let n) = indexingProgress { return n }
        if case .scanning(let done, _) = indexingProgress { return done }
        return 0
    }

    let preferences = Preferences()

    // MARK: - Private state

    private var store: ScreenshotStore?
    private var thumbnails: ThumbnailCache?
    private var indexer: Indexer?
    private var actionHandlers: ActionHandlers?
    private var panelController: PanelController?
    private let hotKey = HotKeyManager()

    init() {
        Task { await bootstrap() }
    }

    private func bootstrap() async {
        do {
            let store = try ScreenshotStore.openDefault()
            let thumbnails = try ThumbnailCache()
            let prefs = preferences
            let actions = ActionHandlers(store: store)
            let indexer = Indexer(
                store: store,
                ocr: ocrForCurrentPrefs(),
                watchedFolders: prefs.resolvedFolders()
            )

            self.store = store
            self.thumbnails = thumbnails
            self.actionHandlers = actions
            self.indexer = indexer
            self.panelController = PanelController(
                store: store,
                thumbnails: thumbnails,
                actions: actions,
                preferences: prefs
            )

            // Register the current hotkey chord.
            registerHotKey()

            // Apply the saved launch-at-login state — catches any drift
            // between the preference and the actual SMAppService status.
            _ = LaunchAtLogin.apply(enabled: prefs.launchAtLogin)

            // Progress stream → observable property.
            Task { [weak self] in
                for await progress in indexer.progressUpdates {
                    await MainActor.run { self?.indexingProgress = progress }
                }
            }

            // Preferences stream → targeted update per change.
            Task { [weak self] in
                let stream = prefs.changes
                for await change in stream {
                    await self?.apply(change: change)
                }
            }

            try await indexer.start()
            await pruneIfNeeded()
        } catch {
            NSLog("vista: bootstrap failed: \(error)")
        }
    }

    // MARK: - Preferences wiring

    private func apply(change: Preferences.Change) async {
        switch change {
        case .hotKey:
            registerHotKey()
        case .panelSize:
            // No-op: FloatingPanel reads panelSizeFraction from prefs on
            // each show, so a slider tweak takes effect next invocation.
            break
        case .ocr:
            let ocr = ocrForCurrentPrefs()
            await indexer?.setOCRRecognizer(ocr)
        case .primaryAction:
            // PanelContentView reads preferences.primaryAction at the
            // moment Enter is pressed, so nothing to do here.
            break
        case .folders:
            let folders = preferences.resolvedFolders()
            try? await indexer?.updateWatchedFolders(folders)
        case .storageDuration:
            await pruneIfNeeded()
        case .launchAtLogin:
            _ = LaunchAtLogin.apply(enabled: preferences.launchAtLogin)
        }
    }

    private func ocrForCurrentPrefs() -> OCRRecognizer {
        OCRRecognizer(level: preferences.ocrLevel, languages: preferences.ocrLanguages)
    }

    private func registerHotKey() {
        let chord = preferences.hotKey
        // A cleared chord (keyCode 0, modifiers 0) means "no hotkey" —
        // unregister so the user can still open the panel from the
        // menu bar.
        if chord.keyCode == 0, chord.modifiers == 0 {
            hotKey.unregister()
            return
        }
        hotKey.register(chord: chord) { [weak self] in
            self?.panelController?.toggle()
        }
    }

    private func pruneIfNeeded() async {
        guard let seconds = preferences.storageDuration.seconds else { return }
        let cutoff = Date().addingTimeInterval(-seconds)
        await indexer?.prune(olderThan: cutoff)
    }

    // MARK: - Menu actions

    func rescanNow() {
        Task { [indexer] in await indexer?.rescanAll() }
    }

    func togglePause() {
        setPaused(!isPaused)
    }

    /// Explicit setter used by UI bindings that receive a `newValue` —
    /// applying `newValue` directly instead of blindly toggling keeps the
    /// UI and the indexer in sync even if SwiftUI replays a state update
    /// or programmatic code sets the property.
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        Task { [indexer] in await indexer?.setPaused(paused) }
    }

    func openPanel() {
        panelController?.show()
    }
}
