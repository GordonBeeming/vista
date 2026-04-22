// OCRRecognizerTests.swift — Smoke-tests the Vision wrapper.
//
// Rather than shipping hand-crafted fixture PNGs (which drift visually
// from one macOS version to the next), we render a known phrase into a
// CGImage at test time and round-trip it through OCR. Fast, deterministic,
// and the text/font parameters are obvious from the test source.

import XCTest
import AppKit
import CoreGraphics
@testable import VistaCore

final class OCRRecognizerTests: XCTestCase {

    func testRecognisesRenderedText() async throws {
        let image = try Self.renderText("vista invoice 2024", size: CGSize(width: 800, height: 160))
        let recognizer = OCRRecognizer(level: .accurate)
        let text = try await recognizer.recognize(cgImage: image)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("vista"),
                      "Expected 'vista' in OCR output, got: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("invoice"),
                      "Expected 'invoice' in OCR output, got: \(text)")
    }

    func testOffLevelReturnsEmpty() async throws {
        let image = try Self.renderText("should be ignored", size: CGSize(width: 600, height: 120))
        let recognizer = OCRRecognizer(level: .off)
        let text = try await recognizer.recognize(cgImage: image)
        XCTAssertEqual(text, "")
    }

    // MARK: - Fixture rendering

    /// Draws black text on a white background. Large font so Vision has
    /// plenty of pixels to work with — OCR is accurate enough that even
    /// the fast level handles this reliably.
    private static func renderText(_ text: String, size: CGSize) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 72),
                .foregroundColor: NSColor.black
            ]
        )
        // CoreText draws in bottom-up coordinates; flip once and draw at
        // an inset so the text doesn't clip to the edges.
        let line = CTLineCreateWithAttributedString(attributed)
        context.textMatrix = .identity
        context.translateBy(x: 20, y: 40)
        CTLineDraw(line, context)

        guard let cgImage = context.makeImage() else {
            throw NSError(domain: "OCRTests", code: -1, userInfo: [NSLocalizedDescriptionKey: "failed to render fixture"])
        }
        return cgImage
    }
}
