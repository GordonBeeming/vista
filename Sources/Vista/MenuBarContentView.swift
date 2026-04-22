// MenuBarContentView.swift — The dropdown shown when the menu bar icon is clicked.
//
// Phase 1 intentionally minimal: shows indexing status, lets you trigger a
// rescan, pause, or quit. Preferences is a stub until Phase 3.

import SwiftUI
import VistaCore

struct MenuBarContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        // Indexer status line — disabled so it doesn't look clickable but
        // gives immediate feedback that vista is working.
        Text(statusLine)

        Divider()

        Button(appState.isPaused ? "Resume Indexing" : "Pause Indexing") {
            appState.togglePause()
        }

        Button("Rescan Now") {
            appState.rescanNow()
        }

        Divider()

        // Preferences stub — real window lands in Phase 3. Keeping the menu
        // item here so the slot exists.
        Button("Preferences…") {
            // Intentionally empty in Phase 1.
        }
        .disabled(true)

        Divider()

        Button("Quit Vista") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch appState.indexingProgress {
        case .idle:
            return "Vista — idle"
        case .scanning(let done, let total):
            return "Indexing \(done) / \(total)"
        case .watching(let indexed):
            return "\(indexed) screenshots indexed"
        }
    }
}
