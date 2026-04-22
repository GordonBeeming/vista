// KeyRecorderView.swift — Click-to-record chord UI.
//
// While recording, the field installs a local NSEvent monitor for both
// keyDown and flagsChanged. flagsChanged gives us the current modifier
// mask so the UI can render "⌃⌥⇧⌘…" live as a Hyper key is held down —
// without that live echo, users hitting a Hyper mapping have no way to
// tell whether the key is registering at all.
//
// The final chord is captured on the first keyDown whose keyCode isn't a
// modifier itself. Escape cancels, Delete clears.
//
// Note on Hyper keys: if an upstream tool (Karabiner, BetterTouchTool,
// Raycast) has already claimed the same chord as a trigger, macOS will
// route it there before NSEvent sees it — the recorder will appear
// unresponsive. Unbind it in the other tool or pick a different chord.

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct KeyRecorderView: View {
    @Binding var chord: HotKeyChord

    @State private var isRecording = false
    @State private var monitor: Any?
    // Live modifier mask while recording — drives the "⌃⌥⇧⌘" echo so the
    // user can see their Hyper key is actually reaching the app.
    @State private var liveMods: UInt32 = 0

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack {
                Text(displayText)
                    .monospaced()
                Spacer()
                if isRecording {
                    Text("esc to cancel")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 180, minHeight: 22)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.accentColor.opacity(0.18) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isRecording ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onDisappear { stopRecording() }
    }

    /// What to show in the button. Prefers a live echo while recording so
    /// the user sees their modifiers being held; otherwise shows the
    /// currently-saved chord.
    private var displayText: String {
        if isRecording {
            if liveMods != 0 {
                return Self.describe(HotKeyChord(keyCode: 0, modifiers: liveMods)) + "…"
            }
            return "Press a key…"
        }
        return Self.describe(chord)
    }

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        liveMods = 0
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handle(event: event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        liveMods = 0
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(event: NSEvent) {
        if event.type == .flagsChanged {
            liveMods = UInt32(Self.carbonModifiers(from: event.modifierFlags))
            return
        }

        // keyDown from here on.
        if event.keyCode == UInt16(kVK_Escape), Self.carbonModifiers(from: event.modifierFlags) == 0 {
            stopRecording()
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            chord = HotKeyChord(keyCode: 0, modifiers: 0)
            stopRecording()
            return
        }
        // Skip pure-modifier keyDowns (shouldn't normally happen, but some
        // rewriters emit them). Wait for a "real" key press.
        if Self.isPureModifier(keyCode: event.keyCode) {
            return
        }

        let carbonMods = UInt32(Self.carbonModifiers(from: event.modifierFlags))
        chord = HotKeyChord(keyCode: UInt32(event.keyCode), modifiers: carbonMods)
        stopRecording()
    }

    // MARK: - Display

    /// Renders a chord like `⌃⌥⇧⌘S` (Hyper+S). Uses macOS standard glyphs
    /// in a single font run so the width stays predictable.
    static func describe(_ chord: HotKeyChord) -> String {
        if chord.keyCode == 0, chord.modifiers == 0 {
            return "Click to record"
        }
        var out = ""
        if chord.modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if chord.modifiers & UInt32(optionKey) != 0  { out += "⌥" }
        if chord.modifiers & UInt32(shiftKey) != 0   { out += "⇧" }
        if chord.modifiers & UInt32(cmdKey) != 0     { out += "⌘" }
        if chord.keyCode != 0 {
            out += Self.keyName(for: chord.keyCode)
        }
        return out.isEmpty ? "Click to record" : out
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space:      return "Space"
        case kVK_Tab:        return "Tab"
        case kVK_Return:     return "↩"
        case kVK_Escape:     return "⎋"
        case kVK_LeftArrow:  return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow:    return "↑"
        case kVK_DownArrow:  return "↓"
        case kVK_F1:  return "F1"
        case kVK_F2:  return "F2"
        case kVK_F3:  return "F3"
        case kVK_F4:  return "F4"
        case kVK_F5:  return "F5"
        case kVK_F6:  return "F6"
        case kVK_F7:  return "F7"
        case kVK_F8:  return "F8"
        case kVK_F9:  return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        default:
            return layoutKeyName(for: keyCode) ?? "Key\(keyCode)"
        }
    }

    /// Pure modifier keys emit keyDowns on some rewriters; filter them so
    /// the recorder waits for a real chord termination.
    private static func isPureModifier(keyCode: UInt16) -> Bool {
        switch Int(keyCode) {
        case kVK_Shift, kVK_RightShift,
             kVK_Control, kVK_RightControl,
             kVK_Option, kVK_RightOption,
             kVK_Command, kVK_RightCommand,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }

    private static func layoutKeyName(for keyCode: UInt32) -> String? {
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
            let result = String(utf16CodeUnits: chars, count: length).uppercased()
            return result.isEmpty ? nil : result
        }
    }

    /// Translate Cocoa's modifier flags into Carbon's bitmask.
    /// `deviceIndependentFlagsMask` strips device-specific bits (capsLock
    /// position, numpad state) that we don't care about, which prevents a
    /// stuck Caps Lock from polluting the stored chord.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        let masked = flags.intersection(.deviceIndependentFlagsMask)
        var out = 0
        if masked.contains(.command)  { out |= cmdKey }
        if masked.contains(.shift)    { out |= shiftKey }
        if masked.contains(.option)   { out |= optionKey }
        if masked.contains(.control)  { out |= controlKey }
        return out
    }
}
