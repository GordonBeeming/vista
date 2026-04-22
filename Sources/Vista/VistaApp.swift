// VistaApp.swift — Application entry point.
//
// Phase 1 scope: menu-bar only. The floating search panel, preferences, and
// global hotkey land in Phase 2+. Keeping this file small on purpose so the
// app boots and the indexer runs end-to-end before any UI work happens.

import SwiftUI
import VistaCore

@main
// Swift 6.x on macOS 26 infers MainActor for App conformances, but the
// Swift 5.10 toolchain that ships with macos-14 runners does not — which
// surfaces as "main actor-isolated initializer cannot be called from a
// synchronous nonisolated context" on `@State private var appState = AppState()`.
// Explicit annotation pins the actor for both toolchains.
@MainActor
struct VistaApp: App {
    // App-wide state lives here so it survives the menu being closed/reopened
    // (MenuBarExtra tears down its view tree between clicks).
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Vista", systemImage: "camera.viewfinder") {
            MenuBarContentView(appState: appState)
        }
        .menuBarExtraStyle(.menu)

        // Regular Window scene (not SwiftUI's Settings scene) — Settings
        // ties itself to the app's activation state, which for an agent
        // app (LSUIElement=YES) is "not really active", so openSettings()
        // creates the window but macOS refuses to bring it forward. A
        // Window scene we control ourselves + NSApp.activate + find-and-
        // raise on open works every time.
        Window("Vista Preferences", id: WindowID.preferences) {
            SettingsView(preferences: appState.preferences, appState: appState)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 540, height: 460)

        Window("About Vista", id: WindowID.about) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 460)
    }
}

/// Central home for scene / window identifiers so the menu bar and the
/// scene registration can't drift out of sync via a typo'd string.
enum WindowID {
    static let preferences = "vista.preferences"
    static let about = "vista.about"
}
