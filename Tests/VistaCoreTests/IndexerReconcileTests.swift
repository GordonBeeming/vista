// IndexerReconcileTests.swift — Guards the "never wipe on a bad scan" rule.
//
// These cover the pure decision helper behind the data-loss fix: a folder
// we couldn't read (or that came back empty while we still hold rows for it)
// must never cause deletions. Instead it's reported as access-blocked and
// the index is left intact.

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

        XCTAssertTrue(result.delete.isEmpty, "no rows should be deleted for an unreadable folder")
        XCTAssertEqual(result.blockedRoots, [root])
    }

    // The fresh-install / iCloud-not-materialised case: the folder reads as
    // "accessible" but returns zero files while we still hold rows for it.
    // The circuit breaker treats this as blocked, not empty.
    func testEmptyScanWhileKnownRowsExistTripsBreaker() {
        let known: Set<String> = [path("a.png"), path("b.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: [])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.delete.isEmpty, "an empty scan must not wipe a populated index")
        XCTAssertEqual(result.blockedRoots, [root])
    }

    // A genuinely-deleted file (root readable, file no longer discovered)
    // is the one case where deletion is correct.
    func testReadableRootDeletesOnlyTrulyMissingFiles() {
        let known: Set<String> = [path("a.png"), path("b.png"), path("gone.png")]
        let discovered: Set<String> = [path("a.png"), path("b.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: discovered)]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertEqual(result.delete, [path("gone.png")])
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }

    // Everything still on disk → nothing to do.
    func testReadableRootWithEverythingPresentDeletesNothing() {
        let known: Set<String> = [path("a.png"), path("b.png")]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: known)]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.delete.isEmpty)
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }

    // An unreadable folder we hold no rows for isn't a problem to surface —
    // there's no data at risk, so it's neither deleted-from nor blocked.
    func testInaccessibleRootWithNoKnownRowsIsNotBlocked() {
        let known: Set<String> = ["/Users/test/other/x.png"]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: false, discoveredPaths: [])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.delete.isEmpty)
        XCTAssertTrue(result.blockedRoots.isEmpty, "no rows under the folder means nothing to warn about")
    }

    // Rows not under any watched root are left alone here — removing a
    // watched folder reconciles through updateWatchedFolders, not this path.
    func testRowsOutsideAnyWatchedRootAreLeftAlone() {
        let known: Set<String> = [path("a.png"), "/Users/test/elsewhere/orphan.png"]
        let roots = [Indexer.RootScanResult(rootPath: root, accessible: true, discoveredPaths: [path("a.png")])]

        let result = Indexer.reconcileDeletions(known: known, roots: roots)

        XCTAssertTrue(result.delete.isEmpty, "orphans outside the watched root aren't this function's job")
        XCTAssertTrue(result.blockedRoots.isEmpty)
    }
}
