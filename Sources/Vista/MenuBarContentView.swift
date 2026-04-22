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

        Button("About Vista") {
            openAboutWindow()
        }

        Divider()

        Button("Quit Vista") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Opens the About window and raises it using the same activation-
    /// policy flip + find-and-raise pattern as Preferences. Without the
    /// flip, the window appears behind whichever app was frontmost — the
    /// classic LSUIElement activation problem.
    private func openAboutWindow() {
        PreferencesActivation.willOpen()

        DispatchQueue.main.async {
            openWindow(id: WindowID.about)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.about }) {
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    PreferencesActivation.didOpen(window)
                }
            }
        }
    }

    /// Opens the preferences Window scene and forces it to be key.
    ///
    /// Sequence (each step runs on the next runloop tick so the previous
    /// one's async consequences settle first):
    ///   1. setActivationPolicy(.regular) + activate — flip agent → regular
    ///   2. openWindow(id:) — let SwiftUI create the NSWindow
    ///   3. activate + orderFrontRegardless + makeKeyAndOrderFront —
    ///      now that the policy change has propagated, the window can
    ///      genuinely become key and own the menu bar (Cmd+Q quits US,
    ///      not whatever app was frontmost before).
    ///
    /// Skipping the ticks produces a "visible but not key" window: user
    /// sees the prefs, types Cmd+Q, and macOS quits the previous app.
    private func openPreferencesWindow() {
        PreferencesActivation.willOpen()

        DispatchQueue.main.async {
            openWindow(id: WindowID.preferences)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == WindowID.preferences }) {
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    PreferencesActivation.didOpen(window)
                }
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
