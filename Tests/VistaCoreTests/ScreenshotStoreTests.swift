// ScreenshotStoreTests.swift — Covers schema, upsert, FTS search, pinning.

import XCTest
@testable import VistaCore

final class ScreenshotStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: ScreenshotStore!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vista-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = try ScreenshotStore(url: tempDir.appendingPathComponent("index.sqlite"))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Basic CRUD

    func testEmptyStoreHasZeroCount() throws {
        XCTAssertEqual(try store.count(), 0)
    }

    func testUpsertInsertsNewRow() throws {
        let record = Self.sampleRecord(name: "Screenshot 1.png", text: "hello world")
        try store.upsert(record)
        XCTAssertEqual(try store.count(), 1)

        let recent = try store.recent()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].name, "Screenshot 1.png")
        XCTAssertEqual(recent[0].ocrText, "hello world")
    }

    func testUpsertReplacesExistingPath() throws {
        let path = Self.sampleURL(name: "Same.png")
        try store.upsert(Self.sampleRecord(path: path, text: "first"))
        try store.upsert(Self.sampleRecord(path: path, text: "second"))
        XCTAssertEqual(try store.count(), 1)
        XCTAssertEqual(try store.recent()[0].ocrText, "second")
    }

    func testDeleteRemovesRowAndFTS() throws {
        let path = Self.sampleURL(name: "Gone.png")
        try store.upsert(Self.sampleRecord(path: path, text: "unique-token"))
        XCTAssertEqual(try store.count(), 1)

        try store.delete(path: path)
        XCTAssertEqual(try store.count(), 0)

        let results = try store.search(QueryParser.parse("unique-token"))
        XCTAssertTrue(results.isEmpty)
    }

    // MARK: - Search

    func testFreeTermMatchesOCRText() throws {
        try store.upsert(Self.sampleRecord(name: "A.png", text: "the invoice is overdue"))
        try store.upsert(Self.sampleRecord(name: "B.png", text: "reminder: standup at nine"))

        let results = try store.search(QueryParser.parse("invoice"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "A.png")
    }

    func testFreeTermMatchesFilename() throws {
        try store.upsert(Self.sampleRecord(name: "Chrome login form.png", text: ""))
        try store.upsert(Self.sampleRecord(name: "Unrelated.png", text: ""))

        let results = try store.search(QueryParser.parse("chrome"))
        XCTAssertEqual(results.count, 1)
    }

    func testNamePrefixIgnoresOCR() throws {
        try store.upsert(Self.sampleRecord(name: "chrome.png", text: "zzz"))
        try store.upsert(Self.sampleRecord(name: "other.png", text: "chrome appears here"))

        let results = try store.search(QueryParser.parse("name:chrome"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "chrome.png")
    }

    func testTextPrefixIgnoresFilename() throws {
        try store.upsert(Self.sampleRecord(name: "chrome.png", text: "zzz"))
        try store.upsert(Self.sampleRecord(name: "other.png", text: "chrome lives inside"))

        let results = try store.search(QueryParser.parse("text:chrome"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "other.png")
    }

    func testDateRangeFilter() throws {
        let jan = Date(timeIntervalSince1970: 1_704_067_200) // 2024-01-01
        let mar = Date(timeIntervalSince1970: 1_709_251_200) // 2024-03-01
        try store.upsert(Self.sampleRecord(name: "Jan.png", capturedAt: jan, text: "w"))
        try store.upsert(Self.sampleRecord(name: "Mar.png", capturedAt: mar, text: "w"))

        let results = try store.search(QueryParser.parse("date:2024-03"))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "Mar.png")
    }

    // MARK: - Keyset pagination

    // Walk every page of `recent()` via the (captured_at, id) cursor and
    // assert we see each row exactly once, newest-first, with no dupes or
    // gaps — including a tie where two rows share a captured_at (the `id`
    // tiebreaker is what keeps that pair from being skipped or repeated).
    func testRecentPaginatesWithoutDupesOrGaps() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 25 rows on distinct timestamps + 2 sharing one timestamp = 27.
        for i in 0..<25 {
            try store.upsert(Self.sampleRecord(name: "S\(i).png",
                                               capturedAt: base.addingTimeInterval(Double(i)),
                                               text: "t"))
        }
        let tie = base.addingTimeInterval(100)
        try store.upsert(Self.sampleRecord(name: "TieA.png", capturedAt: tie, text: "t"))
        try store.upsert(Self.sampleRecord(name: "TieB.png", capturedAt: tie, text: "t"))

        var seen: [Int64] = []
        var cursor: ScreenshotStore.Cursor? = nil
        let pageSize = 10
        while true {
            let page = try store.recent(limit: pageSize, after: cursor)
            seen.append(contentsOf: page.map(\.id))
            guard let last = page.last, page.count == pageSize else { break }
            cursor = ScreenshotStore.Cursor(capturedAt: last.capturedAt.timeIntervalSince1970, id: last.id)
        }

        XCTAssertEqual(seen.count, 27)
        XCTAssertEqual(Set(seen).count, 27, "no row should appear twice across pages")
        // Page-stitched order must match a single unbounded fetch.
        let oneShot = try store.recent(limit: 1000).map(\.id)
        XCTAssertEqual(seen, oneShot)
    }

    // The cursor also has to thread through the FTS/date WHERE chain in
    // `search()` — paginating a filtered result set, not just `recent()`.
    func testSearchPaginatesWithCursor() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<15 {
            try store.upsert(Self.sampleRecord(name: "Match\(i).png",
                                               capturedAt: base.addingTimeInterval(Double(i)),
                                               text: "needle"))
        }
        try store.upsert(Self.sampleRecord(name: "Other.png", capturedAt: base, text: "haystack"))

        let query = QueryParser.parse("needle")
        let firstPage = try store.search(query, limit: 10)
        XCTAssertEqual(firstPage.count, 10)
        let cursor = ScreenshotStore.Cursor(
            capturedAt: firstPage.last!.capturedAt.timeIntervalSince1970,
            id: firstPage.last!.id)
        let secondPage = try store.search(query, limit: 10, after: cursor)

        let combined = (firstPage + secondPage).map(\.id)
        XCTAssertEqual(combined.count, 15, "only the 15 needle rows, no haystack leak")
        XCTAssertEqual(Set(combined).count, 15)
    }

    // MARK: - Pinning

    func testPinSetsFlag() throws {
        try store.upsert(Self.sampleRecord(name: "A.png", text: "t"))
        let record = try store.recent()[0]
        try store.setPinned(id: record.id, pinned: true)
        let refreshed = try store.recent()[0]
        XCTAssertTrue(refreshed.pinned)
        XCTAssertNotNil(refreshed.pinnedAt)
    }

    // MARK: - Fingerprint (skip-unchanged guard)

    func testFingerprintReturnsLastKnown() throws {
        let path = Self.sampleURL(name: "Fp.png")
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(Self.sampleRecord(path: path, mtime: mtime, size: 1234, text: "x"))

        let fp = try store.fingerprint(for: path)
        XCTAssertEqual(fp?.size, 1234)
        XCTAssertEqual(fp?.mtime.timeIntervalSince1970 ?? 0,
                       mtime.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testFingerprintUnknownPathReturnsNil() throws {
        XCTAssertNil(try store.fingerprint(for: Self.sampleURL(name: "never-seen.png")))
    }

    // Regression: exact `Date == Date` after a round-trip through the REAL
    // `mtime` column used to fail sporadically because a Double ULP at
    // 2026 timestamps (~400 ns) is coarser than APFS's 1 ns mtime
    // resolution — so a `Double` can't represent every distinct APFS
    // timestamp. `isAlreadyIndexed` applies `ScreenshotStore.mtimeTolerance`
    // (1 ms) so high-precision fractional mtimes still match after the
    // round-trip.
    func testIsAlreadyIndexedSurvivesDoublePrecisionRoundTrip() throws {
        let path = Self.sampleURL(name: "Drift.png")
        // Fractional seconds chosen so `.timeIntervalSince1970` can't be
        // represented exactly as a Double — that's the shape filesystem
        // mtimes actually have on APFS.
        let mtime = Date(timeIntervalSince1970: 1_776_864_366.2835145)
        let size: Int64 = 42_630
        try store.upsert(Self.sampleRecord(path: path, mtime: mtime, size: size, text: ""))

        XCTAssertTrue(try store.isAlreadyIndexed(at: path, mtime: mtime, size: size))
        XCTAssertFalse(try store.isAlreadyIndexed(at: path, mtime: mtime, size: size + 1))
        XCTAssertFalse(try store.isAlreadyIndexed(at: Self.sampleURL(name: "nope.png"),
                                                  mtime: mtime, size: size))

        // Drift outside the tolerance window is treated as "changed". The
        // epsilon (10 × tolerance) is deliberately well beyond the ~400 ns
        // Double-round-trip slop so the assertion is deterministic across
        // fractional mtime values.
        let beyondTol = mtime.addingTimeInterval(ScreenshotStore.mtimeTolerance * 10)
        XCTAssertFalse(try store.isAlreadyIndexed(at: path, mtime: beyondTol, size: size))
    }

    // MARK: - Helpers

    private static func sampleURL(name: String) -> URL {
        URL(fileURLWithPath: "/tmp/\(name)")
    }

    private static func sampleRecord(
        path: URL? = nil,
        name: String = "Screenshot.png",
        capturedAt: Date = Date(),
        mtime: Date = Date(),
        size: Int64 = 1000,
        text: String = ""
    ) -> ScreenshotRecord {
        ScreenshotRecord(
            path: path ?? sampleURL(name: name),
            name: name,
            capturedAt: capturedAt,
            mtime: mtime,
            size: size,
            ocrText: text
        )
    }
}
