// KeyRecorderView.swift — Click-to-record chord UI.
//
// When focused, the field installs a local NSEvent monitor and captures
// the next modifier+key combination. The captured chord is written back
// through the `@Binding`; any downstream observer (HotKeyManager) picks
// it up and re-registers.
//
// Design choices:
//   - Escape cancels recording (keeps old value).
//   - Delete / backspace while focused clears the chord.
//   - We only accept chords that include at least one modifier — a bare
//     letter key would fight every text field in the OS.

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct KeyRecorderView: View {
    @Binding var chord: HotKeyChord

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            HStack {
                Text(isRecording ? "Press a key…" : Self.describe(chord))
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

    // MARK: - Recording

    private func startRecording() {
        isRecording = true
        // Local monitor returns the event when we don't want the system
        // to consume it; returning nil swallows the keypress so no text
        // field catches it while we're recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event: event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(event: NSEvent) {
        // Esc cancels — keep existing chord.
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        // Delete / backspace clears to a sentinel "no chord" (keyCode 0
        // with no modifiers). We don't currently expose an "unbind" toggle
        // separately, so this doubles as the way to disable the hotkey.
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            chord = HotKeyChord(keyCode: 0, modifiers: 0)
            stopRecording()
            return
        }

        let carbonMods = Self.carbonModifiers(from: event.modifierFlags)
        guard carbonMods != 0 else {
            // Bare letter key — ignore and keep listening. Hotkeys without
            // modifiers would clash with basic typing.
            return
        }

        chord = HotKeyChord(keyCode: UInt32(event.keyCode), modifiers: UInt32(carbonMods))
        stopRecording()
    }

    // MARK: - Display

    /// Renders a chord like `⌘⇧S` or `⌥Space`. Uses the standard macOS
    /// glyphs in a single font run so width stays predictable.
    static func describe(_ chord: HotKeyChord) -> String {
        if chord.keyCode == 0, chord.modifiers == 0 {
            return "Click to record"
        }
        var out = ""
        if chord.modifiers & UInt32(controlKey) != 0 { out += "⌃" }
        if chord.modifiers & UInt32(optionKey) != 0  { out += "⌥" }
        if chord.modifiers & UInt32(shiftKey) != 0   { out += "⇧" }
        if chord.modifiers & UInt32(cmdKey) != 0     { out += "⌘" }
        out += Self.keyName(for: chord.keyCode)
        return out
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
        case kVK_F1:         return "F1"
        case kVK_F2:         return "F2"
        case kVK_F3:         return "F3"
        case kVK_F4:         return "F4"
        case kVK_F5:         return "F5"
        case kVK_F6:         return "F6"
        case kVK_F7:         return "F7"
        case kVK_F8:         return "F8"
        case kVK_F9:         return "F9"
        case kVK_F10:        return "F10"
        case kVK_F11:        return "F11"
        case kVK_F12:        return "F12"
        default:
            // Ask the current keyboard layout to translate the keyCode
            // into a Unicode character. This respects non-QWERTY layouts
            // (Dvorak, AZERTY, etc.) and produces the right label for
            // the user's physical keys.
            return layoutKeyName(for: keyCode) ?? "Key\(keyCode)"
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

    /// NSEvent's Cocoa modifier flags need translating to Carbon's flag
    /// constants to round-trip through RegisterEventHotKey.
    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> Int {
        var out = 0
        if flags.contains(.command)  { out |= cmdKey }
        if flags.contains(.shift)    { out |= shiftKey }
        if flags.contains(.option)   { out |= optionKey }
        if flags.contains(.control)  { out |= controlKey }
        return out
    }
}
