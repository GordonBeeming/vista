// FloatingPanel.swift — The HUD-style window that holds the search grid.
//
// Design intent:
//   - Nonactivating — appearing doesn't steal focus from the frontmost app,
//     so "Paste to Front App" has a frontmost app to paste into.
//   - Floats above normal windows so it's always visible while you type.
//   - Rounded, translucent chrome that looks native to modern macOS.
//   - Sized to a user-settable fraction of the active screen (default 60%).
//   - Dismisses on Esc and when focus is lost.

import AppKit
import SwiftUI

/// Controls whether the panel is shown and where it's positioned.
public final class FloatingPanel: NSPanel {

    /// Fraction of the active screen, from 0.3 (compact) to 1.0 (full).
    /// Applied every time the panel is shown so changes take effect without
    /// needing a relaunch.
    public var sizeFraction: CGFloat = 0.6

    public init(contentView: NSView) {
        // Borderless = no traffic-light buttons, no titlebar strip. The
        // whole visible surface is our SwiftUI content, which handles its
        // own rounded corners and background material. `.titled` would
        // bake in a chrome strip we can't fully hide, which shows up as a
        // dark border above the SwiftUI material.
        let style: NSWindow.StyleMask = [.borderless, .resizable, .nonactivatingPanel]

        // 800x600 is replaced immediately by applySize() on first show —
        // NSPanel refuses to init with a zero-sized rect so pick something
        // sensible.
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.becomesKeyOnlyIfNeeded = false
        // isOpaque=false + clear backgroundColor lets the SwiftUI material
        // and corner clip-shape define the visible shape of the window.
        // Without these the rounded corners render onto an opaque grey
        // square (the "transparent border" effect).
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true

        self.contentView = contentView
    }

    /// Panels default to declining key-window status; we need it so the
    /// SwiftUI search field can accept typed text.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    /// Sizes the panel according to `sizeFraction` and centers it on the
    /// screen that currently hosts the mouse. Falls back to the primary
    /// screen when the mouse is offscreen.
    public func applySize() {
        let screen = Self.activeScreen()
        let visible = screen.visibleFrame
        let width = visible.width * sizeFraction
        let height = visible.height * sizeFraction
        let origin = NSPoint(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2
        )
        setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
    }

    public func show() {
        applySize()
        // orderFrontRegardless + activate-on-next-runloop is the idiomatic
        // way to raise a nonactivating panel while still allowing the
        // embedded text field to become first responder.
        makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Chosen by proximity to the cursor — multi-monitor users expect the
    /// panel to appear on whichever screen they're currently looking at.
    private static func activeScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
