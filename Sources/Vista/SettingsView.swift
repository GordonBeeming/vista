// SettingsView.swift — Full tabbed preferences.
//
// Matches every knob Raycast exposes plus vista's two extras (user-set
// hotkey and panel size). Each tab reads and writes straight through the
// shared Preferences object, which persists to UserDefaults / bookmarks
// and emits change events for the downstream components (Indexer,
// HotKeyManager, FloatingPanel) to react to.

import SwiftUI
import AppKit
import VistaCore

/// Tabs shown at the top of the preferences window. Kept as an enum so
/// the identifier, label, and icon all live in one place and the switch
/// in the body is exhaustively checked.
private enum PrefTab: String, CaseIterable, Identifiable {
    case general, behaviour, folders, search, appearance, shortcuts, permissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:     return "General"
        case .behaviour:   return "Behaviour"
        case .folders:     return "Folders"
        case .search:      return "Search"
        case .appearance:  return "Appearance"
        case .shortcuts:   return "Shortcuts"
        case .permissions: return "Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .general:     return "gear"
        case .behaviour:   return "return"
        case .folders:     return "folder"
        case .search:      return "magnifyingglass"
        case .appearance:  return "rectangle.on.rectangle"
        case .shortcuts:   return "command"
        case .permissions: return "checkmark.shield"
        }
    }
}

struct SettingsView: View {
    @Bindable var preferences: Preferences
    let appState: AppState

    @State private var selection: PrefTab = .general

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            // The selected tab's content. Wrapped in a fixed-height frame
            // so the window doesn't resize as the user switches tabs —
            // matches how macOS's built-in Settings window feels.
            tabContent
                .frame(maxWidth: .infinity, minHeight: 380, alignment: .top)
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        // Belt-and-braces window raise — matches the openPreferencesWindow
        // logic in MenuBarContentView, here as a final safety net in case
        // the window is created in response to Cmd+, (menu path bypassed).
        .onAppear {
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "vista.preferences" }) {
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(nil)
                    PreferencesActivation.didOpen(window)
                }
            }
        }
    }

    // MARK: - Tab bar

    /// Horizontal row of icon+label buttons styled like the macOS
    /// preferences window. Rolled by hand because SwiftUI's TabView
    /// renders as a navigation popover inside a regular Window scene —
    /// the classic top-tabs look is only available inside the Settings
    /// scene, which we can't use for activation-policy reasons.
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(PrefTab.allCases) { tab in
                tabButton(for: tab)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func tabButton(for tab: PrefTab) -> some View {
        let isSelected = selection == tab
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18, weight: .regular))
                Text(tab.label)
                    .font(.system(size: 11))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : .clear)
            )
            .foregroundStyle(isSelected ? Color.accentColor : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab content

    @ViewBuilder
    private var tabContent: some View {
        switch selection {
        case .general:     GeneralTab(preferences: preferences, appState: appState)
        case .behaviour:   BehaviourTab(preferences: preferences)
        case .folders:     FoldersTab(preferences: preferences)
        case .search:      SearchTab(preferences: preferences)
        case .appearance:  AppearanceTab(preferences: preferences)
        case .shortcuts:   ShortcutsTab(preferences: preferences)
        case .permissions: PermissionsTab(appState: appState)
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Bindable var preferences: Preferences
    let appState: AppState

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            Toggle("Pause indexing", isOn: .init(
                get: { appState.isPaused },
                set: { _ in appState.togglePause() }
            ))
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Behaviour

private struct BehaviourTab: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Picker("Primary Action", selection: $preferences.primaryAction) {
                ForEach(PrimaryAction.allCases) { action in
                    Text(action.label).tag(action)
                }
            }
            Text("What ⏎ does when a result is selected. Every action is still available via the ⌘K menu.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Folders

private struct FoldersTab: View {
    @Bindable var preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Vista watches the macOS default screenshot location automatically. Add any extra folders you want to search.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Toggle(isOn: $preferences.watchDefaultFolder) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()

                Image(systemName: "folder.fill.badge.gearshape")
                    .foregroundStyle(preferences.watchDefaultFolder ? .secondary : .tertiary)
                VStack(alignment: .leading) {
                    Text("Default screenshot folder")
                        .foregroundStyle(preferences.watchDefaultFolder ? .primary : .tertiary)
                    Text(VistaPaths.defaultScreenshotFolder().path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer()
                Text(preferences.watchDefaultFolder ? "Watching" : "Excluded")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // User-added folders list.
            if preferences.watchedFolders.isEmpty {
                Text("No additional folders. Click ‘Add Folder…’ to include a custom location.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
            } else {
                List {
                    ForEach(preferences.watchedFolders) { folder in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(folder.displayPath)
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer()
                            Button {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.displayPath)
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                            Button(role: .destructive) {
                                preferences.removeFolder(id: folder.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Remove")
                        }
                    }
                }
                .frame(minHeight: 120)
            }

            HStack {
                Spacer()
                Button("Add Folder…") { addFolder() }
                    .controlSize(.large)
            }

            Toggle("Include all images & movies", isOn: $preferences.includeAllMedia)
                .help("Index every image and video in watched folders, not just files that look like screenshots.")

            Spacer()
        }
        .padding(20)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        panel.message = "Choose a folder to index screenshots from."
        if panel.runModal() == .OK, let url = panel.url {
            preferences.addFolder(url)
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Picker("Text Recognition", selection: $preferences.ocrLevel) {
                Text("Off").tag(OCRRecognizer.Level.off)
                Text("Fast").tag(OCRRecognizer.Level.fast)
                Text("Accurate").tag(OCRRecognizer.Level.accurate)
            }
            Text(ocrDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Storage Duration", selection: $preferences.storageDuration) {
                ForEach(StorageDuration.allCases) { duration in
                    Text(duration.label).tag(duration)
                }
            }
            Text("Older index entries are removed automatically. Pinned screenshots are kept regardless. Your actual image files are never deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Include all images & movies", isOn: $preferences.includeAllMedia)
            Text("Index every image and video file, not just ones that look like screenshots.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding(20)
    }

    private var ocrDescription: String {
        switch preferences.ocrLevel {
        case .off:      return "OCR is disabled — only filenames and dates are searched."
        case .fast:     return "Fast OCR. Lower CPU, slightly less accurate on small or stylised text."
        case .accurate: return "Accurate OCR uses more CPU but handles small text and non-Latin scripts better."
        }
    }
}

// MARK: - Appearance

private struct AppearanceTab: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            Section("Panel Size") {
                HStack {
                    Text("Window")
                    Spacer()
                    Text("\(Int(preferences.panelSizeFraction * 100))%")
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $preferences.panelSizeFraction, in: 0.3...1.0, step: 0.05) {
                    Text("Panel size")
                } minimumValueLabel: {
                    Text("30%").font(.caption)
                } maximumValueLabel: {
                    Text("100%").font(.caption)
                }
                HStack(spacing: 8) {
                    Button("Compact")    { preferences.panelSizeFraction = 0.4 }
                    Button("Comfortable") { preferences.panelSizeFraction = 0.6 }
                    Button("Large")      { preferences.panelSizeFraction = 0.8 }
                    Button("Full")       { preferences.panelSizeFraction = 1.0 }
                }
                .buttonStyle(.bordered)

                Text("How much of the active screen the search panel takes up when you invoke the hotkey.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Preview Size") {
                HStack {
                    Text("Thumbnail")
                    Spacer()
                    Text("\(Int(preferences.thumbnailSize)) pt")
                        .monospaced()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $preferences.thumbnailSize, in: 160...720, step: 20) {
                    Text("Preview size")
                } minimumValueLabel: {
                    Text("S").font(.caption)
                } maximumValueLabel: {
                    Text("XL").font(.caption)
                }
                HStack(spacing: 8) {
                    Button("Small")  { preferences.thumbnailSize = 200 }
                    Button("Medium") { preferences.thumbnailSize = 280 }
                    Button("Large")  { preferences.thumbnailSize = 420 }
                    Button("XL")     { preferences.thumbnailSize = 600 }
                }
                .buttonStyle(.bordered)

                Text("Target width of each preview in the grid. Bigger previews mean fewer columns — independent of the panel size.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Shortcuts

private struct ShortcutsTab: View {
    @Bindable var preferences: Preferences

    var body: some View {
        Form {
            LabeledContent("Invoke hotkey") {
                KeyRecorderView(chord: $preferences.hotKey)
            }
            Text("Click, then press any chord — including Hyper (⌃⌥⇧⌘). ⎋ cancels, ⌫ clears.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("If a chord doesn't register, another tool (Karabiner, BetterTouchTool, Raycast) may have claimed it first. Unbind it there or pick a different chord.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Reset to ⌘⇧S") {
                    preferences.hotKey = .defaultInvoke
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Permissions

private struct PermissionsTab: View {
    let appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vista needs a few macOS permissions to work. Grant them here, or from System Settings → Privacy & Security.")
                .font(.callout)
                .foregroundStyle(.secondary)

            PermissionRow(
                title: "Accessibility",
                description: "Required to register the global hotkey.",
                openPane: "Privacy_Accessibility"
            )
            PermissionRow(
                title: "Full Disk Access",
                description: "Optional. Grant if you want to index folders outside of your home directory.",
                openPane: "Privacy_AllFiles"
            )
            PermissionRow(
                title: "Automation (System Events)",
                description: "Required for the ‘Paste to Front App’ action.",
                openPane: "Privacy_Automation"
            )

            Divider()
            HStack {
                Text("Indexed screenshots:")
                Spacer()
                Text("\(appState.indexedCount)")
                    .monospaced()
            }
            .font(.callout)

            Spacer()
        }
        .padding(20)
    }
}

private struct PermissionRow: View {
    let title: String
    let description: String
    let openPane: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(openPane)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
