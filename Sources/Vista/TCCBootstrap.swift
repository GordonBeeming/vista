// TCCBootstrap.swift — Prime macOS's FDA list with vista's identity.
//
// Apps only appear in System Settings → Privacy & Security → Full Disk
// Access after they've attempted to read a TCC-protected file at least
// once. Without a deliberate read, macOS has no record of the app in
// its TCC database, and a user who wants to grant FDA has to "+" browse
// to vista.app manually.
//
// Running a few cheap read attempts at launch — all expected to fail
// until the user grants — is enough for the TCC daemon to register
// vista in the list. The reads are wrapped in fopen/try? so failures
// are silent.

import Foundation

enum TCCBootstrap {

    /// Call once on app launch. Idempotent — multiple invocations just
    /// fire the same couple of reads.
    static func registerWithTCC() {
        // TCC.db is the canonical FDA-gated file. Reading it is what
        // most apps do to show up in the FDA list.
        attemptRead(at: "/Library/Application Support/com.apple.TCC/TCC.db")

        // Safari's bookmarks file is also FDA-gated; hitting a second
        // path improves the odds that TCC logs the access attempt,
        // since macOS has been inconsistent across versions about which
        // paths trigger the registration.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        attemptRead(at: "\(home)/Library/Safari/Bookmarks.plist")
    }

    /// Opens the file read-only and immediately closes it. The attempt
    /// itself is what TCC observes; the resulting handle is discarded.
    /// Using fopen rather than FileHandle keeps the call non-throwing
    /// and avoids logging a Swift error for the expected EPERM case.
    private static func attemptRead(at path: String) {
        guard let handle = fopen(path, "r") else { return }
        fclose(handle)
    }
}
