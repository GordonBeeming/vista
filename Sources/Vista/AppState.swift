// AppState.swift — Top-level observable state for the app.
//
// Owns the shared VistaCore objects (store, indexer), the thumbnail cache,
// the hotkey manager, and the panel controller. The menu bar reads its
// status strings from here.

import Foundation
import Observation
import VistaCore

@Observable
@MainActor
final class AppState {
    var indexer: Indexer?
    var indexingProgress: Indexer.Progress = .idle
    var isPaused: Bool = false

    private var store: ScreenshotStore?
    private var thumbnails: ThumbnailCache?
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
            let actions = ActionHandlers(store: store)
            let indexer = Indexer(
                store: store,
                ocr: OCRRecognizer(level: .fast),
                watchedFolders: [VistaPaths.defaultScreenshotFolder()]
            )

            self.store = store
            self.thumbnails = thumbnails
            self.actionHandlers = actions
            self.indexer = indexer
            self.panelController = PanelController(
                store: store,
                thumbnails: thumbnails,
                actions: actions
            )

            // Wire the default ⌘⇧S hotkey. Rebinding UI lands in Phase 3.
            hotKey.register(chord: .defaultInvoke) { [weak self] in
                self?.panelController?.toggle()
            }

            Task { [weak self] in
                for await progress in indexer.progressUpdates {
                    await MainActor.run { self?.indexingProgress = progress }
                }
            }

            try await indexer.start()
        } catch {
            NSLog("vista: bootstrap failed: \(error)")
        }
    }

    func rescanNow() {
        Task { [indexer] in await indexer?.rescanAll() }
    }

    func togglePause() {
        isPaused.toggle()
        let paused = isPaused
        Task { [indexer] in await indexer?.setPaused(paused) }
    }

    func openPanel() {
        panelController?.show()
    }
}
