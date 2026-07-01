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
        // thread into the worker task as a side effect, which is harmless.
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
/// `timeout`. The caller is freed the instant either the work or the deadline
/// settles, even when the work is stuck in a non-cancellable synchronous call
/// (Vision's `perform`, an ImageIO decode) that ignores cooperative cancellation.
///
/// This deliberately does NOT use a `withThrowingTaskGroup`: a structured group
/// cannot return from its scope until every child task has finished, so if the
/// operation hangs the group hangs with it and the timeout never frees the
/// caller — defeating the whole watchdog. Instead the work runs in an
/// unstructured task that the caller never awaits directly. The caller suspends
/// on a continuation that whichever of {work, deadline} finishes first resumes
/// via a one-shot gate; a hung work task is simply orphaned (it finishes in the
/// background and its late result is discarded). This bounds the *await*, not
/// necessarily the CPU — the right trade for a watchdog.
func withTimeout<T: Sendable>(
    _ timeout: Duration,
    onTimeout: @autoclosure @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
        let gate = TimeoutGate(continuation)
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                gate.resume(with: .failure(onTimeout()))
            } catch {
                // Sleep cancelled because the work settled first — nothing to do.
            }
        }
        Task {
            do { gate.resume(with: .success(try await operation())) }
            catch { gate.resume(with: .failure(error)) }
            // Stop the watchdog as soon as the work settles so the common fast
            // path doesn't leave a task sleeping out the full timeout.
            deadline.cancel()
        }
    }
}

/// One-shot resume gate for `withTimeout`: only the first of {work, deadline}
/// resumes the caller; the loser's later attempt is dropped. The NSLock guards
/// the single-resume invariant that `CheckedContinuation` asserts on. Declared
/// at file scope because Swift can't nest a type inside a generic function.
private final class TimeoutGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let firstTime = !resumed
        resumed = true
        lock.unlock()
        if firstTime { continuation.resume(with: result) }
    }
}
