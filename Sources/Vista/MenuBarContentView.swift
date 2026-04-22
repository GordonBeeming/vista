// MenuBarContentView.swift — The dropdown shown when the menu bar icon is clicked.

import SwiftUI
import VistaCore

struct MenuBarContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        Text(statusLine)

        Divider()

        Button("Search Screenshots…") {
            appState.openPanel()
        }
        .keyboardShortcut("s", modifiers: [.command, .shift])

        Divider()

        Button(appState.isPaused ? "Resume Indexing" : "Pause Indexing") {
            appState.togglePause()
        }

        Button("Rescan Now") {
            appState.rescanNow()
        }

        Divider()

        Button("Preferences…") {
            // Phase 3.
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
