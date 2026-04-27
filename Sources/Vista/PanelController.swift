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
    private var viewModel: SearchViewModel?
    private let store: ScreenshotStore
    private let thumbnails: ThumbnailCache
    private let actions: ActionHandlers
    private let preferences: Preferences

    /// The app that was frontmost when the user invoked vista's hotkey —
    /// captured before we steal focus so "Paste to Front App" can aim
    /// back at the original target rather than at vista itself.
    private var previousFrontmostApp: NSRunningApplication?

    /// Wall-clock time the panel was last hidden. Used to decide whether
    /// to reset query/selection on the next show — see `show()`. nil
    /// means we've never hidden the panel this session, in which case
    /// the view-model is already fresh and there's nothing to reset.
    private var lastHiddenAt: Date?

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

        // Wire the paste-to-front-app action. The closure runs on the
        // main actor (ActionHandlers is @MainActor) so it's safe to touch
        // NSWorkspace and NSApp directly.
        actions.pasteToFrontImpl = { [weak self] _ in
            self?.pasteToPreviousFrontmost()
        }
    }

    /// Toggle: if the panel is visible it hides, otherwise it appears.
    /// This is what we bind the global hotkey to.
    public func toggle() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            capturePreviousFrontmost()
            show()
        }
    }

    public func show() {
        capturePreviousFrontmost()
        let panel = ensurePanel()
        // If the panel has been out of sight long enough that the
        // previous query is unlikely to still be relevant, wipe back to
        // a clean state before the window is visible. Decided on each
        // show so changing the timeout in Settings takes effect
        // immediately. Skip on the very first show of the session
        // (lastHiddenAt == nil) — the view-model is already fresh.
        if let last = lastHiddenAt,
           let timeout = preferences.panelResetTimeout.seconds,
           Date().timeIntervalSince(last) >= timeout {
            viewModel?.resetState()
        }
        // Apply the latest panel-size preference every show so Appearance
        // slider changes take effect without needing a relaunch.
        panel.sizeFraction = preferences.panelSizeFraction
        panel.show()
    }

    /// Hides the panel and stamps the hide time so the next show can
    /// decide whether enough time has elapsed to warrant a state reset.
    /// Use this instead of calling `panel.orderOut` directly.
    private func hidePanel() {
        panel?.orderOut(nil)
        lastHiddenAt = Date()
    }

    /// Records whoever was frontmost before we activate. Skips vista
    /// itself — if the user opens the panel while it's already visible
    /// (e.g. via the menu bar) we don't want to overwrite the real
    /// previous app with our own bundle id.
    private func capturePreviousFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        guard app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        previousFrontmostApp = app
    }

    /// Dismisses the panel, reactivates the previously-frontmost app,
    /// and sends a Cmd+V keystroke via Apple Events. Relies on the user
    /// having granted the Automation permission for vista to control
    /// System Events — the first invocation triggers the macOS prompt,
    /// which also registers vista in the System Settings → Privacy →
    /// Automation list so the toggle is usable thereafter.
    ///
    /// Guards on a non-nil `previousFrontmostApp`: if we never captured
    /// a target (e.g. panel was opened from the menu bar and no other
    /// app was frontmost), firing the Cmd+V anyway would paste into
    /// whichever app bubbled up to frontmost after the panel hid —
    /// often vista itself, or the user's Finder. Skipping is safer; the
    /// clipboard copy already happened in ActionHandlers.
    private func pasteToPreviousFrontmost() {
        guard let target = previousFrontmostApp else {
            hidePanel()
            return
        }
        hidePanel()
        // Activate after panel hides. A short delay gives AppKit time to
        // process the orderOut before we ask another app to take focus;
        // without it the frontmost-change can be dropped on the floor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            // No-arg `activate()` is macOS 14+, which matches our deployment
            // target; the options-based variant is deprecated on 14+ and
            // `.activateIgnoringOtherApps` is itself a no-op there.
            target.activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Self.sendPasteKeystroke()
            }
        }
    }

    private static func sendPasteKeystroke() {
        let source = #"tell application "System Events" to keystroke "v" using command down"#
        guard let script = NSAppleScript(source: source) else { return }
        var error: NSDictionary?
        script.executeAndReturnError(&error)
        if let error {
            NSLog("vista: paste keystroke failed: \(error)")
        }
    }

    private func ensurePanel() -> FloatingPanel {
        if let existing = panel { return existing }

        let viewModel = SearchViewModel(store: store)
        self.viewModel = viewModel
        let content = PanelContentView(
            model: viewModel,
            thumbnails: thumbnails,
            actions: actions,
            preferences: preferences,
            dismiss: { [weak self] in self?.hidePanel() }
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
