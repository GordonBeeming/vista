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

// Every view in this file touches `Preferences` (MainActor-isolated), so
// pin them all to MainActor explicitly. Swift 6.x infers this for SwiftUI
// views; Swift 5.10 (the toolchain on macos-14 runners) does not, and the
// compile fails with "main actor-isolated property cannot be referenced
// from a non-isolated context" on helpers like `addFolder()` and on
// computed properties that read `preferences.*`.
@MainActor
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
        case .folders:     FoldersTab(preferences: preferences, appState: appState)
        case .search:      SearchTab(preferences: preferences)
        case .appearance:  AppearanceTab(preferences: preferences)
        case .shortcuts:   ShortcutsTab(preferences: preferences)
        case .permissions: PermissionsTab(appState: appState)
        }
    }
}

// MARK: - General

@MainActor
private struct GeneralTab: View {
    @Bindable var preferences: Preferences
    let appState: AppState

    var body: some View {
        Form {
            Toggle("Launch at login", isOn: $preferences.launchAtLogin)
            Toggle("Pause indexing", isOn: .init(
                get: { appState.isPaused },
                set: { appState.setPaused($0) }
            ))
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

// MARK: - Behaviour

@MainActor
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

@MainActor
private struct FoldersTab: View {
    @Bindable var preferences: Preferences
    let appState: AppState

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
                Button("Rescan Now") { appState.rescanNow() }
                    .help("Re-walk every watched folder from scratch — useful after adding a new folder, or to pick up anything FSEvents might have missed.")
                Spacer()
                Button("Add Folder…") { addFolder() }
                    .controlSize(.large)
            }

            // Live count so the user can confirm the scan actually picked
            // files up after adding a folder.
            Text("Indexed screenshots: \(appState.indexedCount)")
                .font(.caption)
                .foregroundStyle(.secondary)

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

@MainActor
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

@MainActor
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

@MainActor
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

@MainActor
private struct PermissionsTab: View {
    let appState: AppState

    /// Refreshed on appear and whenever the user grants / opens settings.
    /// Kept in state so the green/grey chip updates without a relaunch.
    @State private var automationState: PermissionProbe.State = .unknown
    @State private var fdaState: PermissionProbe.State = .unknown

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vista only needs one macOS permission — and only if you use Paste to Front App. Everything else runs without extra grants.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            AutomationRow(
                state: automationState,
                onGrant: {
                    // NSAppleScript path — definitely triggers the
                    // macOS Automation prompt (and registers vista in
                    // Privacy → Automation). Re-reads the state after
                    // the user responds.
                    automationState = PermissionProbe.requestAutomationForSystemEvents()
                },
                onOpenSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                        NSWorkspace.shared.open(url)
                    }
                }
            )

            OptionalFullDiskRow(
                state: fdaState,
                onOpenSettings: {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
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
        .onAppear {
            automationState = PermissionProbe.automationForSystemEvents()
            fdaState = PermissionProbe.fullDiskAccess()
        }
    }
}

private struct AutomationRow: View {
    let state: PermissionProbe.State
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state.symbol)
                .foregroundStyle(state == .granted ? .green : state == .denied ? .red : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Paste to Front App").bold()
                    Text(state.label)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .separatorColor).opacity(0.4))
                        .clipShape(Capsule())
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if state == .granted {
                Button("Open Settings", action: onOpenSettings)
            } else if state == .denied {
                Button("Open Settings", action: onOpenSettings)
            } else {
                Button("Grant", action: onGrant)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hint: String {
        switch state {
        case .granted:
            return "Vista can send a Cmd+V to the frontmost app when you pick Paste to Front App. You're all set."
        case .denied:
            return "Automation is denied in System Settings. Toggle it back on if you want Paste to Front App to work."
        case .notDetermined:
            return "Needed only for Paste to Front App. Clicking Grant triggers a one-time macOS prompt — you can revoke anytime."
        case .unknown:
            return "Couldn't read the current state. Open System Settings → Privacy → Automation to check."
        }
    }
}

private struct OptionalFullDiskRow: View {
    let state: PermissionProbe.State
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "externaldrive.badge.checkmark")
                .foregroundStyle(state == .granted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Full Disk Access").bold()
                    Text(badge)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(nsColor: .separatorColor).opacity(0.4))
                        .clipShape(Capsule())
                }
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("Open Settings", action: onOpenSettings)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var badge: String {
        switch state {
        case .granted: return "Granted · Optional"
        case .denied, .notDetermined, .unknown: return "Optional"
        }
    }

    private var hint: String {
        switch state {
        case .granted:
            return "Full Disk Access is on — vista can index protected locations. You don't need this unless you want to, since folders added via Folders already work via security-scoped bookmarks."
        case .denied, .notDetermined, .unknown:
            return "Not required. Folders you add with the Folders tab work via security-scoped bookmarks without any system-wide grant. Enable Full Disk Access only if you want vista to index protected locations it otherwise can't read."
        }
    }
}
