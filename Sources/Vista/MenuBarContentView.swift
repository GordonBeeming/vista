// MenuBarContentView.swift — The dropdown shown when the menu bar icon is clicked.

import SwiftUI
import AppKit
import Carbon.HIToolbox
import VistaCore

// Explicit MainActor — touches AppState (MainActor) and drives window
// management via NSApp. Swift 6.x infers this; 5.10 doesn't.
@MainActor
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
        .keyboardShortcut(appState.preferences.hotKey.asSwiftUIShortcut)

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
        case .enumerating(let folders):
            return folders == 1 ? "Scanning folder…" : "Scanning \(folders) folders…"
        case .indexing(let done, let total):
            if total == 0 {
                // Empty queue = fully resumed from the DB, everything
                // was already indexed. Jump straight to the steady-state
                // message so the user doesn't see a flash of "0 / 0".
                return "Up to date"
            }
            return "OCR'ing \(done) / \(total) new images"
        case .watching(let indexed):
            return "\(indexed) screenshots indexed"
        }
    }
}

extension HotKeyChord {
    /// Converts this Carbon-backed chord into the SwiftUI shortcut the
    /// menu item renders. Returns nil (no shortcut shown) when the chord
    /// is empty or the key doesn't map cleanly to a `KeyEquivalent`, so
    /// the menu never shows a stale/wrong glyph — the global Carbon
    /// hotkey still fires regardless.
    var asSwiftUIShortcut: KeyboardShortcut? {
        guard keyCode != 0 else { return nil }
        guard let equivalent = Self.keyEquivalent(for: keyCode) else { return nil }

        // Carbon also vends an `EventModifiers` type, so the SwiftUI one
        // needs to be fully qualified or the type checker can't pick a
        // base for `.command` / `.shift` / `.option` / `.control`.
        var mods: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey)     != 0 { mods.insert(.command) }
        if modifiers & UInt32(shiftKey)   != 0 { mods.insert(.shift) }
        if modifiers & UInt32(optionKey)  != 0 { mods.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { mods.insert(.control) }

        return KeyboardShortcut(equivalent, modifiers: mods)
    }

    private static func keyEquivalent(for keyCode: UInt32) -> KeyEquivalent? {
        switch Int(keyCode) {
        case kVK_Space:         return .space
        case kVK_Return:        return .return
        case kVK_Tab:            return .tab
        case kVK_Escape:         return .escape
        case kVK_Delete:         return .delete
        case kVK_ForwardDelete:  return .deleteForward
        case kVK_LeftArrow:      return .leftArrow
        case kVK_RightArrow:     return .rightArrow
        case kVK_UpArrow:        return .upArrow
        case kVK_DownArrow:      return .downArrow
        default:
            // Translate via the active keyboard layout so AZERTY/QWERTZ
            // users see their own glyph, not a QWERTY guess. Lowercased
            // because SwiftUI compares case-insensitively and the menu
            // draws the glyph in its own case regardless.
            guard let name = layoutCharacter(for: keyCode), let ch = name.first else {
                return nil
            }
            return KeyEquivalent(Character(ch.lowercased()))
        }
    }

    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let ptr = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeyState: UInt32 = 0
            var chars: [UniChar] = Array(repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                ptr,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )
            guard status == noErr, length > 0 else { return nil }
            let result = String(utf16CodeUnits: chars, count: length)
            return result.isEmpty ? nil : result
        }
    }
}
