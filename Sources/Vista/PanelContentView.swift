// PanelContentView.swift — The SwiftUI contents of the floating panel.
//
// Layout mirrors Raycast's search-screenshots command:
//   - Top row: search field + "Source" dropdown (stub for Phase 2; the
//     dropdown just picks "All" until multi-folder support lands).
//   - Grid of thumbnails with captions, auto-flowing to fill width.
//   - Bottom bar: current primary action + "Actions" trigger (⌘K, stub).
//
// Keyboard handling:
//   - Left / Right move selection by ±1 (same row)
//   - Up / Down move selection by ±columnCount (same column, adjacent row)
//   - Enter runs primary action, Esc dismisses, ⌘P pins, ⌘⇧C copies OCR
//
// All arrow handling goes through a window-scoped NSEvent local monitor,
// not SwiftUI's .onKeyPress — the search field (always focused) would
// otherwise consume Left/Right for cursor movement and swallow the
// events before any SwiftUI handler saw them. The monitor lives only
// while the panel is on screen.

import SwiftUI
import AppKit
import Carbon.HIToolbox
import VistaCore

@MainActor
struct PanelContentView: View {
    @Bindable var model: SearchViewModel
    let thumbnails: ThumbnailCache
    let actions: ActionHandlers
    let preferences: Preferences
    let dismiss: () -> Void

    // Drives keyboard focus so the search field is live the moment the
    // panel appears — users shouldn't have to click to start typing.
    @FocusState private var searchFocused: Bool

    // Columns currently rendered by the LazyVGrid. Recomputed whenever
    // the grid's width or the preview-size preference changes, and
    // consumed by the arrow-key handler for up/down row jumps.
    @State private var columnCount: Int = 1

    // Token for the NSEvent local monitor. Installed while the panel is
    // visible; removed on disappear so it doesn't leak and so it doesn't
    // keep intercepting events when the panel is hidden.
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if model.results.isEmpty {
                emptyState
            } else {
                resultsGrid
            }
            Divider()
            footer
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    // MARK: - Sections

    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Filter screenshots by name:, text: or date:…", text: $model.queryText)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($searchFocused)
                .onAppear { searchFocused = true }
            // Source dropdown — Phase 3 wires it to the folder list.
            Menu("Images") {
                Text("All").tag("all")
            }
            .menuStyle(.button)
            .frame(width: 120)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.queryText.isEmpty ? "No screenshots indexed yet" : "No matches")
                .font(.headline)
                .foregroundStyle(.secondary)
            if model.queryText.isEmpty {
                Text(emptyStateHint)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hint text for the empty state. Picks the most relevant folder to
    /// name — a user-added folder if one exists, otherwise the system
    /// default if it's being watched, otherwise tells the user to add one.
    private var emptyStateHint: String {
        if let firstUserFolder = preferences.watchedFolders.first {
            let name = (firstUserFolder.displayPath as NSString).lastPathComponent
            return "Drop a screenshot into \(name) — vista will pick it up in a few seconds."
        }
        if preferences.watchDefaultFolder {
            let name = VistaPaths.defaultScreenshotFolder().lastPathComponent
            return "Drop a screenshot into \(name) — vista will pick it up in a few seconds."
        }
        return "No folders are being watched. Open Preferences → Folders to add one."
    }

    private var resultsGrid: some View {
        // Preview-size preference drives both the grid columns (minimum
        // width per thumb) and the NSImage size we pull from the cache
        // (so a user asking for 500pt previews gets the 1024-px cached
        // thumbnail, not an upscaled 512-px one).
        let target = preferences.thumbnailSize
        let thumbCacheSize: ThumbnailCache.Size = target > 380 ? .large : target > 180 ? .medium : .small
        let spacing: CGFloat = 16
        return GeometryReader { proxy in
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: target, maximum: target * 1.6), spacing: spacing)],
                        spacing: spacing
                    ) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, record in
                            ResultCell(
                                record: record,
                                isSelected: index == model.selectedIndex,
                                thumbnails: thumbnails,
                                thumbSize: thumbCacheSize
                            )
                            .onTapGesture {
                                model.selectedIndex = index
                                runPrimary()
                            }
                        }
                    }
                    .padding(spacing)
                }
                // Keep the selected cell visible as arrow-key nav moves the
                // border off-screen. `anchor: nil` is a bring-into-view —
                // cells already visible don't move, so stepping within a
                // row doesn't jitter the scroll.
                .onChange(of: model.selectedIndex) { _, newIndex in
                    guard model.results.indices.contains(newIndex) else { return }
                    let targetID = model.results[newIndex].id
                    withAnimation(.easeInOut(duration: 0.15)) {
                        scrollProxy.scrollTo(targetID, anchor: nil)
                    }
                }
                // Keep columnCount in sync with the actual layout. The formula
                // mirrors what LazyVGrid.adaptive does internally: pick the
                // largest N where N*minCol + (N-1)*spacing ≤ usableWidth.
                .onAppear {
                    columnCount = Self.columnsFor(
                        width: proxy.size.width,
                        target: target,
                        spacing: spacing
                    )
                }
                .onChange(of: proxy.size.width) { _, newWidth in
                    columnCount = Self.columnsFor(
                        width: newWidth,
                        target: target,
                        spacing: spacing
                    )
                }
                .onChange(of: target) { _, newTarget in
                    columnCount = Self.columnsFor(
                        width: proxy.size.width,
                        target: newTarget,
                        spacing: spacing
                    )
                }
            }
        }
    }

    private static func columnsFor(width: CGFloat, target: Double, spacing: CGFloat) -> Int {
        let usable = max(1, width - spacing * 2)  // subtract the grid's own padding
        let count = Int(floor((usable + spacing) / (CGFloat(target) + spacing)))
        return max(1, count)
    }

    private var footer: some View {
        HStack {
            Image(systemName: "camera.viewfinder")
            Text("Vista")
                .fontWeight(.medium)
            // Build badge → opens the release page (or commit) on GitHub.
            // Subtle so it doesn't pull focus from the primary-action hint
            // on the right; still clickable for anyone who wants the notes.
            if let url = BuildInfo.releaseOrCommitURL {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(BuildInfo.footerBadge)
                            .monospaced()
                        Image(systemName: "arrow.up.forward.square")
                            .imageScale(.small)
                    }
                    .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Open release notes on GitHub")
            }
            Spacer()
            HStack(spacing: 6) {
                Text(preferences.primaryAction.label)
                Image(systemName: "return")
                    .foregroundStyle(.secondary)
            }
            Divider().frame(height: 12)
            HStack(spacing: 6) {
                Text("Actions")
                Text("⌘K")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Keyboard

    /// Installs an NSEvent local monitor so arrow keys and shortcuts
    /// reach grid navigation even while the TextField is focused. The
    /// TextField would otherwise consume Left/Right for cursor movement
    /// and the grid would appear non-interactive — `.onKeyPress` on
    /// ancestor views doesn't preempt the focused responder.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handlePanelKey(event)
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Returns the event unchanged when we don't want to handle it —
    /// that's how the TextField still receives characters to type. Returns
    /// nil to swallow (arrow keys, Enter, Esc, our ⌘-chords).
    private func handlePanelKey(_ event: NSEvent) -> NSEvent? {
        // Only act on events delivered to our panel window. Otherwise a
        // user typing in another app's textbox while the panel is hidden-
        // but-alive would have their keys eaten.
        guard event.window?.identifier == nil || event.window === NSApp.keyWindow else {
            return event
        }

        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch Int(event.keyCode) {
        case kVK_LeftArrow:
            model.moveSelection(by: -1)
            return nil
        case kVK_RightArrow:
            model.moveSelection(by: 1)
            return nil
        case kVK_UpArrow:
            model.moveSelection(by: -columnCount)
            return nil
        case kVK_DownArrow:
            model.moveSelection(by: columnCount)
            return nil
        case kVK_Return:
            runPrimary()
            return nil
        case kVK_Escape:
            dismiss()
            return nil
        default:
            break
        }

        // ⌘P → pin toggle; ⌘⇧C → copy OCR text.
        if mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if chars == "p", !mods.contains(.shift) {
                if let rec = model.selectedRecord {
                    actions.run(.togglePin, on: rec)
                    model.reload()
                }
                return nil
            }
            if chars == "c", mods.contains(.shift) {
                if let rec = model.selectedRecord {
                    actions.run(.copyOCRText, on: rec)
                }
                return nil
            }
        }

        return event
    }

    private func runPrimary() {
        guard let record = model.selectedRecord else { return }
        actions.run(preferences.primaryAction.rowAction, on: record)
        dismiss()
    }
}

// MARK: - Result cell

@MainActor
private struct ResultCell: View {
    let record: ScreenshotRecord
    let isSelected: Bool
    let thumbnails: ThumbnailCache
    let thumbSize: ThumbnailCache.Size

    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .aspectRatio(16.0/10.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
            )
            if record.pinned {
                HStack(spacing: 4) {
                    Image(systemName: "pin.fill").foregroundStyle(.yellow)
                    Text(ResultCell.caption(for: record))
                }
                .font(.caption)
            } else {
                Text(ResultCell.caption(for: record))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(record.id)-\(thumbSize.rawValue)") {
            // Load in a detached task so scroll-past doesn't block on
            // thumbnail generation. Re-fires when thumbSize changes so the
            // preview-size slider takes effect without a reload.
            let loaded = await Task.detached(priority: .userInitiated) { [record, thumbSize] in
                try? thumbnails.thumbnail(
                    for: record.path,
                    size: thumbSize,
                    sourceMtime: record.mtime,
                    sourceSize: record.size
                )
            }.value
            self.image = loaded
        }
    }

    /// Relative-date caption matching the "Today at 14:27" style Raycast uses.
    private static func caption(for record: ScreenshotRecord) -> String {
        record.capturedAt.timeAgoStyle()
    }
}

private extension Date {
    /// "Today at 14:27" / "Yesterday at 09:12" / "Fri at 11:05" /
    /// "12 Apr at 16:40" — picks the most human-feeling form.
    func timeAgoStyle() -> String {
        let cal = Calendar.current
        let time = DateFormatter.vistaTime.string(from: self)
        if cal.isDateInToday(self) {
            return "Today at \(time)"
        }
        if cal.isDateInYesterday(self) {
            return "Yesterday at \(time)"
        }
        let daysAgo = cal.dateComponents([.day], from: self, to: Date()).day ?? 0
        if daysAgo >= 0, daysAgo < 7 {
            let weekday = DateFormatter.vistaWeekday.string(from: self)
            return "\(weekday) at \(time)"
        }
        return "\(DateFormatter.vistaDate.string(from: self)) at \(time)"
    }
}

private extension DateFormatter {
    static let vistaTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let vistaWeekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    static let vistaDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
}
