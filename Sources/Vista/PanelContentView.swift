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

    // Shift+Space opens a large preview of the selected screenshot. Esc
    // closes the preview first (leaving the panel up); a second Esc
    // dismisses the panel.
    @State private var previewVisible: Bool = false

    // ⌘K opens a Raycast-style actions popover anchored to the footer's
    // "Actions ⌘K" hint. Esc cascade also closes this before the panel.
    @State private var actionsVisible: Bool = false

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
        .overlay {
            if previewVisible, let record = model.selectedRecord {
                PreviewOverlay(
                    record: record,
                    thumbnails: thumbnails,
                    close: { previewVisible = false }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: previewVisible)
        // Drop the preview if the selection list empties out (e.g. the
        // user typed a query that no longer matches anything). Otherwise
        // we'd be stuck showing the overlay with no record behind it.
        .onChange(of: model.selectedRecord == nil) { _, gone in
            if gone {
                previewVisible = false
                actionsVisible = false
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear {
            removeKeyMonitor()
            previewVisible = false
            actionsVisible = false
        }
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
                            // Double-click before single so the single
                            // handler doesn't also fire on a double: double
                            // copies + dismisses (same as Enter), single just
                            // moves the selection and leaves the panel up.
                            .onTapGesture(count: 2) {
                                model.selectedIndex = index
                                runPrimary()
                            }
                            .onTapGesture(count: 1) {
                                model.selectedIndex = index
                            }
                            // Infinite scroll: when the trailing cell scrolls
                            // into view, page in the next batch. LazyVGrid only
                            // realizes (and fires onAppear for) cells near the
                            // viewport, so this fires once the user nears the
                            // bottom of what's loaded.
                            .onAppear {
                                if record.id == model.results.last?.id {
                                    model.loadMore()
                                }
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
            Button {
                if model.selectedRecord != nil { actionsVisible.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Actions")
                    Text("⌘K")
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .disabled(model.selectedRecord == nil)
            .popover(isPresented: $actionsVisible, arrowEdge: .top) {
                if let record = model.selectedRecord {
                    ActionsPopover(
                        record: record,
                        preferences: preferences,
                        run: { action in
                            actionsVisible = false
                            actions.run(action, on: record)
                            // Pin and trash mutate the store — reload so
                            // the grid reflects the change immediately.
                            if action == .togglePin || action == .moveToTrash {
                                model.reload()
                            } else if action != .copyFilePath, action != .copyOCRText {
                                // Most actions are terminal — dismiss the
                                // panel afterwards, same as Enter. The two
                                // clipboard-text actions stay open since
                                // users typically copy then keep browsing.
                                dismiss()
                            }
                        }
                    )
                }
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
            // Cascade: close transient overlays first, only dismiss the
            // panel once nothing else is on top. Lets users peek or open
            // the actions menu without losing their place in the grid.
            if actionsVisible {
                actionsVisible = false
            } else if previewVisible {
                previewVisible = false
            } else {
                dismiss()
            }
            return nil
        case kVK_Space:
            // Shift+Space toggles the large preview. Plain space falls
            // through to the search field so multi-word queries
            // (`text:hello world`) still work. Strict equality on `mods`
            // would fail when capsLock or function-key state bits ride
            // along, so test the relevant modifiers individually.
            let shiftOnly = mods.contains(.shift)
                && !mods.contains(.command)
                && !mods.contains(.option)
                && !mods.contains(.control)
            if shiftOnly, model.selectedRecord != nil {
                previewVisible.toggle()
                return nil
            }
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
            // ⌘K toggles the actions popover. Mirrors the footer hint and
            // matches Raycast muscle memory for the same shortcut. Pass
            // the event through when there's nothing selected — swallowing
            // it would turn ⌘K into a dead key on empty result lists and
            // block any future global binding from seeing it.
            if chars == "k", !mods.contains(.shift) {
                guard model.selectedRecord != nil else { return event }
                actionsVisible.toggle()
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

// MARK: - Preview overlay

/// Quick Look-style large preview triggered by Shift+Space. Sized to
/// ~85% of the panel area so the surrounding grid is still visible at
/// the edges, reinforcing that the panel is still up and arrow keys
/// will swap the previewed record.
@MainActor
private struct PreviewOverlay: View {
    let record: ScreenshotRecord
    let thumbnails: ThumbnailCache
    let close: () -> Void

    @State private var image: NSImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Dimmed scrim — tap anywhere outside the card to close.
                Color.black.opacity(0.45)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)

                card
                    .frame(
                        width: geo.size.width * 0.85,
                        height: geo.size.height * 0.85
                    )
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // Re-load when arrow keys change the selected record while the
        // overlay is open. `task(id:)` cancels its own body when id
        // changes, but `Task.detached` is unstructured and keeps running
        // even after cancellation — without the isCancelled check below,
        // a slow load from the previous record can land after a faster
        // load for the new one and briefly show the wrong screenshot.
        .task(id: record.id) {
            let loaded = await Task.detached(priority: .userInitiated) { [record] in
                try? thumbnails.thumbnail(
                    for: record.path,
                    size: .large,
                    sourceMtime: record.mtime,
                    sourceSize: record.size
                )
            }.value
            guard !Task.isCancelled else { return }
            self.image = loaded
        }
    }

    private var card: some View {
        HStack(spacing: 0) {
            imagePane
            Divider()
            metadataPane
                .frame(width: 280)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    private var imagePane: some View {
        ZStack {
            Color.black.opacity(0.25)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var metadataPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 8) {
                if record.pinned {
                    Image(systemName: "pin.fill")
                        .foregroundStyle(.yellow)
                        .padding(.top, 2)
                }
                Text(record.name)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(record.capturedAt.timeAgoStyle(), systemImage: "calendar")
                Label(Self.byteFormatter.string(fromByteCount: record.size), systemImage: "internaldrive")
                if record.width > 0, record.height > 0 {
                    Label("\(record.width) × \(record.height)", systemImage: "ruler")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            Divider()

            Text("Text in screenshot")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            ocrSnippet

            Spacer(minLength: 0)

            HStack {
                Spacer()
                Button(action: close) {
                    Label("Close", systemImage: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var ocrSnippet: some View {
        if let text = record.ocrText {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                Text("No text detected")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .italic()
            } else {
                ScrollView {
                    Text(trimmed)
                        .font(.callout)
                        .monospaced()
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("OCR still running…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()
}

// MARK: - Actions popover

/// Raycast-style action list anchored to the footer's ⌘K hint. Lists
/// every `RowAction` in its canonical order, with the panel-internal
/// shortcuts shown on the right so users can learn them by looking.
@MainActor
private struct ActionsPopover: View {
    let record: ScreenshotRecord
    let preferences: Preferences
    let run: (RowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Actions")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(RowAction.allCases) { action in
                Button {
                    run(action)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: Self.icon(for: action))
                            .frame(width: 16)
                            .foregroundStyle(.secondary)
                        Text(label(for: action))
                            .foregroundStyle(.primary)
                        Spacer()
                        let hints = shortcuts(for: action)
                        if !hints.isEmpty {
                            Text(hints.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospaced()
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 8)
        }
        .frame(width: 280)
    }

    /// Pinned records flip the "Pin / Unpin" label to whichever action
    /// the click will actually perform — clearer than always showing both.
    private func label(for action: RowAction) -> String {
        if action == .togglePin {
            return record.pinned ? "Unpin" : "Pin"
        }
        return action.label
    }

    /// Shortcuts wired up in `handlePanelKey`. Showing only the ones that
    /// actually work avoids promising bindings that don't exist. Returns
    /// a list because some actions have two bindings at once — e.g. when
    /// the user's primary action is Copy OCR Text, both ↵ and ⌘⇧C fire it,
    /// and hiding either hint would misrepresent the live bindings.
    private func shortcuts(for action: RowAction) -> [String] {
        var hints: [String] = []
        if action == preferences.primaryAction.rowAction { hints.append("↵") }
        switch action {
        case .togglePin:    hints.append("⌘P")
        case .copyOCRText:  hints.append("⌘⇧C")
        default:            break
        }
        return hints
    }

    private static func icon(for action: RowAction) -> String {
        switch action {
        case .open:             return "arrow.up.right.square"
        case .copyImage:        return "doc.on.clipboard"
        case .pasteToFrontApp:  return "arrow.down.doc"
        case .showInFinder:     return "folder"
        case .copyFilePath:     return "link"
        case .copyOCRText:      return "text.quote"
        case .togglePin:        return "pin"
        case .moveToTrash:      return "trash"
        }
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
