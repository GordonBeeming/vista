// IndexerReconcileTests.swift — Guards the "never wipe on a bad scan" rule.
//
// These cover the pure decision helper behind the data-loss fix: a folder
// we couldn't read (or that came back empty while we still hold rows for it)
// must never cause deletions. Orphans from unwatched folders are cleaned up,
// but only when the watched-root set is trustworthy.

import XCTest
@testable import VistaCore

final class IndexerReconcileTests: XCTestCase {

    private let root = "/Users/test/screenshots"
    private func path(_ name: String) -> String { "\(root)/\(name)" }

    // A folder that failed to enumerate (missing, not a dir, permission
    // denied) never deletes the rows we hold for it — it's reported blocked.
    func testInaccessibleRootDeletesNothingAndIsBlocked() {
        let known: Set<String> = [path("a.png"), path("b.png"), path("c.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: false, discoveredPaths: [])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.deleteMissing.isEmpty, "no rows should be deleted for an unreadable folder")
        XCTAssertTrue(result.deleteOrphans.isEmpty)
        XCTAssertEqual(result.blockedRoots, [root])
    }

    // The fresh-install / iCloud-not-materialised case: the folder reads as
    // "accessible" but returns zero files while we still hold rows for it.
    // The circuit breaker treats this as blocked, not empty.
    func testEmptyScanWhileKnownRowsExistTripsBreaker() {
        let known: Set<String> = [path("a.png"), path("b.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: [])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.deleteMissing.isEmpty, "an empty scan must not wipe a populated index")
        XCTAssertTrue(result.deleteOrphans.isEmpty)
        XCTAssertEqual(result.blockedRoots, [root])
    }

    // A genuinely-deleted file (root readable, file no longer discovered)
    // is the one case where missing-file deletion is correct.
    func testReadableRootDeletesOnlyTrulyMissingFiles() {
        let known: Set<String> = [path("a.png"), path("b.png"), path("gone.png")]
        let discovered: Set<String> = [path("a.png"), path("b.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: discovered)]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertEqual(result.deleteMissing, [path("gone.png")])
        XCTAssertTrue(result.deleteOrphans.isEmpty)
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }

    // Everything still on disk → nothing to do.
    func testReadableRootWithEverythingPresentDeletesNothing() {
        let known: Set<String> = [path("a.png"), path("b.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: known)]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.deleteMissing.isEmpty)
        XCTAssertTrue(result.deleteOrphans.isEmpty)
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }

    // An unreadable folder we hold no rows for isn't a problem to surface —
    // there's no data at risk, so it's neither deleted-from nor blocked.
    func testInaccessibleRootWithNoKnownRowsIsNotBlocked() {
        let known: Set<String> = ["/Users/test/other/x.png"]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: false, discoveredPaths: [])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        // The /other/ path is an orphan, but with no accessible root we don't
        // trust the "orphan" conclusion, so nothing is deleted.
        XCTAssertTrue(result.deleteMissing.isEmpty)
        XCTAssertTrue(result.deleteOrphans.isEmpty)
        XCTAssertTrue(result.blockedRoots.isEmpty, "no rows under the folder means nothing to warn about")
    }

    // Rows not under any watched root are orphans from an unwatched folder.
    // With a readable root present, they're cleaned up unconditionally — the
    // files still exist on disk, so the fileExists guard alone wouldn't.
    func testRowsOutsideAnyWatchedRootAreReturnedAsOrphans() {
        let known: Set<String> = [path("a.png"), "/Users/test/elsewhere/orphan.png"]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: [path("a.png")])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.deleteMissing.isEmpty)
        XCTAssertEqual(result.deleteOrphans, ["/Users/test/elsewhere/orphan.png"])
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }

    // The orphan-wipe guard: if NO root was accessible, an apparently-orphan
    // path might just mean the watched-folder list failed to load. Preserve
    // everything rather than deleting on an untrustworthy root set.
    func testOrphansPreservedWhenNoAccessibleRoot() {
        let known: Set<String> = [path("a.png"), "/Users/test/elsewhere/orphan.png"]
        // Only an inaccessible root in the set → don't trust orphan status.
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: false, discoveredPaths: [])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.deleteOrphans.isEmpty, "no accessible root means we can't trust 'orphan'")
        XCTAssertTrue(result.deleteMissing.isEmpty)
        XCTAssertEqual(result.blockedRoots, [root], "the inaccessible root still holds a row → blocked")
    }

    // Empty root set (folder list failed to resolve) must never wipe.
    func testEmptyRootSetDeletesNothing() {
        let known: Set<String> = [path("a.png"), path("b.png")]

        let result = Indexer.reconcileDeletions(known: known, roots: [])

        XCTAssertTrue(result.deleteMissing.isEmpty)
        XCTAssertTrue(result.deleteOrphans.isEmpty, "with no roots at all, every row would look orphaned — preserve")
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }
}
