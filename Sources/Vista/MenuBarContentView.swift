// MenuBarContentView.swift — The dropdown shown when the menu bar icon is clicked.

import SwiftUI
import AppKit
import VistaCore

struct MenuBarContentView: View {
    @Bindable var appState: AppState
    // openWindow drives our Window scene. Combined with NSApp.activate
    // and a find-and-raise pass, this reliably brings the preferences
    // window forward even when the app is acting as an accessory.
    @Environment(\.openWindow) private var openWindow

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
            openPreferencesWindow()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Vista") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Opens the preferences Window scene and forces it to the front.
    ///
    /// We do two passes: an immediate activate+open, and a short-delayed
    /// orderFrontRegardless so a freshly-created window that races our
    /// first pass still gets raised. The delay is small enough to feel
    /// instant but long enough for SwiftUI to have created the NSWindow.
    private func openPreferencesWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: WindowID.preferences)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.preferences }) {
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
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
