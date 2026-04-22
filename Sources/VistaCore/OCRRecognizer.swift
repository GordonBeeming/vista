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

    /// Recognises text in the image at `url`. Returns a single joined
    /// string (lines separated by `\n`). Empty when OCR is off or when
    /// Vision found no text.
    ///
    /// Throws on unreadable files or Vision failures — callers can decide
    /// whether to log and skip or surface to the user.
    public func recognize(at url: URL) async throws -> String {
        guard level != .off else { return "" }

        // Load once via ImageIO — avoids pulling the full decoded bitmap
        // into memory when Vision can stream from the CGImage source.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OCRError.unreadableImage(url)
        }

        return try await recognize(cgImage: cgImage)
    }

    /// Recognises text in an already-decoded CGImage. Exposed so tests and
    /// the thumbnail path can reuse a single decode.
    public func recognize(cgImage: CGImage) async throws -> String {
        guard level != .off else { return "" }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                // `topCandidates(1)` returns up to one best-guess per
                // recognised line; Vision already filters confidence.
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
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
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public enum OCRError: Error, Equatable {
        case unreadableImage(URL)
    }
}
