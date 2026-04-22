// VistaApp.swift — Application entry point.
//
// Phase 1 scope: menu-bar only. The floating search panel, preferences, and
// global hotkey land in Phase 2+. Keeping this file small on purpose so the
// app boots and the indexer runs end-to-end before any UI work happens.

import SwiftUI
import VistaCore

@main
struct VistaApp: App {
    // App-wide state lives here so it survives the menu being closed/reopened
    // (MenuBarExtra tears down its view tree between clicks).
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Vista", systemImage: "camera.viewfinder") {
            MenuBarContentView(appState: appState)
        }
        // Menu style — the `.menu` variant matches the classic macOS menu
        // feel; `.window` would show a popover, which we don't want for the
        // Phase 1 stub. The real search UI is a separate NSPanel.
        .menuBarExtraStyle(.menu)

        // Adding a Settings scene gives us a real target for SettingsLink
        // and wires up the standard ⌘, shortcut automatically. Contents
        // land in Phase 3 — today it's a placeholder so the menu item
        // can be enabled instead of a dead button.
        Settings {
            SettingsView()
        }
    }
}
