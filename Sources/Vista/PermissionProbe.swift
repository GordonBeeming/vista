// PermissionProbe.swift — Live state for macOS privacy prompts.
//
// macOS doesn't expose a clean "is permission X granted?" API for most
// categories — TCC is deliberately opaque to the apps it governs. These
// helpers use the least-invasive probe available per category:
//   - Automation: AEDeterminePermissionToAutomateTarget with
//                 askUserIfNeeded=false (read-only).  The Grant path uses
//                 AppleScript instead because it triggers the prompt
//                 more reliably across macOS versions than the raw AE API.
//   - Full Disk Access: try reading /Library/Application Support/com.apple.TCC/TCC.db
//                 — the canonical FDA-gated location. Readable ⇒ granted.

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

    // MARK: - Automation (Apple Events to System Events)

    /// Read-only check — does not prompt the user. Logs the raw OSStatus
    /// when the result is anything other than granted/denied/notDetermined
    /// so we can map new values if Apple introduces them.
    static func automationForSystemEvents() -> State {
        var target = AEAddressDesc()
        let bundleId = "com.apple.systemevents"
        let createStatus: OSStatus = bundleId.withCString { cstr in
            OSStatus(AECreateDesc(
                typeApplicationBundleID,
                UnsafeRawPointer(cstr),
                bundleId.utf8.count,
                &target
            ))
        }
        guard createStatus == noErr else {
            NSLog("vista: AECreateDesc failed (\(createStatus)) — probe indeterminate")
            return .unknown
        }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target,
            typeWildCard,
            typeWildCard,
            false
        )

        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):  // -1743
            return .denied
        case -1744:  // errAEEventWouldRequireUserConsent (no named constant)
            return .notDetermined
        case -600:   // procNotFound — System Events process not running
            NSLog("vista: automation probe: System Events not running — treating as not determined")
            return .notDetermined
        default:
            NSLog("vista: automation probe: unexpected OSStatus \(status)")
            return .unknown
        }
    }

    /// Triggers the macOS Automation prompt the first time it's called
    /// for this app, and afterwards either succeeds or fails depending on
    /// whether the user granted permission. We use NSAppleScript because
    /// it's been the reliable path across macOS versions — the raw
    /// AEDeterminePermissionToAutomateTarget API with askUserIfNeeded
    /// has been flaky for us on macOS 26.
    @discardableResult
    static func requestAutomationForSystemEvents() -> State {
        // Harmless read-only query. System Events returns the current
        // user's short name; the value is discarded. The key is that
        // running this script causes macOS to evaluate whether vista
        // has Automation permission for System Events, and if not,
        // shows the permission prompt.
        let source = #"tell application "System Events" to return name of current user"#
        guard let script = NSAppleScript(source: source) else {
            NSLog("vista: NSAppleScript(source:) returned nil — cannot request Automation")
            return .unknown
        }
        var error: NSDictionary?
        _ = script.executeAndReturnError(&error)
        if let error {
            NSLog("vista: AppleScript probe error: \(error)")
        }
        // Re-read the state — after a successful run it's .granted; if
        // the user denied the prompt it's .denied; if the dialog is still
        // open it may still be .notDetermined until the user responds.
        return automationForSystemEvents()
    }

    // MARK: - Full Disk Access

    /// FDA is a binary question: if we can read `TCC.db`, we have it.
    /// If not (isReadableFile returns false, open() EPERMs), we don't.
    static func fullDiskAccess() -> State {
        let tccPath = "/Library/Application Support/com.apple.TCC/TCC.db"
        let fm = FileManager.default
        // fileExists returns true even when we can't read — need a
        // stronger signal. Try opening the file; errno distinguishes
        // "not permitted" from other failures.
        guard fm.fileExists(atPath: tccPath) else {
            // Unusual — the file is always there on a normal macOS
            // install. If it's missing we can't conclude either way.
            return .unknown
        }
        let handle = fopen(tccPath, "r")
        if let handle {
            fclose(handle)
            return .granted
        }
        // Most common failure is EACCES / EPERM — FDA not granted.
        return .denied
    }
}
