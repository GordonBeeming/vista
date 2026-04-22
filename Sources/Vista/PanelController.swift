// PanelController.swift — Owns the FloatingPanel and its SwiftUI content.
//
// Keeping this distinct from AppState lets AppState stay framework-free
// (easier to test) while the AppKit-heavy plumbing lives here.

import AppKit
import SwiftUI
import VistaCore

@MainActor
public final class PanelController {

    private var panel: FloatingPanel?
    private let store: ScreenshotStore
    private let thumbnails: ThumbnailCache
    private let actions: ActionHandlers
    private let preferences: Preferences

    public init(
        store: ScreenshotStore,
        thumbnails: ThumbnailCache,
        actions: ActionHandlers,
        preferences: Preferences
    ) {
        self.store = store
        self.thumbnails = thumbnails
        self.actions = actions
        self.preferences = preferences
    }

    /// Toggle: if the panel is visible it hides, otherwise it appears.
    /// This is what we bind the global hotkey to.
    public func toggle() {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    public func show() {
        let panel = ensurePanel()
        // Apply the latest panel-size preference every show so Appearance
        // slider changes take effect without needing a relaunch.
        panel.sizeFraction = preferences.panelSizeFraction
        panel.show()
    }

    private func ensurePanel() -> FloatingPanel {
        if let existing = panel { return existing }

        let viewModel = SearchViewModel(store: store)
        let content = PanelContentView(
            model: viewModel,
            thumbnails: thumbnails,
            actions: actions,
            preferences: preferences,
            dismiss: { [weak self] in self?.panel?.orderOut(nil) }
        )

        // NSHostingView is the bridge between SwiftUI and AppKit — the
        // panel owns it as its contentView.
        let host = NSHostingView(rootView: content)
        host.autoresizingMask = [.width, .height]
        let panel = FloatingPanel(contentView: host)
        self.panel = panel
        return panel
    }
}
