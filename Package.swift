// swift-tools-version: 5.9
// Package.swift — vista: a macOS screenshot search utility.
//
// Two-target layout:
//   - VistaCore: library holding the indexer, Vision OCR wrapper, SQLite/FTS5
//     store, and query parser. Kept GUI-free so it's independently testable.
//   - Vista:     SwiftUI menu-bar app that owns the floating panel, settings
//     window, global hotkey, and action handlers. Depends on VistaCore.
//
// No CLI target by design — v1 is GUI-only. If we add one later it becomes a
// third .executableTarget alongside these two.

import PackageDescription

let package = Package(
    name: "Vista",
    // macOS 14 gives us @Observable, SMAppService (login items), and the
    // current MenuBarExtra APIs without needing back-deploy shims.
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // VistaCore is exposed as a library so tests (and any future CLI)
        // can link it without pulling in the AppKit/SwiftUI app target.
        .library(
            name: "VistaCore",
            targets: ["VistaCore"]
        ),
        // The app executable. Packaged into a proper .app bundle by the
        // Scripts/build-release.sh flow; `swift run Vista` also works for
        // quick iteration (no bundle, but launches the process).
        .executable(
            name: "Vista",
            targets: ["Vista"]
        ),
    ],
    dependencies: [
        // No external dependencies on purpose — SQLite, Vision, CoreServices
        // (FSEvents), AppKit, and SwiftUI all ship with macOS, and we want
        // the distributed binary as small and self-contained as possible.
    ],
    targets: [
        // MARK: - Library

        // Core indexing + search logic. Links SQLite3 for the FTS5 store,
        // Vision for OCR, and CoreServices for FSEvents folder watching.
        .target(
            name: "VistaCore",
            path: "Sources/VistaCore",
            linkerSettings: [
                // SQLite ships with macOS; link the system library instead
                // of vendoring a copy.
                .linkedLibrary("sqlite3"),
                // Vision provides VNRecognizeTextRequest (on-device OCR).
                .linkedFramework("Vision"),
                // CoreServices provides FSEventStream for folder watching.
                .linkedFramework("CoreServices"),
                // AppKit for NSImage-based thumbnailing in the core lib.
                // (Kept in core so tests can render thumbnails headlessly.)
                .linkedFramework("AppKit"),
            ]
        ),

        // MARK: - Executable

        // The SwiftUI app. Info.plist and entitlements are excluded from the
        // SPM compile — the build script copies them into the .app bundle.
        .executableTarget(
            name: "Vista",
            dependencies: ["VistaCore"],
            path: "Sources/Vista",
            exclude: ["Info.plist", "Vista.entitlements"]
        ),

        // MARK: - Tests

        // VistaCore unit tests: query parser, store, OCR on fixtures.
        .testTarget(
            name: "VistaCoreTests",
            dependencies: ["VistaCore"],
            path: "Tests/VistaCoreTests",
            resources: [
                // Fixture screenshots used by OCRRecognizerTests.
                .copy("Fixtures")
            ]
        ),
    ]
)
