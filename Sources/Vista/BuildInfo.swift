// BuildInfo.swift — Version / commit metadata baked into the app bundle.
//
// Values come from the Info.plist keys that Scripts/build-release.sh writes
// at bundle time:
//   CFBundleShortVersionString  — semver like "0.1"
//   VistaGitCommit              — 7-char SHA, or "unknown" for non-git builds
//   VistaReleaseTag             — release tag (e.g. "v0.1.0") when built
//                                 from a tag; empty string otherwise
//
// For unbundled dev builds (`swift run Vista`), Info.plist isn't read, so
// these all fall back to best-effort defaults.

import Foundation

enum BuildInfo {

    /// "0.1" from CFBundleShortVersionString; "dev" when unbundled.
    static let version: String = {
        info("CFBundleShortVersionString") ?? "dev"
    }()

    /// Short git commit SHA (7 chars). Empty string for dev builds where
    /// Info.plist wasn't generated.
    static let commit: String = {
        info("VistaGitCommit") ?? ""
    }()

    /// Release tag (e.g. "v0.1.0") for tagged CI builds; empty otherwise.
    static let releaseTag: String = {
        info("VistaReleaseTag") ?? ""
    }()

    /// Target URL for the commit/tag badge in the UI.
    ///
    /// Prefers the release page when this build came from a tagged release
    /// so users get the release notes directly. Falls back to the bare
    /// commit page so even ad-hoc CI builds have a working link.
    static var releaseOrCommitURL: URL? {
        let repo = "https://github.com/gordonbeeming/vista"
        if !releaseTag.isEmpty {
            return URL(string: "\(repo)/releases/tag/\(releaseTag)")
        }
        if !commit.isEmpty, commit != "unknown" {
            return URL(string: "\(repo)/commit/\(commit)")
        }
        return URL(string: repo)
    }

    /// "v0.1 · abc1234" or "v0.1" or "dev · abc1234" — whichever info is
    /// available. Tight string designed for the footer. The "v" prefix
    /// is only applied when the version actually looks like a semver, so
    /// a literal "dev" doesn't render as "vdev".
    static var footerBadge: String {
        let looksLikeSemver = version.first?.isNumber == true
        var parts: [String] = [looksLikeSemver ? "v\(version)" : version]
        if !commit.isEmpty, commit != "unknown" {
            parts.append(commit)
        }
        return parts.joined(separator: " · ")
    }

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.infoDictionary?[key] as? String,
              !value.isEmpty else { return nil }
        return value
    }
}
