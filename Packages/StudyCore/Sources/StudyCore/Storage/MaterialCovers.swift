import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// mt: course materials' covers and favicons, cached files (never blobs, never synced): re-made
/// when missing. A cover is page 1 of the PDF, or the first of pages 1–4 that is not near-blank
/// (a half-title page), drawn on white at `coverPixelWidth` (the shelf's 112 pt tile at 2×).
/// CoreGraphics only (no PDFKit, no AppKit): the library makes it on add, the screens when the
/// cache was purged. Blocking work: call it off the main actor.
public enum MaterialCovers {
    public static let coverPixelWidth = 224
    /// A page counts as blank when at least this share of its sampled pixels is white.
    static let blankShare = 0.98

    /// `Caches/Materials/covers/<sha256>.png`.
    public static func coverURL(sha256: String, paths: AppPaths) -> URL {
        paths.caches.appending(path: "Materials/covers", directoryHint: .isDirectory).appending(path: "\(sha256).png")
    }

    /// `Caches/Materials/favicons/<hash>.png` (`MaterialFacts.faviconHash`; the link fetcher writes it).
    public static func faviconURL(hash: String, paths: AppPaths) -> URL {
        paths.caches.appending(path: "Materials/favicons", directoryHint: .isDirectory).appending(path: "\(hash).png")
    }

    /// The cover of the PDF at `file` (its document's `blob_sha256` names the cache file): the
    /// cached one, else drawn and cached now. Nil when the PDF cannot be opened.
    public static func cover(pdfAt file: URL, sha256: String, paths: AppPaths) -> URL? {
        let url = coverURL(sha256: sha256, paths: paths)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        guard let document = CGPDFDocument(file as CFURL), document.numberOfPages > 0,
              let image = render(document: document) else { return nil }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return url
        } catch {
            Log.materials.error("Writing a cover failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The first of pages 1–4 that has ink, drawn on white at `coverPixelWidth`.
    static func render(document: CGPDFDocument) -> CGImage? {
        let candidates = (1...min(4, document.numberOfPages)).compactMap { document.page(at: $0) }
        let page = candidates.first { !isBlank($0) } ?? candidates.first
        guard let page else { return nil }
        return draw(page, width: coverPixelWidth)
    }

    /// The page at `width` pixels (its crop box's aspect), white behind it.
    static func draw(_ page: CGPDFPage, width: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let rotated = page.rotationAngle % 180 != 0
        let aspect = rotated ? box.width / box.height : box.height / box.width
        let height = max(1, Int((CGFloat(width) * aspect).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let target = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(target)
        context.interpolationQuality = .high
        context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// At least `blankShare` of the page drawn at 48 px wide is white (a near-blank half-title).
    static func isBlank(_ page: CGPDFPage) -> Bool {
        guard let image = draw(page, width: 48), let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return false }
        let length = CFDataGetLength(data)
        let stride = image.bitsPerPixel / 8
        guard stride >= 3, length > 0 else { return false }
        var white = 0
        var total = 0
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * image.bytesPerRow + column * stride
                guard offset + 2 < length else { continue }
                total += 1
                if bytes[offset] > 245, bytes[offset + 1] > 245, bytes[offset + 2] > 245 { white += 1 }
            }
        }
        return total > 0 && Double(white) / Double(total) >= blankShare
    }
}
