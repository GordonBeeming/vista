// ThumbnailCache.swift — Disk-backed NSImage thumbnail cache.
//
// Thumbnails are derived from on-disk screenshots; we never keep the
// only copy. Living in ~/Library/Caches means macOS can evict the whole
// directory under disk pressure without breaking correctness — the next
// request just re-renders.
//
// Keys: sha1(absolute-path)-<size>.png. The sha lets us keep the cache
// flat (no directory nesting) while still avoiding collisions. Size is
// the longest edge in pixels.

import Foundation
import AppKit
import ImageIO
import CryptoKit

public final class ThumbnailCache: @unchecked Sendable {

    public enum Size: Int, Sendable, CaseIterable {
        case small = 256
        case medium = 512
        case large = 1024
    }

    private let directory: URL
    // In-process cache: avoids decode+resize when the same thumbnail is
    // requested multiple times within one app session (common during
    // scrolling). NSCache evicts under memory pressure automatically.
    private let memoryCache = NSCache<NSString, NSImage>()

    public init(directory: URL? = nil) throws {
        let base = try directory ?? VistaPaths.cachesDirectory()
        self.directory = base.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        // Loose cap on memory residency — 512 entries × ~256 KB average
        // for a 512-pixel thumbnail is ~128 MB, which is well within
        // what a foreground Mac app can keep.
        memoryCache.countLimit = 512
    }

    /// Returns a thumbnail, rendering and persisting it if needed.
    /// `sourceMtime` is the source file's current mtime — when it differs
    /// from the mtime encoded in the cached filename, we regenerate.
    /// Pass `sourceSize` when possible; it's rolled into the cache key so
    /// a file that changes inside the same second (and therefore keeps
    /// the same whole-second mtime) still invalidates the cached image.
    public func thumbnail(
        for source: URL,
        size: Size,
        sourceMtime: Date,
        sourceSize: Int64? = nil
    ) throws -> NSImage {
        let key = Self.cacheKey(for: source, size: size, mtime: sourceMtime, sourceSize: sourceSize)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        let diskURL = directory.appendingPathComponent(key).appendingPathExtension("png")
        if FileManager.default.fileExists(atPath: diskURL.path),
           let image = NSImage(contentsOf: diskURL) {
            memoryCache.setObject(image, forKey: key as NSString)
            return image
        }

        // Cache miss — render from source.
        let image = try renderThumbnail(from: source, size: size)
        try writePNG(image: image, to: diskURL)
        memoryCache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Removes every entry for this source path (all sizes, all mtimes).
    /// Called when the Indexer sees a file deleted or modified — the mtime
    /// suffix would otherwise leave stale files on disk.
    public func purge(source: URL) {
        let prefix = Self.pathHash(source)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for entry in entries where entry.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
            }
        }
        // memoryCache entries will age out naturally.
    }

    // MARK: - Private

    private func renderThumbnail(from url: URL, size: Size) throws -> NSImage {
        // ImageIO's CGImageSourceCreateThumbnailAtIndex is the right tool
        // here: it reads embedded EXIF thumbnails when available and only
        // decodes the subset of the source image actually needed.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size.rawValue,
            kCGImageSourceShouldCache: false,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw CacheError.renderFailed(url)
        }
        let nsSize = NSSize(width: cgImage.width, height: cgImage.height)
        return NSImage(cgImage: cgImage, size: nsSize)
    }

    private func writePNG(image: NSImage, to url: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            throw CacheError.encodeFailed(url)
        }
        try data.write(to: url)
    }

    private static func cacheKey(for source: URL, size: Size, mtime: Date, sourceSize: Int64?) -> String {
        // mtime alone can collide when a file changes twice inside the
        // same whole second — including file size (when known) disambiguates
        // same-second rewrites. Higher-precision timestamps vary by APFS
        // semantics and aren't reliable across copy/move, so size is the
        // cheapest stable tiebreaker we have.
        let mtimeStamp = Int(mtime.timeIntervalSince1970)
        let sizeTag = sourceSize.map(String.init) ?? "?"
        return "\(pathHash(source))-\(mtimeStamp)-\(sizeTag)-\(size.rawValue)"
    }

    private static func pathHash(_ url: URL) -> String {
        let data = Data(url.path.utf8)
        let digest = Insecure.SHA1.hash(data: data)
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    public enum CacheError: Error, Equatable {
        case renderFailed(URL)
        case encodeFailed(URL)
    }
}
