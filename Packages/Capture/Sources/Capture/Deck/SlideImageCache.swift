import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fixed render widths in pixels. Two sizes keep the cache small and predictable.
public enum SlideWidth {
    /// Filmstrips and lists (92 pt at 2×, with headroom).
    public static let thumbnail = 320
    /// The large slide (about 1000 pt at 2×).
    public static let display = 2048
}

/// Identifies one rendered slide bitmap. Bump `rendererVersion` when rendering changes so stale
/// bitmaps are never reused.
public struct SlideRenderKey: Hashable, Sendable, CustomStringConvertible {
    public static let rendererVersion = 1

    /// Lowercase hex SHA-256 of the PDF.
    public var deckSHA256: String
    /// 1-based page.
    public var page: Int
    public var pixelWidth: Int
    public var version: Int

    public init(deckSHA256: String, page: Int, pixelWidth: Int, version: Int = SlideRenderKey.rendererVersion) {
        self.deckSHA256 = deckSHA256.lowercased()
        self.page = page
        self.pixelWidth = pixelWidth
        self.version = version
    }

    /// `ab/abcdef…/p0012-w2048-v1.png`: one folder per deck, sortable file names.
    public var relativePath: String {
        let prefix = deckSHA256.prefix(2)
        return "\(prefix)/\(deckSHA256)/" + String(format: "p%04d-w%d-v%d.png", page, pixelWidth, version)
    }

    public var description: String { relativePath }
}

/// Rendered slide bitmaps on disk (PNG), under the app's caches directory. Safe to purge.
public struct SlideImageCache: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func url(for key: SlideRenderKey) -> URL {
        root.appending(path: key.relativePath, directoryHint: .notDirectory)
    }

    public func contains(_ key: SlideRenderKey) -> Bool {
        FileManager.default.fileExists(atPath: url(for: key).path(percentEncoded: false))
    }

    /// Decodes the cached bitmap off the calling thread's lazy path (decoded immediately),
    /// downsampled so its longer side is at most `maxPixelSize` when given.
    public func load(_ key: SlideRenderKey, maxPixelSize: Int? = nil) -> CGImage? {
        let url = url(for: key)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Writes `image` as PNG atomically.
    public func store(_ image: CGImage, for key: SlideRenderKey) throws {
        let destination = url(for: key)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(UUID().uuidString).png")
        guard let writer = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SlideDeckError.cacheWriteFailed(key.relativePath) }
        CGImageDestinationAddImage(writer, image, nil)
        guard CGImageDestinationFinalize(writer) else {
            try? FileManager.default.removeItem(at: temporary)
            throw SlideDeckError.cacheWriteFailed(key.relativePath)
        }
        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    /// Removes every cached bitmap of a deck.
    public func removeAll(deckSHA256: String) throws {
        let sha = deckSHA256.lowercased()
        let directory = root.appending(path: "\(sha.prefix(2))/\(sha)", directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
