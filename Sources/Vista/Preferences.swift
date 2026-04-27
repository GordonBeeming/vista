// Preferences.swift — User-visible settings with persistence.
//
// Single source of truth for every value the settings UI mutates. Views
// bind to @Observable properties; changes are written through to
// UserDefaults (or, for folder bookmarks, a JSON file in Application
// Support). Downstream components (AppState, Indexer, HotKeyManager,
// FloatingPanel) observe this via async streams or KVO-ish didSet hooks.

import Foundation
import Observation
import AppKit
import VistaCore

/// Options for the "press Enter on a result" behaviour. Matches Raycast's
/// Primary Action dropdown exactly so muscle memory transfers.
public enum PrimaryAction: String, CaseIterable, Identifiable, Sendable, Codable {
    case copyImage
    case pasteToFrontApp
    case open
    case showInFinder
    case copyOCRText

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .copyImage:       return "Copy to Clipboard"
        case .pasteToFrontApp: return "Paste to Front App"
        case .open:            return "Open Image"
        case .showInFinder:    return "Show in Finder"
        case .copyOCRText:     return "Copy OCR Text"
        }
    }

    /// Maps the user-visible choice to the RowAction the ActionHandlers
    /// already understands. Identity mapping today, but kept as a function
    /// so we can diverge later (e.g. different defaults per context).
    public var rowAction: RowAction {
        switch self {
        case .copyImage:       return .copyImage
        case .pasteToFrontApp: return .pasteToFrontApp
        case .open:            return .open
        case .showInFinder:    return .showInFinder
        case .copyOCRText:     return .copyOCRText
        }
    }
}

/// Storage Duration options. Matches Raycast's dropdown values.
public enum StorageDuration: String, CaseIterable, Identifiable, Sendable, Codable {
    case unlimited
    case oneWeek
    case oneMonth
    case threeMonths
    case sixMonths
    case oneYear

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .unlimited:    return "Unlimited"
        case .oneWeek:      return "1 week"
        case .oneMonth:     return "1 month"
        case .threeMonths:  return "3 months"
        case .sixMonths:    return "6 months"
        case .oneYear:      return "1 year"
        }
    }

    /// Seconds to keep. nil = never prune.
    public var seconds: TimeInterval? {
        switch self {
        case .unlimited:   return nil
        case .oneWeek:     return 60 * 60 * 24 * 7
        case .oneMonth:    return 60 * 60 * 24 * 30
        case .threeMonths: return 60 * 60 * 24 * 91
        case .sixMonths:   return 60 * 60 * 24 * 182
        case .oneYear:     return 60 * 60 * 24 * 365
        }
    }
}

/// How long the panel must be hidden before reopening it resets the
/// search query, scroll position, and selection. "Resume where I left
/// off" only feels right inside a single train-of-thought; come back an
/// hour later and a stale query is friction, not a feature.
public enum PanelResetTimeout: String, CaseIterable, Identifiable, Sendable, Codable {
    case never
    case thirtySeconds
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case tenMinutes

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .never:          return "Never"
        case .thirtySeconds:  return "30 seconds"
        case .oneMinute:      return "1 minute"
        case .twoMinutes:     return "2 minutes"
        case .fiveMinutes:    return "5 minutes"
        case .tenMinutes:     return "10 minutes"
        }
    }

    /// Hidden-duration threshold above which the panel resets on next
    /// show. nil = never reset.
    public var seconds: TimeInterval? {
        switch self {
        case .never:         return nil
        case .thirtySeconds: return 30
        case .oneMinute:     return 60
        case .twoMinutes:    return 120
        case .fiveMinutes:   return 300
        case .tenMinutes:    return 600
        }
    }
}

/// A persistent, security-scoped reference to a folder the user added.
/// The bookmark is what survives app restarts — re-resolving it yields
/// back a URL we're allowed to read even in a hardened-runtime build.
public struct WatchedFolder: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var displayPath: String
    public var bookmark: Data

    public init(id: UUID = UUID(), displayPath: String, bookmark: Data) {
        self.id = id
        self.displayPath = displayPath
        self.bookmark = bookmark
    }

    /// Resolves the bookmark back to a URL and (if requested) starts a
    /// security-scoped access session. Returns nil if the bookmark went
    /// stale (folder deleted, renamed, etc).
    public func resolve(startAccess: Bool = true) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        if startAccess {
            _ = url.startAccessingSecurityScopedResource()
        }
        return url
    }
}

@Observable
@MainActor
public final class Preferences {
    // MARK: - Keys

    private enum Key {
        static let hotKeyCode = "vista.hotKey.keyCode"
        static let hotKeyModifiers = "vista.hotKey.modifiers"
        static let panelSizeFraction = "vista.panel.sizeFraction"
        static let thumbnailSize = "vista.panel.thumbnailSize"
        static let ocrLevel = "vista.ocr.level"
        static let ocrLanguages = "vista.ocr.languages"
        static let primaryAction = "vista.primaryAction"
        static let includeAllMedia = "vista.includeAllMedia"
        static let storageDuration = "vista.storageDuration"
        static let launchAtLogin = "vista.launchAtLogin"
        static let watchDefaultFolder = "vista.watchDefaultFolder"
        static let panelResetTimeout = "vista.panelResetTimeout"
    }

    private let defaults: UserDefaults

    // MARK: - Simple scalar prefs (persist via didSet)

    public var hotKey: HotKeyChord {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(hotKey.modifiers), forKey: Key.hotKeyModifiers)
            emitChange(.hotKey)
        }
    }

    public var panelSizeFraction: Double {
        didSet {
            let clamped = min(1.0, max(0.3, panelSizeFraction))
            if clamped != panelSizeFraction {
                // Using the stored property inside didSet would loop —
                // write straight to defaults and fix the in-memory value
                // on the next runloop tick.
                defaults.set(clamped, forKey: Key.panelSizeFraction)
                DispatchQueue.main.async { [weak self] in self?.panelSizeFraction = clamped }
                return
            }
            defaults.set(panelSizeFraction, forKey: Key.panelSizeFraction)
            emitChange(.panelSize)
        }
    }

    /// Target width (in points) for each thumbnail in the results grid.
    /// The grid uses this as the minimum column width; columns may grow
    /// up to ~1.6× to absorb leftover horizontal space, so bigger values
    /// mean fewer, larger previews.
    public var thumbnailSize: Double {
        didSet {
            let clamped = min(720, max(160, thumbnailSize))
            if clamped != thumbnailSize {
                defaults.set(clamped, forKey: Key.thumbnailSize)
                DispatchQueue.main.async { [weak self] in self?.thumbnailSize = clamped }
                return
            }
            defaults.set(thumbnailSize, forKey: Key.thumbnailSize)
            emitChange(.panelSize)
        }
    }

    public var ocrLevel: OCRRecognizer.Level {
        didSet {
            defaults.set(ocrLevel.rawValueForStorage, forKey: Key.ocrLevel)
            emitChange(.ocr)
        }
    }

    public var ocrLanguages: [String] {
        didSet {
            defaults.set(ocrLanguages, forKey: Key.ocrLanguages)
            emitChange(.ocr)
        }
    }

    public var primaryAction: PrimaryAction {
        didSet {
            defaults.set(primaryAction.rawValue, forKey: Key.primaryAction)
            emitChange(.primaryAction)
        }
    }

    public var includeAllMedia: Bool {
        didSet {
            defaults.set(includeAllMedia, forKey: Key.includeAllMedia)
            emitChange(.folders)
        }
    }

    public var storageDuration: StorageDuration {
        didSet {
            defaults.set(storageDuration.rawValue, forKey: Key.storageDuration)
            emitChange(.storageDuration)
        }
    }

    public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            emitChange(.launchAtLogin)
        }
    }

    /// Whether to include the macOS system screenshot folder in the watch
    /// list. Some users (like anyone whose screenshots go to iCloud Drive
    /// via Cmd+Shift+5 "Save to") don't actually want the OS default
    /// watched — it's usually ~/Desktop and holds unrelated files.
    public var watchDefaultFolder: Bool {
        didSet {
            defaults.set(watchDefaultFolder, forKey: Key.watchDefaultFolder)
            emitChange(.folders)
        }
    }

    /// How long the panel can stay hidden before its query/selection are
    /// reset on next show. Read on demand by PanelController; no
    /// downstream observers need to react, so we don't emit a change.
    public var panelResetTimeout: PanelResetTimeout {
        didSet {
            defaults.set(panelResetTimeout.rawValue, forKey: Key.panelResetTimeout)
        }
    }

    // MARK: - Watched folders (bookmark-backed)

    /// Folders the indexer will watch. Mutated through the add/remove
    /// helpers below so the bookmark file stays in sync.
    public private(set) var watchedFolders: [WatchedFolder]

    private let bookmarksURL: URL

    /// Resolves the system-default folder (if enabled) plus every
    /// user-added folder. Tries the security-scoped bookmark first, then
    /// falls back to the stored plain path — vista runs unsandboxed, so
    /// the path alone is enough to read the folder without any scoped
    /// access. The fallback matters for:
    ///   - ad-hoc-signed dev builds (each rebuild invalidates prior
    ///     bookmarks because the code signature changes),
    ///   - anyone whose bookmark has gone stale after an OS upgrade or
    ///     folder move/rename.
    public func resolvedFolders() -> [URL] {
        var out: [URL] = []
        if watchDefaultFolder {
            out.append(VistaPaths.defaultScreenshotFolder())
        }
        for folder in watchedFolders {
            let url: URL
            if let bookmarked = folder.resolve(startAccess: true) {
                url = bookmarked
            } else {
                VistaLog.log("bookmark resolve failed for \(folder.displayPath) — falling back to plain path (unsandboxed so no scope needed)")
                url = URL(fileURLWithPath: folder.displayPath, isDirectory: true)
            }
            if !out.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
                out.append(url)
            }
        }
        return out
    }

    public func addFolder(_ url: URL) {
        // Security-scoped bookmarks are the only way to re-open a
        // user-granted folder across app launches in a hardened-runtime
        // build. Without the withSecurityScope option macOS hands back a
        // URL that can't be read from.
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else {
            NSLog("vista: could not create bookmark for \(url.path)")
            return
        }
        let folder = WatchedFolder(displayPath: url.path, bookmark: data)
        watchedFolders.append(folder)
        persistFolders()
        emitChange(.folders)
    }

    public func removeFolder(id: UUID) {
        watchedFolders.removeAll { $0.id == id }
        persistFolders()
        emitChange(.folders)
    }

    private func persistFolders() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(watchedFolders)
            try data.write(to: bookmarksURL, options: .atomic)
        } catch {
            NSLog("vista: failed to persist watched folders: \(error)")
        }
    }

    // MARK: - Change notifications

    public enum Change: Sendable {
        case hotKey
        case panelSize
        case ocr
        case primaryAction
        case folders
        case storageDuration
        case launchAtLogin
    }

    private var changeContinuation: AsyncStream<Change>.Continuation?
    public let changes: AsyncStream<Change>

    private func emitChange(_ change: Change) {
        changeContinuation?.yield(change)
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Bootstrap scalars. First launch falls back to sensible defaults;
        // subsequent launches restore the user's choices.
        let keyCode = defaults.object(forKey: Key.hotKeyCode) as? Int
        let mods = defaults.object(forKey: Key.hotKeyModifiers) as? Int
        if let keyCode, let mods {
            self.hotKey = HotKeyChord(keyCode: UInt32(keyCode), modifiers: UInt32(mods))
        } else {
            self.hotKey = .defaultInvoke
        }

        let frac = defaults.object(forKey: Key.panelSizeFraction) as? Double
        self.panelSizeFraction = frac ?? 0.6

        let thumb = defaults.object(forKey: Key.thumbnailSize) as? Double
        // 280 pt is roughly the Raycast default — big enough that window
        // text is legible without an eye squint, small enough that you
        // get four or five columns at Comfortable panel width.
        self.thumbnailSize = thumb ?? 280

        let levelRaw = defaults.string(forKey: Key.ocrLevel) ?? "fast"
        self.ocrLevel = OCRRecognizer.Level(storageRawValue: levelRaw) ?? .fast

        let langs = defaults.stringArray(forKey: Key.ocrLanguages)
        self.ocrLanguages = langs ?? []

        let actionRaw = defaults.string(forKey: Key.primaryAction) ?? PrimaryAction.copyImage.rawValue
        self.primaryAction = PrimaryAction(rawValue: actionRaw) ?? .copyImage

        self.includeAllMedia = defaults.object(forKey: Key.includeAllMedia) as? Bool ?? false

        let durationRaw = defaults.string(forKey: Key.storageDuration) ?? StorageDuration.unlimited.rawValue
        self.storageDuration = StorageDuration(rawValue: durationRaw) ?? .unlimited

        self.launchAtLogin = defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false

        // Default to ON — matches Raycast behaviour and means fresh installs
        // "just work" without requiring a folder to be added first.
        self.watchDefaultFolder = defaults.object(forKey: Key.watchDefaultFolder) as? Bool ?? true

        let resetRaw = defaults.string(forKey: Key.panelResetTimeout) ?? PanelResetTimeout.twoMinutes.rawValue
        self.panelResetTimeout = PanelResetTimeout(rawValue: resetRaw) ?? .twoMinutes

        // Watched folders live in a JSON file so we can store bookmark
        // data cleanly. Application Support is the right location —
        // survives upgrades, not subject to cache eviction.
        let appSupport = (try? VistaPaths.applicationSupportDirectory())
            ?? FileManager.default.homeDirectoryForCurrentUser
        self.bookmarksURL = appSupport.appendingPathComponent("watched_folders.json")

        if let data = try? Data(contentsOf: bookmarksURL),
           let decoded = try? JSONDecoder().decode([WatchedFolder].self, from: data) {
            self.watchedFolders = decoded
        } else {
            self.watchedFolders = []
        }

        var cont: AsyncStream<Change>.Continuation!
        self.changes = AsyncStream { cont = $0 }
        self.changeContinuation = cont
    }
}

// Local extensions so OCRRecognizer.Level can round-trip through
// UserDefaults without needing a conformance in VistaCore itself.
private extension OCRRecognizer.Level {
    var rawValueForStorage: String {
        switch self {
        case .off:      return "off"
        case .fast:     return "fast"
        case .accurate: return "accurate"
        }
    }

    init?(storageRawValue raw: String) {
        switch raw {
        case "off":      self = .off
        case "fast":     self = .fast
        case "accurate": self = .accurate
        default:         return nil
        }
    }
}
