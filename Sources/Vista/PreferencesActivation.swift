// PreferencesActivation.swift — Agent ↔ regular app flip for the prefs window.
//
// macOS gives LSUIElement=YES apps "accessory" status: no Dock icon, no
// Cmd+Tab presence, AND — the annoying part — the OS refuses to treat
// any window they open as genuinely activatable. Users see the window
// flash into front and immediately demote back behind whatever app was
// active before. This is what every menu bar app that shows a real
// preferences window works around in the same way:
//
//   on open  → NSApp.setActivationPolicy(.regular)  → Dock icon appears,
//              NSApp.activate works, window can hold focus normally
//   on close → NSApp.setActivationPolicy(.accessory) → back to menu-bar-only
//
// The Dock icon is only visible while the prefs window is open, which
// matches how Rectangle, 1Password's mini window, and similar agent apps
// handle their settings surface.

import AppKit

@MainActor
enum PreferencesActivation {

    /// Single observer so multiple open/close cycles don't stack handlers.
    private static var observer: NSObjectProtocol?

    /// Called right before opening the preferences window. Promotes the
    /// app to regular status and activates so the window can hold focus.
    ///
    /// setActivationPolicy isn't fully synchronous — the Dock server
    /// acknowledges the change on a later runloop tick. Activating before
    /// that acknowledgement arrives is a no-op, which is why a
    /// naive `willOpen + activate + openWindow` sequence produces a window
    /// that's *visible* but not *key*: it shows, the user sees it, but
    /// Cmd+Q and keystrokes still flow to whatever app was previously
    /// active. The explicit `runModalSession(for:) /.stop()` trick to
    /// force-flush the event queue isn't available here, so we instead
    /// ask callers to reactivate on a short delay — see MenuBarContentView.
    static func willOpen() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called once the preferences window exists. Wires a single willClose
    /// observer that demotes us back to accessory as soon as the window
    /// goes away — re-registered on every open so stale observers can't
    /// accumulate across repeated open/close cycles.
    static func didOpen(_ window: NSWindow) {
        if let existing = observer {
            NotificationCenter.default.removeObserver(existing)
            observer = nil
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            // We're already on the main queue via the notification's
            // queue: .main — this MainActor hop is cheap and keeps the
            // type-checker happy.
            Task { @MainActor in
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
