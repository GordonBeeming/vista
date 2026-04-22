// LaunchAtLogin.swift — Small wrapper around SMAppService.
//
// Lets Preferences flip a single boolean while handling the "service
// already registered / not registered" edge cases and surfaces the
// resulting status for the prefs UI to display.

import Foundation
import ServiceManagement

enum LaunchAtLogin {

    /// Applies the user's desired state (true → register, false → unregister).
    /// Returns the resolved state after the call so the UI can
    /// reconcile optimistic state with reality.
    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            NSLog("vista: SMAppService.\(enabled ? "register" : "unregister") failed: \(error)")
        }
        return service.status == .enabled
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
