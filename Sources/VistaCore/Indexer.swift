// Indexer.swift — Orchestrates folder watching, OCR, and persistence.
//
// Lifecycle:
//   1. start() — initial scan of every watched folder, then begin watching
//   2. FSEvents fires → enqueue path → OCR → upsert
//   3. setPaused(true) pauses dequeue; watching continues so we don't miss events
//   4. stop() cancels everything
//
// Designed as a single long-lived object that the app holds for its
// lifetime. Progress updates stream through `progressUpdates`.

import Foundation

public actor Indexer {

    public enum Progress: Sendable, Equatable {
        /// No work running, no recent activity.
        case idle
        /// Walking watched folders, filtering to already-indexed vs new
        /// via the mtime+size fingerprint. Fast; there's no meaningful
        /// progress signal other than "scanning N folders".
        case enumerating(folders: Int)
        /// OCR queue. `done` / `total` is new files (files we actually
        /// need to read + OCR), not all files on disk. A relaunch with
        /// a fresh DB might show total=4762; the next relaunch with the
        /// DB populated typically shows total=0 → we skip straight to
        /// `.watching`. `indexed` is the live total row count so the UI
        /// can show how many are already searchable while OCR catches up.
        case indexing(done: Int, total: Int, indexed: Int)
        /// Live-watching mode. `indexed` is the current total row count
        /// so the UI can render "1,234 screenshots indexed".
        case watching(indexed: Int)
    }

    private let store: ScreenshotStore
    // Mutable so preferences can swap in a new recognizer when the user
    // changes OCR level / languages without restarting the app.
    private var ocr: OCRRecognizer
    private var watchedFolders: [URL]
    private let watcher = FSEventsWatcher()

    private var isPaused = false
    private var isStarted = false
    // Pending work is a growing list plus an index cursor. `removeFirst`
    // on a Swift Array is O(n), which becomes quadratic under a burst of
    // filesystem events. Advancing an index is O(1); we compact the list
    // periodically once the cursor has moved far enough to be worth
    // reclaiming memory.
    private var pendingPaths: [URL] = []
    private var pendingIndex: Int = 0
    private var workTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?

    private var progressContinuation: AsyncStream<Progress>.Continuation?
    // nonisolated because the stream is immutable after init and AsyncStream
    // is Sendable — letting consumers `for await` without awaiting the actor.
    public nonisolated let progressUpdates: AsyncStream<Progress>

    // Separate from `progressUpdates` on purpose: access-blocked status must
    // not ride the progress stream, because each scan also emits `.indexing`
    // / `.watching` afterwards, which would immediately overwrite it and the
    // UI would never render the "grant access" state. This stream carries the
    // blocked-folder list (empty when access is fine) exactly once per scan,
    // so consumers can latch it as sticky state until the next scan clears it.
    private var accessContinuation: AsyncStream<[URL]>.Continuation?
    public nonisolated let accessUpdates: AsyncStream<[URL]>

    public init(store: ScreenshotStore, ocr: OCRRecognizer, watchedFolders: [URL]) {
        self.store = store
        self.ocr = ocr
        self.watchedFolders = watchedFolders

        var accessCont: AsyncStream<[URL]>.Continuation!
        self.accessUpdates = AsyncStream { accessCont = $0 }
        self.accessContinuation = accessCont

        var cont: AsyncStream<Progress>.Continuation!
        self.progressUpdates = AsyncStream { cont = $0 }
        self.progressContinuation = cont
    }

    // MARK: - Public API

    public func start() async throws {
        guard !isStarted else { return }
        isStarted = true

        try await initialScan()

        watcher.start(paths: watchedFolders)
        // Capture watcher locally so the Task doesn't need to hop onto the
        // actor just to read a `let` property.
        let watcher = self.watcher
        eventTask = Task { [weak self] in
            for await change in watcher.events {
                await self?.handle(change: change)
            }
        }

        await emitWatchingProgress()
    }

    public func stop() {
        watcher.stop()
        eventTask?.cancel()
        workTask?.cancel()
        progressContinuation?.finish()
        accessContinuation?.finish()
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused {
            scheduleWork()
        }
    }

    /// Re-scans every watched folder from scratch, picking up anything
    /// that FSEvents may have missed (e.g. the app was quit when the file
    /// landed). Skips unchanged files via the mtime+size fingerprint.
    public func rescanAll() async {
        do { try await initialScan() } catch {
            NSLog("vista: rescan failed: \(error)")
        }
    }

    public func updateWatchedFolders(_ folders: [URL]) async throws {
        self.watchedFolders = folders
        watcher.stop()
        watcher.start(paths: folders)
        try await initialScan()
    }

    /// Swap the OCR recognizer at runtime — lets the preferences panel
    /// change recognition level or languages without restarting the app.
    /// Already-indexed files aren't re-OCR'd; the new settings apply to
    /// files seen from now on (or to anything touched by Rescan Now).
    public func setOCRRecognizer(_ ocr: OCRRecognizer) {
        self.ocr = ocr
    }

    /// Deletes index entries (not image files) for unpinned screenshots
    /// older than `cutoff`. Called from the storage-duration pruner when
    /// preferences change or periodically while the app runs.
    public func prune(olderThan cutoff: Date) async {
        do {
            try store.deleteUnpinned(olderThan: cutoff)
            await emitWatchingProgress()
        } catch {
            NSLog("vista: prune failed: \(error)")
        }
    }

    // MARK: - Initial / rescan logic

    private func initialScan() async throws {
        let fm = FileManager.default

        VistaLog.log("initialScan starting with \(watchedFolders.count) folder(s)")
        progressContinuation?.yield(.enumerating(folders: watchedFolders.count))

        // --- Phase 1: walk each watched folder and collect candidates,
        // tracking per-root access health so a folder we simply couldn't
        // read can never be mistaken for a folder that's genuinely empty.
        var discovered: [URL] = []
        var rootScans: [RootScanResult] = []
        for root in watchedFolders {
            // Probe the folder before enumerating so a permission failure
            // surfaces in the logs instead of silently returning zero.
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: root.path, isDirectory: &isDir)
            VistaLog.log("  \(root.path) exists=\(exists) isDir=\(isDir.boolValue)")
            guard exists, isDir.boolValue else {
                VistaLog.log("  inaccessible — path does not exist or is not a directory")
                rootScans.append(RootScanResult(rootPath: root.path, accessible: false, discoveredPaths: []))
                continue
            }

            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey, .creationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    // Returning true keeps the enumerator going; logging
                    // the error gives us something to diagnose with when
                    // iCloud placeholder files or permission-denied
                    // subdirectories turn up.
                    VistaLog.log("  enumerator error at \(url.path): \(error.localizedDescription)")
                    return true
                }
            ) else {
                VistaLog.log("  could not build enumerator for \(root.path) — treating as inaccessible")
                rootScans.append(RootScanResult(rootPath: root.path, accessible: false, discoveredPaths: []))
                continue
            }

            var seen = 0
            var rootDiscovered = Set<String>()
            // `for in enumerator` drives NSFastEnumeration's makeIterator,
            // which Swift 6 treats as unavailable from async contexts. Manual
            // nextObject() avoids the sync/async mismatch without changing
            // the walk semantics.
            while let next = enumerator.nextObject() as? URL {
                seen += 1
                guard Self.isImageCandidate(next) else { continue }
                let values = try? next.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true else { continue }
                rootDiscovered.insert(next.path)
                discovered.append(next)
            }
            VistaLog.log("  enumerated \(seen) entries, matched \(rootDiscovered.count) images under \(root.path)")
            rootScans.append(RootScanResult(rootPath: root.path, accessible: true, discoveredPaths: rootDiscovered))
        }

        VistaLog.log("initialScan discovered \(discovered.count) candidate files across \(watchedFolders.count) folder(s)")

        // --- Phase 2: reconcile. Only drop rows whose file is genuinely
        // gone from a folder we could actually read. A folder that failed
        // to enumerate — or came back empty while we still hold rows for it
        // (the fresh-install / iCloud-not-materialised case) — never causes
        // deletions; instead we emit it on `accessUpdates` so the user can
        // restore access and the index resumes untouched. The per-file
        // `fileExists` check is the final belt: iCloud dataless placeholders
        // still report true, so they're preserved even if discovery missed
        // them.
        let known = try store.pathsOnDisk()
        let reconcile = Self.reconcileDeletions(known: known, roots: rootScans)
        // Files missing from a folder we could read: delete, but only after
        // fileExists confirms they're really gone (iCloud placeholders report
        // present, so they survive).
        for stale in reconcile.deleteMissing where !fm.fileExists(atPath: stale) {
            try? store.delete(path: URL(fileURLWithPath: stale))
        }
        // Orphans belong to folders no longer watched — their files still
        // exist on disk, so the fileExists guard would wrongly keep them.
        // Delete unconditionally. reconcileDeletions only reports orphans when
        // the watched-root set is trustworthy, so a failed-to-load folder list
        // can't turn every row into an "orphan" and wipe the index.
        for orphan in reconcile.deleteOrphans {
            try? store.delete(path: URL(fileURLWithPath: orphan))
        }
        // Emit access state every scan (empty when fine) so the UI can latch
        // it as sticky state — see `accessUpdates`.
        if !reconcile.blockedRoots.isEmpty {
            VistaLog.log("  ACCESS BLOCKED for \(reconcile.blockedRoots.count) folder(s) holding indexed rows — preserving index, not deleting")
        }
        accessContinuation?.yield(reconcile.blockedRoots.map { URL(fileURLWithPath: $0) })

        // --- Phase 3: fingerprint-filter. Anything whose (mtime, size)
        // matches the DB entry is already indexed; skip without OCR.
        // This is the "resume" path — on a relaunch with a populated DB,
        // nearly every file lands here and the expensive Phase 4 queue
        // ends up empty.
        var toIndex: [URL] = []
        toIndex.reserveCapacity(discovered.count / 4)  // rough guess
        for url in discovered {
            if Task.isCancelled { return }
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date()
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            if (try? store.isAlreadyIndexed(at: url, mtime: mtime, size: size)) == true {
                continue
            }
            toIndex.append(url)
        }

        VistaLog.log("\(discovered.count - toIndex.count) already indexed, \(toIndex.count) new file(s) to OCR")

        // --- Phase 4: OCR + upsert the genuinely-new files. Progress
        // reported against this shorter list so the counter reflects
        // actual work, not fingerprint-check flybys.
        let total = toIndex.count
        progressContinuation?.yield(.indexing(done: 0, total: total, indexed: (try? store.count()) ?? 0))

        var done = 0
        for url in toIndex {
            if Task.isCancelled { break }
            do {
                try await indexFile(url)
            } catch {
                VistaLog.log("failed to index \(url.lastPathComponent): \(error)")
            }
            done += 1
            // One progress event per 5 files keeps the UI lively during
            // OCR without drowning the observer. Also emit on the last
            // file so the counter lands exactly at total. `indexed` is the
            // live row count so the menu can show how many are already
            // searchable while OCR works through the backlog.
            if done % 5 == 0 || done == total {
                progressContinuation?.yield(.indexing(done: done, total: total, indexed: (try? store.count()) ?? 0))
            }
        }

        await emitWatchingProgress()
    }

    // MARK: - Event-driven indexing

    private func handle(change: FSEventsWatcher.Change) async {
        switch change {
        case .created(let url), .modified(let url), .renamed(let url):
            // Renames report the *new* path; if the file has actually
            // vanished (moved out of a watched folder) the fileExists
            // check below catches it.
            guard Self.isImageCandidate(url) else { return }
            pendingPaths.append(url)
            scheduleWork()
        case .removed(let url):
            try? store.delete(path: url)
            await emitWatchingProgress()
        }
    }

    private func scheduleWork() {
        guard workTask == nil, !isPaused else { return }
        workTask = Task { [weak self] in
            await self?.drainPending()
        }
    }

    private func drainPending() async {
        defer { workTask = nil }
        while pendingIndex < pendingPaths.count {
            if isPaused || Task.isCancelled { return }
            let url = pendingPaths[pendingIndex]
            pendingIndex += 1
            do {
                try await indexFile(url)
            } catch {
                NSLog("vista: failed to index \(url.lastPathComponent): \(error)")
            }
            // Compact occasionally so pendingPaths.count doesn't grow
            // unboundedly across many FS bursts. 256 is large enough to
            // skip the reclaim in the common small-burst case but keeps
            // memory bounded for pathological workloads.
            if pendingIndex >= 256 {
                pendingPaths.removeFirst(pendingIndex)
                pendingIndex = 0
            }
        }
        pendingPaths.removeAll(keepingCapacity: false)
        pendingIndex = 0
        await emitWatchingProgress()
    }

    // MARK: - Single-file indexing

    private func indexFile(_ url: URL) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            try? store.delete(path: url)
            return
        }

        let attrs = try fm.attributesOfItem(atPath: url.path)
        let mtime = (attrs[.modificationDate] as? Date) ?? Date()
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let created = (attrs[.creationDate] as? Date) ?? mtime

        // Skip unchanged files — the fingerprint check saves us an expensive
        // OCR pass for every file on every relaunch.
        if try store.isAlreadyIndexed(at: url, mtime: mtime, size: size) {
            return
        }

        let text = try await ocr.recognize(at: url)

        let record = ScreenshotRecord(
            path: url,
            capturedAt: created,
            mtime: mtime,
            size: size,
            ocrText: text
        )
        try store.upsert(record)
    }

    // MARK: - Reconcile

    /// Outcome of walking one watched root, fed to `reconcileDeletions`.
    /// `accessible` is the raw walk health (the folder existed, was a
    /// directory, and built an enumerator); the empty-while-known circuit
    /// breaker lives in `reconcileDeletions`, not here.
    struct RootScanResult: Sendable, Equatable {
        let rootPath: String
        let accessible: Bool
        let discoveredPaths: Set<String>
    }

    /// Decides which known rows are safe to delete during a reconcile, and
    /// which roots are access-blocked. Pure so it can be unit-tested without
    /// touching the filesystem or OCR.
    ///
    /// Three buckets:
    /// - `deleteMissing` — under a readable root but not seen this scan: the
    ///   file is genuinely gone. A readable root that returned zero files
    ///   while we still hold rows under it is treated as *blocked*, not empty
    ///   — the fresh-install / lost-permission / iCloud-not-materialised case,
    ///   and deleting there is exactly the data-loss bug we're guarding.
    /// - `deleteOrphans` — not under any watched root, i.e. a folder the user
    ///   unwatched. Returned ONLY when at least one root was accessible, so a
    ///   watched-folder list that failed to load can't make every row look
    ///   like an orphan and wipe the index.
    /// - `blockedRoots` — readable-but-untrustworthy or unreadable roots that
    ///   still hold rows; surfaced to the UI, never deleted from.
    ///
    /// Known paths are grouped by root in a single pass with prefixes computed
    /// once, so this stays O(known) regardless of library size.
    static func reconcileDeletions(
        known: Set<String>,
        roots: [RootScanResult]
    ) -> (deleteMissing: [String], deleteOrphans: [String], blockedRoots: [String]) {
        var deleteMissing: [String] = []
        var deleteOrphans: [String] = []
        var blockedRoots: [String] = []

        let prefixes = roots.map { $0.rootPath.hasSuffix("/") ? $0.rootPath : $0.rootPath + "/" }
        var pathsByRoot: [Int: [String]] = [:]
        var orphans: [String] = []
        for path in known {
            if let index = prefixes.firstIndex(where: { path.hasPrefix($0) }) {
                pathsByRoot[index, default: []].append(path)
            } else {
                orphans.append(path)
            }
        }

        for (index, root) in roots.enumerated() {
            let knownUnder = pathsByRoot[index] ?? []
            // Circuit breaker: an "accessible" root that found nothing while
            // we hold rows for it is not trustworthy — never wipe on it.
            let trustworthy = root.accessible
                && !(root.discoveredPaths.isEmpty && !knownUnder.isEmpty)
            guard trustworthy else {
                if !knownUnder.isEmpty { blockedRoots.append(root.rootPath) }
                continue
            }
            for path in knownUnder where !root.discoveredPaths.contains(path) {
                deleteMissing.append(path)
            }
        }

        // Only act on orphans when the root set is trustworthy enough to trust
        // the "not under any root" conclusion. With no accessible root, the
        // folder list may simply have failed to resolve — preserve everything.
        if roots.contains(where: { $0.accessible }) {
            deleteOrphans = orphans
        }

        return (deleteMissing, deleteOrphans, blockedRoots)
    }

    // MARK: - Helpers

    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "bmp", "webp"
    ]

    public static func isImageCandidate(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    private func emitWatchingProgress() async {
        let count = (try? store.count()) ?? 0
        progressContinuation?.yield(.watching(indexed: count))
    }
}
