// HotKeyManager.swift — User-configurable global hotkey via Carbon.
//
// Why Carbon and not the HotKey Swift package? One less dependency to
// audit and update, and the surface area we need (register + callback)
// is small enough that vending our own thin wrapper is cheaper than the
// integration cost. Carbon's RegisterEventHotKey is deprecated on paper
// but Apple still ships it and every mainstream launcher still uses it —
// NSEvent.addGlobalMonitorForEvents can't catch modifier-only shortcuts
// and can't suppress the key from reaching the focused app.

import AppKit
import Carbon.HIToolbox

/// Value type describing a hotkey (⌘⇧S, ⌥Space, …). Persisted to
/// UserDefaults as two ints (keyCode + modifier mask).
public struct HotKeyChord: Equatable, Sendable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default: ⌘⇧S. Chosen so it mirrors the macOS screenshot UI
    /// shortcut family without overlapping any system-owned binding.
    public static let defaultInvoke = HotKeyChord(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: UInt32(cmdKey | shiftKey)
    )
}

@MainActor
public final class HotKeyManager {

    // Callback invoked on the main queue when the hotkey fires. We keep it
    // simple (no event payload) — the app only cares that the chord hit.
    private var onFire: (() -> Void)?

    // Carbon state. hotKeyRef is what we pass to UnregisterEventHotKey
    // when rebinding; handlerRef is the installed event handler.
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    // Every registered hotkey needs a unique (signature, id) tuple so the
    // Carbon dispatcher can route the callback. We hold id constant since
    // we only register one chord at a time.
    private static let signature: FourCharCode = {
        // 'vsta' — uniquely identifies Vista's hotkey in the Carbon namespace.
        let chars: [Character] = ["v", "s", "t", "a"]
        return chars.reduce(FourCharCode(0)) { acc, ch in
            (acc << 8) | FourCharCode(ch.asciiValue ?? 0)
        }
    }()
    private static let hotKeyId: UInt32 = 1

    public init() {}

    /// Registers `chord` and invokes `onFire` on every firing. Re-calling
    /// replaces the previous binding.
    public func register(chord: HotKeyChord, onFire: @escaping () -> Void) {
        self.onFire = onFire
        unregister()
        installHandlerIfNeeded()

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyId)
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            self.hotKeyRef = ref
        } else {
            NSLog("vista: RegisterEventHotKey failed with \(status)")
        }
    }

    public func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Carbon won't dispatch to our callback until an EventHandler is
    /// installed for kEventHotKeyPressed. We install it lazily on first
    /// register so the cost is only paid when the user actually wants a
    /// hotkey.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        var handler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                let getStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                if getStatus == noErr, hotKeyID.id == HotKeyManager.hotKeyId {
                    let manager = Unmanaged<HotKeyManager>
                        .fromOpaque(userData)
                        .takeUnretainedValue()
                    // Bounce onto the main queue — Carbon doesn't promise
                    // which thread the handler runs on, and all our UI
                    // work has to be main-actor.
                    DispatchQueue.main.async {
                        manager.onFire?()
                    }
                }
                return noErr
            },
            1,
            &spec,
            selfPointer,
            &handler
        )
        if status == noErr {
            self.handlerRef = handler
        } else {
            NSLog("vista: InstallEventHandler failed with \(status)")
        }
    }

    deinit {
        // Safe to call without hopping actors — these are C APIs that
        // don't touch Swift state.
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let handler = handlerRef {
            RemoveEventHandler(handler)
        }
    }
}
