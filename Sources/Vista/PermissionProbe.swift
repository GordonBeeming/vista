// PermissionProbe.swift — Live state for macOS privacy prompts.
//
// macOS's Privacy & Security settings offer no blessed API to "read the
// current state" of most permissions — you're expected to trigger them
// and see what the system does. These helpers do the least-intrusive
// probe available per permission, with care not to create phantom prompts.

import Foundation
import AppKit

enum PermissionProbe {

    enum State: Equatable {
        /// Permission is granted (or not needed on this system).
        case granted
        /// Permission is explicitly denied in System Settings.
        case denied
        /// Permission has not been asked yet; a user action will prompt.
        case notDetermined
        /// Unknown — probe not supported on this macOS version.
        case unknown

        var label: String {
            switch self {
            case .granted:       return "Granted"
            case .denied:        return "Denied"
            case .notDetermined: return "Not yet requested"
            case .unknown:       return "Unknown"
            }
        }

        var symbol: String {
            switch self {
            case .granted:       return "checkmark.circle.fill"
            case .denied:        return "xmark.octagon.fill"
            case .notDetermined: return "questionmark.circle"
            case .unknown:       return "questionmark.circle"
            }
        }
    }

    /// Automation (Apple Events) targeting System Events — the exact
    /// target we use for Paste to Front App. `AEDeterminePermissionToAutomateTarget`
    /// reports the stored decision without firing a prompt when
    /// askUserIfNeeded is false.
    static func automationForSystemEvents() -> State {
        // "sevs" == 0x73657673 == bundle code for System Events.
        var target = AEAddressDesc()
        let bundleId = "com.apple.systemevents"
        let rc: OSStatus = bundleId.withCString { cstr in
            // AECreateDesc returns OSErr (Int16) on some SDKs and OSStatus
            // (Int32) on others; widen explicitly so the comparison below
            // against noErr is type-stable across toolchains.
            OSStatus(AECreateDesc(
                typeApplicationBundleID,
                UnsafeRawPointer(cstr),
                bundleId.utf8.count,
                &target
            ))
        }
        guard rc == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            false  // askUserIfNeeded — never prompt from a status probe
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case -1744: // errAEEventWouldRequireUserConsent (not exposed as a named constant)
            return .notDetermined
        default:
            return .unknown
        }
    }

    /// Fires a no-op Apple Event at System Events with user consent
    /// enabled so macOS shows the permission prompt (and registers vista
    /// in System Settings → Privacy → Automation on first run).
    /// Returns the post-prompt state.
    @discardableResult
    static func requestAutomationForSystemEvents() -> State {
        var target = AEAddressDesc()
        let bundleId = "com.apple.systemevents"
        let rc: OSStatus = bundleId.withCString { cstr in
            // AECreateDesc returns OSErr (Int16) on some SDKs and OSStatus
            // (Int32) on others; widen explicitly so the comparison below
            // against noErr is type-stable across toolchains.
            OSStatus(AECreateDesc(
                typeApplicationBundleID,
                UnsafeRawPointer(cstr),
                bundleId.utf8.count,
                &target
            ))
        }
        guard rc == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        _ = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            true  // askUserIfNeeded
        )
        return automationForSystemEvents()
    }
}
