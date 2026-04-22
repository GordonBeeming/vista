// SettingsView.swift — Placeholder Settings scene.
//
// Phase 3 fills this in with the tabbed prefs described in the plan
// (General, Behaviour, Folders, Search, Appearance, Shortcuts, Permissions).
// For now we ship a single informational view so the menu item works and
// ⌘, opens something rather than being inert.

import SwiftUI

struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "camera.viewfinder")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vista")
                        .font(.title2).bold()
                    Text("Screenshot search for macOS")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Preferences are on the way.")
                .font(.headline)
            Text("Folder list, OCR accuracy, panel size, and global hotkey rebinding land in the next update. For now vista watches the macOS default screenshot folder and responds to ⌘⇧S.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            HStack {
                Spacer()
                Text("v0.1.0")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
        .frame(width: 480, height: 280)
    }
}
