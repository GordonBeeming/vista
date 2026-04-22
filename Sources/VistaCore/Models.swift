// Models.swift — Value types shared across VistaCore.
//
// ScreenshotRecord is the canonical row the store hands back; Query is the
// parsed form of a user's search string, ready to be compiled into SQL.

import Foundation

/// One screenshot that vista knows about.
///
/// The store treats these as immutable: to update OCR text or pin state we
/// issue dedicated UPDATE statements and let callers re-fetch.
public struct ScreenshotRecord: Equatable, Sendable, Identifiable {
    /// Stable row id from SQLite. Zero for records that haven't been
    /// persisted yet.
    public var id: Int64

    /// Absolute path to the file on disk.
    public var path: URL

    /// Just the filename, derived from `path`. Stored separately so FTS5
    /// can tokenise it independently of the OCR body.
    public var name: String

    /// When the screenshot was taken. Prefer the file's creation date; fall
    /// back to mtime. Parsed in Indexer on insert.
    public var capturedAt: Date

    /// Filesystem mtime at index time. Used as the incremental-scan key
    /// together with `size`.
    public var mtime: Date

    /// File size in bytes at index time.
    public var size: Int64

    /// Pixel dimensions. Zero means "not yet measured" — we fill them in
    /// when the thumbnail is generated.
    public var width: Int
    public var height: Int

    /// Extracted text from Vision OCR. Empty string means "OCR ran and
    /// found nothing"; nil means "OCR has not run yet". FTS5 table only
    /// indexes the non-nil case.
    public var ocrText: String?

    /// User-pinned flag. Pinned records are excluded from Storage Duration
    /// pruning and appear in a dedicated section at the top of the grid.
    public var pinned: Bool

    /// When the user pinned this, or nil if never pinned.
    public var pinnedAt: Date?

    public init(
        id: Int64 = 0,
        path: URL,
        name: String? = nil,
        capturedAt: Date,
        mtime: Date,
        size: Int64,
        width: Int = 0,
        height: Int = 0,
        ocrText: String? = nil,
        pinned: Bool = false,
        pinnedAt: Date? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name ?? path.lastPathComponent
        self.capturedAt = capturedAt
        self.mtime = mtime
        self.size = size
        self.width = width
        self.height = height
        self.ocrText = ocrText
        self.pinned = pinned
        self.pinnedAt = pinnedAt
    }
}

/// Parsed representation of a user's search string.
///
/// The parser splits the raw string into these prefix-scoped bits plus a
/// free-text residue; the store compiles them back into a WHERE clause.
public struct Query: Equatable, Sendable {
    /// Terms that should match against the filename (the `name:` prefix).
    public var nameTerms: [String]

    /// Terms that should match against OCR text (the `text:` prefix).
    public var textTerms: [String]

    /// Parsed date clauses (the `date:` prefix). Half-open so records
    /// with sub-second `captured_at` timestamps at the very end of a day
    /// (e.g. 23:59:59.5) aren't excluded by an inclusive-upper bound like
    /// 23:59:59 exactly. The store compiles these with `>= lower AND < upper`.
    public var dateRanges: [Range<Date>]

    /// Bare terms — match either name OR ocr_text via FTS5.
    public var freeTerms: [String]

    public init(
        nameTerms: [String] = [],
        textTerms: [String] = [],
        dateRanges: [Range<Date>] = [],
        freeTerms: [String] = []
    ) {
        self.nameTerms = nameTerms
        self.textTerms = textTerms
        self.dateRanges = dateRanges
        self.freeTerms = freeTerms
    }

    /// True when the query would match every row — lets the UI skip a
    /// database hit and just show the "no filter" grid.
    public var isEmpty: Bool {
        nameTerms.isEmpty && textTerms.isEmpty && dateRanges.isEmpty && freeTerms.isEmpty
    }
}
