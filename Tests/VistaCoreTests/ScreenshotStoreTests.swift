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
