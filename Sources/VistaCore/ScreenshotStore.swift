// ScreenshotStore.swift — SQLite-backed index with FTS5 full-text search.
//
// One file, two tables:
//   screenshots       — authoritative rows (one per file on disk)
//   screenshots_fts   — FTS5 virtual table mirroring name + ocr_text for search
//
// Why raw sqlite3 and not GRDB/SQLite.swift?
//   - Zero external deps keeps the DMG small and SPM resolve trivial.
//   - The schema is small and unlikely to grow; a thin wrapper pays for itself.
//
// Concurrency: all access is funnelled through a single serial dispatch
// queue (`queue`). SQLite is compiled with threadsafe=1 on macOS but the
// ergonomics of sharing a connection are easier if we just serialise.

import Foundation
import SQLite3

public final class ScreenshotStore: @unchecked Sendable {

    // sqlite3_stmt and the connection are POSIX handles — not Swift Sendable
    // by construction. We guard all use with `queue` and mark the class
    // @unchecked Sendable so it can cross actor boundaries safely.
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.gordonbeeming.vista.store")

    /// URL the connection was opened against. Exposed for diagnostics /
    /// "reveal in Finder" debug actions.
    public let databaseURL: URL

    // MARK: - Lifecycle

    /// Opens the default store at Application Support/Vista/index.sqlite.
    public static func openDefault() throws -> ScreenshotStore {
        let dir = try VistaPaths.applicationSupportDirectory()
        return try ScreenshotStore(url: dir.appendingPathComponent("index.sqlite"))
    }

    /// Opens or creates a store at an arbitrary URL. Used by tests against
    /// a temp directory.
    public init(url: URL) throws {
        self.databaseURL = url

        // SQLITE_OPEN_FULLMUTEX = the library serialises access internally,
        // giving us a belt to go with our dispatch-queue braces. The cost is
        // negligible on a single-writer workload like this one.
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            throw StoreError.open(code: rc, message: String(cString: sqlite3_errstr(rc)))
        }
        self.db = handle

        // WAL gives us concurrent read during writes — the indexer writes
        // while the UI reads. synchronous=NORMAL is the recommended pairing
        // for WAL and survives crashes without data loss.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=NORMAL;")
        try exec("PRAGMA foreign_keys=ON;")

        try migrate()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    // MARK: - Schema

    /// Bumped every time the schema changes; migrate() walks each delta.
    private static let currentSchemaVersion: Int32 = 1

    private func migrate() throws {
        let version = try readUserVersion()
        if version >= Self.currentSchemaVersion { return }

        try exec("""
            CREATE TABLE IF NOT EXISTS screenshots (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                path        TEXT    NOT NULL UNIQUE,
                name        TEXT    NOT NULL,
                captured_at REAL    NOT NULL,
                mtime       REAL    NOT NULL,
                size        INTEGER NOT NULL,
                width       INTEGER NOT NULL DEFAULT 0,
                height      INTEGER NOT NULL DEFAULT 0,
                ocr_text    TEXT,
                pinned      INTEGER NOT NULL DEFAULT 0,
                pinned_at   REAL
            );
        """)

        // FTS5 external-content table mirrors the rowid of `screenshots`
        // so JOINs are cheap. External content means the FTS table doesn't
        // store a copy of the data — it reads through to `screenshots` — and
        // we keep it in sync with triggers below.
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS screenshots_fts USING fts5(
                name,
                ocr_text,
                content='screenshots',
                content_rowid='id',
                tokenize='porter unicode61'
            );
        """)

        // FTS5 insists that the "old" values passed to the 'delete' command
        // match what's currently stored, or it throws SQLITE_CORRUPT. The
        // simplest way to guarantee that is to drive the sync from triggers
        // that run inside the same transaction as the base-table mutation —
        // this is the pattern the FTS5 docs recommend for external content.
        try exec("""
            CREATE TRIGGER IF NOT EXISTS screenshots_ai AFTER INSERT ON screenshots BEGIN
                INSERT INTO screenshots_fts(rowid, name, ocr_text)
                VALUES (new.id, new.name, COALESCE(new.ocr_text, ''));
            END;
        """)
        try exec("""
            CREATE TRIGGER IF NOT EXISTS screenshots_ad AFTER DELETE ON screenshots BEGIN
                INSERT INTO screenshots_fts(screenshots_fts, rowid, name, ocr_text)
                VALUES ('delete', old.id, old.name, COALESCE(old.ocr_text, ''));
            END;
        """)
        try exec("""
            CREATE TRIGGER IF NOT EXISTS screenshots_au AFTER UPDATE ON screenshots BEGIN
                INSERT INTO screenshots_fts(screenshots_fts, rowid, name, ocr_text)
                VALUES ('delete', old.id, old.name, COALESCE(old.ocr_text, ''));
                INSERT INTO screenshots_fts(rowid, name, ocr_text)
                VALUES (new.id, new.name, COALESCE(new.ocr_text, ''));
            END;
        """)

        try exec("CREATE INDEX IF NOT EXISTS idx_screenshots_captured_at ON screenshots(captured_at DESC);")
        try exec("CREATE INDEX IF NOT EXISTS idx_screenshots_pinned ON screenshots(pinned) WHERE pinned = 1;")

        try exec("PRAGMA user_version = \(Self.currentSchemaVersion);")
    }

    private func readUserVersion() throws -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else {
            throw lastError()
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Lookups used during incremental scan

    /// Tolerance applied when comparing a file's current mtime against
    /// the value we stored the last time we indexed it. Public so tests
    /// can pin behaviour to the same constant instead of re-declaring
    /// the magic number.
    public static let mtimeTolerance: TimeInterval = 0.001

    /// Whether the DB already holds an entry for `url` matching the given
    /// `(mtime, size)`. Mtime is compared with `mtimeTolerance` (1 ms) to
    /// survive the `Double` round-trip through SQLite's REAL column: at
    /// year-2026 timestamps (~1.78e9 s) one Double ULP is ~400 ns, which
    /// is coarser than APFS's ns-resolution mtime, so a Double can't
    /// represent every distinct APFS timestamp and exact equality
    /// sporadically fails. Before the tolerance, the indexer re-OCR'd a
    /// random ~37 % subset of rows on every relaunch. `size` is still
    /// compared exactly — a real edit almost always changes size, so the
    /// slack on mtime doesn't mask genuine changes.
    public func isAlreadyIndexed(at url: URL, mtime: Date, size: Int64) throws -> Bool {
        guard let existing = try fingerprint(for: url) else { return false }
        guard existing.size == size else { return false }
        let drift = abs(existing.mtime.timeIntervalSinceReferenceDate
                      - mtime.timeIntervalSinceReferenceDate)
        return drift <= Self.mtimeTolerance
    }

    /// Returns the (mtime, size) we last indexed for this path, or nil if
    /// unknown. Indexer uses this to skip unchanged files without reading
    /// pixels.
    public func fingerprint(for path: URL) throws -> (mtime: Date, size: Int64)? {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT mtime, size FROM screenshots WHERE path = ? LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, path.path, -1, Self.transient)
            let step = sqlite3_step(stmt)
            guard step == SQLITE_ROW else { return nil }
            let mtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            let size = sqlite3_column_int64(stmt, 1)
            return (mtime, size)
        }
    }

    public func pathsOnDisk() throws -> Set<String> {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT path FROM screenshots;", -1, &stmt, nil) == SQLITE_OK else {
                throw lastError()
            }
            defer { sqlite3_finalize(stmt) }
            var out = Set<String>()
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    out.insert(String(cString: cstr))
                }
            }
            return out
        }
    }

    // MARK: - Writes

    /// Inserts or replaces the row for `record` and syncs the FTS index.
    /// Returns the id that was written.
    @discardableResult
    public func upsert(_ record: ScreenshotRecord) throws -> Int64 {
        try queue.sync {
            try exec("BEGIN IMMEDIATE;")
            do {
                let id = try upsertLocked(record)
                try exec("COMMIT;")
                return id
            } catch {
                try? exec("ROLLBACK;")
                throw error
            }
        }
    }

    private func upsertLocked(_ record: ScreenshotRecord) throws -> Int64 {
        let sql = """
            INSERT INTO screenshots (path, name, captured_at, mtime, size, width, height, ocr_text, pinned, pinned_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(path) DO UPDATE SET
                name = excluded.name,
                captured_at = excluded.captured_at,
                mtime = excluded.mtime,
                size = excluded.size,
                width = excluded.width,
                height = excluded.height,
                ocr_text = excluded.ocr_text
            RETURNING id;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, record.path.path, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, record.name, -1, Self.transient)
        sqlite3_bind_double(stmt, 3, record.capturedAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 4, record.mtime.timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 5, record.size)
        sqlite3_bind_int(stmt, 6, Int32(record.width))
        sqlite3_bind_int(stmt, 7, Int32(record.height))
        if let ocr = record.ocrText {
            sqlite3_bind_text(stmt, 8, ocr, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        sqlite3_bind_int(stmt, 9, record.pinned ? 1 : 0)
        if let pinnedAt = record.pinnedAt {
            sqlite3_bind_double(stmt, 10, pinnedAt.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 10)
        }

        guard sqlite3_step(stmt) == SQLITE_ROW else { throw lastError() }
        // FTS sync is driven by the AFTER INSERT / AFTER UPDATE triggers
        // defined in migrate() — nothing to do here.
        return sqlite3_column_int64(stmt, 0)
    }

    public func delete(path: URL) throws {
        try queue.sync {
            // AFTER DELETE trigger keeps FTS in sync.
            try execWithBinds(
                "DELETE FROM screenshots WHERE path = ?;",
                binds: [.text(path.path)]
            )
        }
    }

    /// Storage Duration pruner. Removes unpinned rows whose captured_at
    /// predates `cutoff`. Pinned rows are never touched; neither are the
    /// underlying image files — we only drop the index entry.
    public func deleteUnpinned(olderThan cutoff: Date) throws {
        try queue.sync {
            try execWithBinds(
                "DELETE FROM screenshots WHERE pinned = 0 AND captured_at < ?;",
                binds: [.double(cutoff.timeIntervalSince1970)]
            )
        }
    }

    public func setPinned(id: Int64, pinned: Bool) throws {
        try queue.sync {
            try execWithBinds(
                "UPDATE screenshots SET pinned = ?, pinned_at = ? WHERE id = ?;",
                binds: [
                    .int64(pinned ? 1 : 0),
                    pinned ? .double(Date().timeIntervalSince1970) : .null,
                    .int64(id)
                ]
            )
        }
    }

    // MARK: - Reads

    public func count() throws -> Int {
        try queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM screenshots;", -1, &stmt, nil) == SQLITE_OK else {
                throw lastError()
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    /// Returns recently-captured records, newest first. Used as the default
    /// view when no query is typed.
    public func recent(limit: Int = 200) throws -> [ScreenshotRecord] {
        try queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT id, path, name, captured_at, mtime, size, width, height, ocr_text, pinned, pinned_at FROM screenshots ORDER BY captured_at DESC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))
            var out: [ScreenshotRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.row(from: stmt))
            }
            return out
        }
    }

    /// Runs a parsed `Query` and returns matching records. For Phase 1 this
    /// is a straightforward translation; in Phase 2 we'll add ranking via
    /// FTS5's bm25() for better relevance ordering.
    public func search(_ query: Query, limit: Int = 200) throws -> [ScreenshotRecord] {
        if query.isEmpty { return try recent(limit: limit) }

        return try queue.sync {
            // Build WHERE incrementally. For FTS conditions we go through a
            // CTE that joins on rowid, which keeps the query planner happy
            // and avoids correlated subqueries.
            var ftsMatch: String? = nil
            var nonFTSClauses: [String] = []
            var binds: [Bind] = []

            // Free text — match across both FTS columns.
            var ftsParts: [String] = []
            for term in query.freeTerms {
                ftsParts.append("(\"name\" : \(Self.ftsQuote(term)) OR \"ocr_text\" : \(Self.ftsQuote(term)))")
            }
            // name: / text: — column-scoped FTS.
            for term in query.nameTerms {
                ftsParts.append("(\"name\" : \(Self.ftsQuote(term)))")
            }
            for term in query.textTerms {
                ftsParts.append("(\"ocr_text\" : \(Self.ftsQuote(term)))")
            }
            if !ftsParts.isEmpty {
                ftsMatch = ftsParts.joined(separator: " AND ")
            }

            for range in query.dateRanges {
                // Half-open on both ends so a record at exactly the upper
                // bound (next day's midnight) belongs to the next bucket,
                // and one at the lower bound belongs to this one.
                nonFTSClauses.append("captured_at >= ? AND captured_at < ?")
                binds.append(.double(range.lowerBound.timeIntervalSince1970))
                binds.append(.double(range.upperBound.timeIntervalSince1970))
            }

            var sql = "SELECT s.id, s.path, s.name, s.captured_at, s.mtime, s.size, s.width, s.height, s.ocr_text, s.pinned, s.pinned_at FROM screenshots s"
            if let ftsMatch {
                sql += " JOIN screenshots_fts f ON f.rowid = s.id"
                sql += " WHERE f.screenshots_fts MATCH ?"
                binds.insert(.text(ftsMatch), at: 0)
                if !nonFTSClauses.isEmpty {
                    sql += " AND " + nonFTSClauses.joined(separator: " AND ")
                }
            } else if !nonFTSClauses.isEmpty {
                sql += " WHERE " + nonFTSClauses.joined(separator: " AND ")
            }
            sql += " ORDER BY s.captured_at DESC LIMIT ?;"
            binds.append(.int64(Int64(limit)))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
            defer { sqlite3_finalize(stmt) }
            try bind(stmt: stmt, values: binds)

            var out: [ScreenshotRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(Self.row(from: stmt))
            }
            return out
        }
    }

    // MARK: - Helpers

    private enum Bind {
        case text(String)
        case int64(Int64)
        case double(Double)
        case null
    }

    private func bind(stmt: OpaquePointer?, values: [Bind]) throws {
        for (i, v) in values.enumerated() {
            let index = Int32(i + 1)
            switch v {
            case .text(let s):   sqlite3_bind_text(stmt, index, s, -1, Self.transient)
            case .int64(let n):  sqlite3_bind_int64(stmt, index, n)
            case .double(let d): sqlite3_bind_double(stmt, index, d)
            case .null:          sqlite3_bind_null(stmt, index)
            }
        }
    }

    private func execWithBinds(_ sql: String, binds: [Bind]) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw lastError() }
        defer { sqlite3_finalize(stmt) }
        try bind(stmt: stmt, values: binds)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw lastError() }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.exec(code: rc, message: msg, sql: sql)
        }
    }

    private func lastError() -> StoreError {
        let code = sqlite3_errcode(db)
        let msg = String(cString: sqlite3_errmsg(db))
        return StoreError.exec(code: code, message: msg, sql: "")
    }

    /// SQLite wants to know whether the bound string buffer is transient
    /// (will be freed after bind returns) or static. Our Swift Strings are
    /// bridged and may be deallocated — so SQLITE_TRANSIENT makes sqlite
    /// take its own copy. The C constant is `-1` cast to a function pointer.
    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1),
        to: sqlite3_destructor_type.self
    )

    /// FTS5 treats `"` as the column-scope quote; we wrap user terms in
    /// double quotes after escaping internal quotes so punctuation doesn't
    /// accidentally invoke operator syntax (MATCH, NEAR, etc).
    private static func ftsQuote(_ term: String) -> String {
        let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func row(from stmt: OpaquePointer?) -> ScreenshotRecord {
        let id = sqlite3_column_int64(stmt, 0)
        let path = URL(fileURLWithPath: String(cString: sqlite3_column_text(stmt, 1)))
        let name = String(cString: sqlite3_column_text(stmt, 2))
        let capturedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
        let mtime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
        let size = sqlite3_column_int64(stmt, 5)
        let width = Int(sqlite3_column_int(stmt, 6))
        let height = Int(sqlite3_column_int(stmt, 7))
        let ocr: String? = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? nil
            : String(cString: sqlite3_column_text(stmt, 8))
        let pinned = sqlite3_column_int(stmt, 9) != 0
        let pinnedAt: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL
            ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
        return ScreenshotRecord(
            id: id, path: path, name: name,
            capturedAt: capturedAt, mtime: mtime, size: size,
            width: width, height: height, ocrText: ocr,
            pinned: pinned, pinnedAt: pinnedAt
        )
    }

    public enum StoreError: Error, CustomStringConvertible {
        case open(code: Int32, message: String)
        case exec(code: Int32, message: String, sql: String)

        public var description: String {
            switch self {
            case .open(let code, let msg):
                return "ScreenshotStore open failed (\(code)): \(msg)"
            case .exec(let code, let msg, let sql):
                return "ScreenshotStore exec failed (\(code)): \(msg) — SQL: \(sql)"
            }
        }
    }
}
