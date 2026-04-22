// PanelContentView.swift — The SwiftUI contents of the floating panel.
//
// Layout mirrors Raycast's search-screenshots command:
//   - Top row: search field + "Source" dropdown (stub for Phase 2; the
//     dropdown just picks "All" until multi-folder support lands).
//   - Grid of thumbnails with captions, auto-flowing to fill width.
//   - Bottom bar: current primary action + "Actions" trigger (⌘K, stub).
//
// Keyboard handling:
//   - Arrow keys move selection
//   - Enter runs primary action
//   - Esc dismisses the panel (handled at the panel level, not here)
//   - ⌘P pin/unpin
//   - ⌘⇧C copy OCR text

import SwiftUI
import VistaCore

struct PanelContentView: View {
    @Bindable var model: SearchViewModel
    let thumbnails: ThumbnailCache
    let actions: ActionHandlers
    let dismiss: () -> Void

    // Drives keyboard focus so the search field is live the moment the
    // panel appears — users shouldn't have to click to start typing.
    @FocusState private var searchFocused: Bool

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
        .onKeyPress { press in handleKey(press) }
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
                Text("Drop a screenshot onto your Desktop — vista will pick it up in a few seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsGrid: some View {
        ScrollView {
            // adaptive grid — columns re-flow when the user resizes the
            // panel (panel size preference is Phase 3).
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 16)],
                spacing: 16
            ) {
                ForEach(Array(model.results.enumerated()), id: \.element.id) { index, record in
                    ResultCell(
                        record: record,
                        isSelected: index == model.selectedIndex,
                        thumbnails: thumbnails
                    )
                    .onTapGesture {
                        model.selectedIndex = index
                        runPrimary()
                    }
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "camera.viewfinder")
            Text("Vista")
                .fontWeight(.medium)
            Spacer()
            HStack(spacing: 6) {
                Text("Copy to Clipboard")
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

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .downArrow:
            model.moveSelection(by: 1)
            return .handled
        case .upArrow:
            model.moveSelection(by: -1)
            return .handled
        case .return:
            runPrimary()
            return .handled
        case .escape:
            dismiss()
            return .handled
        default:
            // ⌘P pin, ⌘⇧C copy OCR
            if press.modifiers.contains(.command) {
                if press.characters == "p" {
                    if let rec = model.selectedRecord {
                        actions.run(.togglePin, on: rec)
                        model.reload()
                    }
                    return .handled
                }
                if press.modifiers.contains(.shift), press.characters.lowercased() == "c" {
                    if let rec = model.selectedRecord {
                        actions.run(.copyOCRText, on: rec)
                    }
                    return .handled
                }
            }
            return .ignored
        }
    }

    private func runPrimary() {
        guard let record = model.selectedRecord else { return }
        // Phase 2 hard-codes "Copy to Clipboard" as the primary action.
        // Phase 3 will read this from preferences.
        actions.run(.copyImage, on: record)
        dismiss()
    }
}

// MARK: - Result cell

private struct ResultCell: View {
    let record: ScreenshotRecord
    let isSelected: Bool
    let thumbnails: ThumbnailCache

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
        .task(id: record.id) {
            // Load in a detached task so scroll-past doesn't block on
            // thumbnail generation.
            let loaded = await Task.detached(priority: .userInitiated) { [record] in
                try? thumbnails.thumbnail(for: record.path, size: .medium, sourceMtime: record.mtime)
            }.value
            self.image = loaded
        }
    }

    /// Relative-date caption matching the "Today at 14:27" style Raycast uses.
    private static func caption(for record: ScreenshotRecord) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return record.capturedAt.timeAgoStyle()
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
