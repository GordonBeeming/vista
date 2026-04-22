// VistaPaths.swift — Canonical filesystem locations used by vista.
//
// Centralised so we don't have ~/Library paths scattered through the code.
// Each helper returns the URL and ensures the directory exists.

import Foundation

public enum VistaPaths {

    /// `~/Library/Application Support/Vista/` — created lazily.
    ///
    /// Holds the SQLite index (`index.sqlite`) and any persistent state
    /// that should survive upgrades but is not user-editable.
    public static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Vista", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// `~/Library/Caches/com.gordonbeeming.vista/` — thumbnail cache.
    ///
    /// Separate from Application Support because the OS is allowed to evict
    /// the Caches directory under disk pressure, which is the right policy
    /// for thumbnails we can always regenerate from the source image.
    public static func cachesDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("com.gordonbeeming.vista", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Resolves the user's current macOS screenshot save location.
    ///
    /// `screencapture` reads `com.apple.screencapture location` as a CFPrefs
    /// value. When unset (the default), screenshots land on ~/Desktop, so we
    /// fall back to that. Path strings may contain `~` — we expand them.
    public static func defaultScreenshotFolder() -> URL {
        if let raw = CFPreferencesCopyAppValue(
            "location" as CFString,
            "com.apple.screencapture" as CFString
        ) as? String, !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }
}
