// MenuBarContentView.swift — The dropdown shown when the menu bar icon is clicked.

import SwiftUI
import AppKit
import VistaCore

struct MenuBarContentView: View {
    @Bindable var appState: AppState
    // `openSettings` is the macOS 14+ environment value that drives the
    // Settings scene. Unlike SettingsLink it's a plain closure, which
    // lets us activate the app first so the window reliably comes to
    // front — agent apps (LSUIElement=YES) otherwise often open their
    // Settings window behind whichever app is already frontmost.
    @Environment(\.openSettings) private var openSettings

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
            // Activate before opening so the window isn't buried under
            // whichever app was frontmost when the menu was clicked.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

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
