// OCRRecognizer.swift — Apple Vision OCR wrapper.
//
// Keeps the Vision API surface inside a tiny boundary so the rest of
// VistaCore deals only with strings. Thread-safe: each call builds its own
// VNImageRequestHandler, which is cheap.

import Foundation
// Vision ships Objective-C types that aren't marked Sendable (VNImageRequestHandler,
// VNRecognizeTextRequest). We only use them inside a single dispatch block
// per call, so @preconcurrency is the honest signal — no data race here.
@preconcurrency import Vision
import CoreGraphics
import ImageIO

public final class OCRRecognizer: Sendable {

    /// Matches Vision's accuracy levels. "Off" is modelled as a separate
    /// state so callers can branch without threading an optional through.
    public enum Level: Sendable {
        case off
        case fast
        case accurate
    }

    public let level: Level

    /// BCP-47 language codes passed to Vision. Empty means "let Vision
    /// auto-detect" which works well for Latin scripts. We seed this from
    /// Locale.preferredLanguages in Indexer so non-English UIs benefit.
    public let languages: [String]

    public init(level: Level = .fast, languages: [String] = []) {
        self.level = level
        self.languages = languages
    }

    /// Upper bound on a single file's OCR. Vision has been observed to
    /// accept an image and then never fire its completion handler (nor
    /// throw), which would await forever; the ImageIO decode can likewise
    /// stall on a malformed iCloud file. A per-file timeout turns either
    /// hang into a thrown error the indexer can log and skip, so one bad
    /// file can't wedge the whole queue. 60s is far above real OCR cost
    /// (accurate mode on the largest screenshots is a few seconds) — it
    /// only ever trips on a genuine infinite hang.
    public static let defaultTimeout: Duration = .seconds(60)

    /// Recognises text in the image at `url`. Returns a single joined
    /// string (lines separated by `\n`). Empty when OCR is off or when
    /// Vision found no text.
    ///
    /// Throws on unreadable files, Vision failures, or when the work
    /// exceeds `timeout` — callers can decide whether to log and skip or
    /// surface to the user.
    public func recognize(at url: URL, timeout: Duration = OCRRecognizer.defaultTimeout) async throws -> String {
        guard level != .off else { return "" }

        // Both the decode and the Vision call run inside the timeout so a
        // stall in either one is bounded. The decode moves off the caller's
        // thread into the worked task as a side effect, which is harmless.
        return try await withTimeout(timeout, onTimeout: OCRError.timedOut(url)) {
            // Load once via ImageIO — avoids pulling the full decoded bitmap
            // into memory when Vision can stream from the CGImage source.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw OCRError.unreadableImage(url)
            }
            return try await self.recognize(cgImage: cgImage)
        }
    }

    /// Recognises text in an already-decoded CGImage. Exposed so tests and
    /// the thumbnail path can reuse a single decode.
    public func recognize(cgImage: CGImage) async throws -> String {
        guard level != .off else { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            // Two code paths can signal a result here:
            //   1. The VNRecognizeTextRequest completion handler (normal
            //      success/error).
            //   2. The `handler.perform([request])` call throwing.
            //
            // In nearly all cases exactly one fires, but Vision has been
            // observed to surface both paths under rare timing conditions —
            // completion fires with an error AND perform() throws — which
            // double-resumes the checked continuation and crashes the app
            // with an assertion failure (seen at ~2.7k files into a scan).
            // A thread-safe one-shot gate guarantees we only resume once.
            let gate = ContinuationGate(continuation)

            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    gate.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // `topCandidates(1)` returns up to one best-guess per
                // recognised line; Vision already filters confidence.
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                gate.resume(returning: lines.joined(separator: "\n"))
            }

            request.recognitionLevel = level == .accurate ? .accurate : .fast
            request.usesLanguageCorrection = level == .accurate
            if !languages.isEmpty {
                request.recognitionLanguages = languages
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            // Vision's perform() is synchronous; push it off the caller's
            // queue to avoid blocking the indexer loop.
            DispatchQueue.global(qos: .utility).async {
                do {
                    try handler.perform([request])
                } catch {
                    gate.resume(throwing: error)
                }
            }
        }
    }

    /// One-shot gate around a CheckedContinuation. Swift's
    /// CheckedContinuation enforces single-resume at runtime with an
    /// assertion; pairing a `VN*Request` completion handler with a
    /// `perform()` catch block is exactly the shape where a double resume
    /// can slip through, so we route both through this.
    private final class ContinuationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String, Error>

        init(_ continuation: CheckedContinuation<String, Error>) {
            self.continuation = continuation
        }

        func resume(returning value: String) {
            lock.lock()
            let firstTime = !done
            done = true
            lock.unlock()
            if firstTime { continuation.resume(returning: value) }
        }

        func resume(throwing error: Error) {
            lock.lock()
            let firstTime = !done
            done = true
            lock.unlock()
            if firstTime { continuation.resume(throwing: error) }
        }
    }

    public enum OCRError: Error, Equatable {
        case unreadableImage(URL)
        case timedOut(URL)
    }
}

/// Runs `operation`, throwing `onTimeout` if it hasn't finished within
/// `timeout`. Races the work against a sleeper in a task group and cancels
/// the loser. The work task is cooperatively cancelled on timeout — a
/// synchronous, non-cancellable call inside it (Vision's `perform`, an
/// ImageIO decode) keeps running to completion in the background but its
/// result is discarded, so this bounds the *await*, not necessarily the CPU.
/// That's the right trade for a watchdog: the caller is freed to move on.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    onTimeout: @autoclosure @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw onTimeout()
        }
        // The first task to finish wins; cancel the other and return.
        guard let result = try await group.next() else {
            throw onTimeout()
        }
        group.cancelAll()
        return result
    }
}
