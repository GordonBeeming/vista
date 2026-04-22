// ActionHandlers.swift — What every row-action in the panel actually does.
//
// Phase 2 ships the core set plus pinning. "Paste to front app" is stubbed
// to a Copy for now — it needs accessibility / AppleScript bridging that
// lands properly in Phase 3 alongside the permissions plumbing.

import AppKit
import VistaCore

/// The menu of actions the user can run against a selected screenshot.
/// Order matters — this is the canonical order used in the ⌘K panel.
public enum RowAction: String, CaseIterable, Identifiable, Sendable {
    case open
    case copyImage
    case pasteToFrontApp
    case showInFinder
    case copyFilePath
    case copyOCRText
    case togglePin
    case moveToTrash

    public var id: String { rawValue }

    /// Label shown in the action list. Matches Raycast wording where
    /// possible so the muscle memory transfers.
    public var label: String {
        switch self {
        case .open:             return "Open"
        case .copyImage:        return "Copy to Clipboard"
        case .pasteToFrontApp:  return "Paste to Front App"
        case .showInFinder:     return "Show in Finder"
        case .copyFilePath:     return "Copy File Path"
        case .copyOCRText:      return "Copy OCR Text"
        case .togglePin:        return "Pin / Unpin"
        case .moveToTrash:      return "Move to Trash"
        }
    }
}

@MainActor
public final class ActionHandlers {

    private let store: ScreenshotStore

    public init(store: ScreenshotStore) {
        self.store = store
    }

    /// Runs `action` against `record`. Some actions mutate the store
    /// (pin, trash) — callers should re-query afterwards to refresh the
    /// grid.
    public func run(_ action: RowAction, on record: ScreenshotRecord) {
        switch action {
        case .open:
            NSWorkspace.shared.open(record.path)
        case .copyImage:
            copyImage(at: record.path)
        case .pasteToFrontApp:
            // Phase 3 wires AppleScript keystrokes into the front app.
            // Until then, copy-and-document so the flow is still useful.
            copyImage(at: record.path)
        case .showInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([record.path])
        case .copyFilePath:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.path.path, forType: .string)
        case .copyOCRText:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(record.ocrText ?? "", forType: .string)
        case .togglePin:
            try? store.setPinned(id: record.id, pinned: !record.pinned)
        case .moveToTrash:
            try? FileManager.default.trashItem(at: record.path, resultingItemURL: nil)
            // The FSEvents delete watcher will remove the store row.
        }
    }

    /// Copies both a file-URL reference and the raw image bytes to the
    /// pasteboard. The URL form lets other apps (Finder, mail composers)
    /// recognise it as a file; the image form lets chat apps paste it as
    /// an inline image without a round-trip through the filesystem.
    private func copyImage(at url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        if let image = NSImage(contentsOf: url) {
            pb.writeObjects([image])
        }
    }
}
