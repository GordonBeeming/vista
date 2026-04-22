// FSEventsWatcher.swift — Async wrapper around FSEventStream.
//
// One watcher per session can track many paths. We keep the API small:
//   - start(paths:) begins streaming
//   - events is an AsyncStream of created / renamed / deleted URLs
//   - stop() tears down and closes the stream
//
// CoreServices' FSEvents is coalesce-heavy: a burst of writes to the same
// file arrives as one callback. That's fine for us — the indexer de-dupes
// by (path, mtime, size).

import Foundation
import CoreServices

public final class FSEventsWatcher: @unchecked Sendable {

    public enum Change: Sendable, Equatable {
        case created(URL)
        case modified(URL)
        case renamed(URL)
        case removed(URL)
    }

    private var stream: FSEventStreamRef?
    private var continuation: AsyncStream<Change>.Continuation?

    public let events: AsyncStream<Change>

    public init() {
        var c: AsyncStream<Change>.Continuation!
        self.events = AsyncStream { c = $0 }
        self.continuation = c
    }

    /// Starts streaming events for the given paths. Safe to call once; to
    /// change paths, `stop()` then call `start` again.
    public func start(paths: [URL]) {
        guard stream == nil, !paths.isEmpty else { return }

        // FSEvents takes a CFArray of CFString paths. We stash `self` in
        // the context so the C callback can dispatch back to Swift.
        let cfPaths = paths.map { $0.path as CFString } as CFArray

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // kFSEventStreamEventIdSinceNow = "start from now". We don't want
        // to replay historical events — the initial scan handles existing
        // files. kFSEventStreamCreateFlagFileEvents = per-file granularity
        // (default is per-directory). IgnoreSelf avoids loopbacks when the
        // app writes to the cache dir.
        let flags: UInt32 = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagIgnoreSelf
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let ref = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, clientInfo, numEvents, eventPaths, eventFlags, _ in
                guard let clientInfo else { return }
                let watcher = Unmanaged<FSEventsWatcher>
                    .fromOpaque(clientInfo)
                    .takeUnretainedValue()
                let paths = Unmanaged<CFArray>
                    .fromOpaque(eventPaths)
                    .takeUnretainedValue() as! [String]
                watcher.handle(paths: paths, flags: eventFlags, count: numEvents)
            },
            &context,
            cfPaths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // latency (seconds) — 1s is a good balance between
                 // responsiveness and batching of rapid writes
            flags
        ) else { return }

        self.stream = ref
        FSEventStreamSetDispatchQueue(ref, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(ref)
    }

    public func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        continuation?.finish()
    }

    // MARK: - Callback dispatch

    private func handle(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        for i in 0..<count {
            let raw = paths[i]
            let url = URL(fileURLWithPath: raw)
            let flag = flags[i]
            // FSEvents coalesces multiple semantic events into one flag mask.
            // We check each bit in a sensible order — a file that was
            // created + modified + renamed in the same coalesced event
            // should still get reported.
            if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                continuation?.yield(.removed(url))
            }
            if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                continuation?.yield(.renamed(url))
            }
            if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                continuation?.yield(.created(url))
            } else if flag & UInt32(kFSEventStreamEventFlagItemModified) != 0 {
                continuation?.yield(.modified(url))
            }
        }
    }

    deinit { stop() }
}
