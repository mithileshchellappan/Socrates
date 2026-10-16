import CoreGraphics
import Foundation
import StudyCore

public enum SlideDeckError: Error, Equatable, Sendable {
    case unreadablePDF(String)
    case pageOutOfRange(Int)
    case renderFailed(Int)
    case cacheWriteFailed(String)
}

/// A slide PDF rendered with Core Graphics (no AppKit/UIKit), with a two-level bitmap cache:
/// a byte-bounded in-memory LRU and PNGs on disk keyed by deck SHA-256, page and width.
///
/// The actor serializes access to the `CGPDFDocument`. Long warm-ups (`prerender`) yield
/// between pages so an interactive request is served within one page render.
public actor SlideDeck {
    public nonisolated let url: URL
    /// Lowercase hex SHA-256 of the PDF.
    public nonisolated let sha256: String
    public nonisolated let pageCount: Int
    /// Page sizes in points after applying page rotation (index 0 = page 1).
    public nonisolated let pageSizes: [CGSize]
    public nonisolated let cache: SlideImageCache

    private let document: CGPDFDocument
    private let memoryBudget: Int
    private var memory: [SlideRenderKey: CGImage] = [:]
    private var recency: [SlideRenderKey] = []
    private var memoryBytes = 0
    /// Pages rendered from the PDF (cache misses), for tests and diagnostics.
    public private(set) var renderCount = 0

    /// Opens `url`. Pass `sha256` when known (e.g. from the BlobStore) to skip hashing.
    public init(url: URL, sha256: String? = nil, cacheDirectory: URL, memoryBudgetBytes: Int = 128 << 20) throws {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw SlideDeckError.unreadablePDF(url.lastPathComponent)
        }
        self.url = url
        self.sha256 = try sha256?.lowercased() ?? BlobStore.sha256(of: url)
        self.document = document
        self.pageCount = document.numberOfPages
        self.pageSizes = (1...document.numberOfPages).map { number in
            document.page(at: number).map(SlidePageRenderer.displaySize(of:)) ?? .zero
        }
        self.cache = SlideImageCache(root: cacheDirectory)
        self.memoryBudget = memoryBudgetBytes
    }

    /// Width / height of a page (16:9 when unknown).
    public nonisolated func aspectRatio(page: Int) -> CGFloat {
        guard pageSizes.indices.contains(page - 1) else { return 16.0 / 9.0 }
        let size = pageSizes[page - 1]
        return size.height > 0 ? size.width / size.height : 16.0 / 9.0
    }

    /// The bitmap of `page` at `width` pixels: from memory, else disk, else rendered (and cached).
    public func image(page: Int, width: Int) throws -> CGImage {
        let key = SlideRenderKey(deckSHA256: sha256, page: page, pixelWidth: width)
        if let image = memory[key] {
            touch(key)
            return image
        }
        let image = try loadOrRender(key)
        remember(image, for: key)
        return image
    }

    /// The bitmap if it is in memory right now (never blocks on disk or rendering).
    public func cachedImage(page: Int, width: Int) -> CGImage? {
        memory[SlideRenderKey(deckSHA256: sha256, page: page, pixelWidth: width)]
    }

    /// Loads `pages` at `width` into memory (rendering when needed), nearest first.
    public func prefetch(pages: [Int], width: Int) async {
        for page in pages where (1...pageCount).contains(page) {
            if Task.isCancelled { return }
            _ = try? image(page: page, width: width)
            await Task.yield()
        }
    }

    /// Renders every page at each width to the disk cache without keeping them in memory.
    /// Yields between pages; stops when the task is cancelled.
    public func prerender(widths: [Int]) async {
        for width in widths {
            for page in 1...pageCount {
                if Task.isCancelled { return }
                let key = SlideRenderKey(deckSHA256: sha256, page: page, pixelWidth: width)
                if memory[key] == nil, !cache.contains(key) {
                    do {
                        try cache.store(try render(key), for: key)
                    } catch {
                        CaptureLog.deck.error("Prerender failed for \(key, privacy: .public): \(String(describing: error), privacy: .public)")
                    }
                }
                await Task.yield()
            }
        }
    }

    // MARK: - Private

    private func loadOrRender(_ key: SlideRenderKey) throws -> CGImage {
        guard (1...pageCount).contains(key.page) else { throw SlideDeckError.pageOutOfRange(key.page) }
        if let image = cache.load(key) {
            return image
        }
        let image = try render(key)
        do {
            try cache.store(image, for: key)
        } catch {
            CaptureLog.deck.error("Caching \(key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
        return image
    }

    private func render(_ key: SlideRenderKey) throws -> CGImage {
        guard let page = document.page(at: key.page),
              let image = SlidePageRenderer.render(page, pixelWidth: key.pixelWidth)
        else { throw SlideDeckError.renderFailed(key.page) }
        renderCount += 1
        return image
    }

    private func remember(_ image: CGImage, for key: SlideRenderKey) {
        memory[key] = image
        memoryBytes += image.bytesPerRow * image.height
        touch(key)
        while memoryBytes > memoryBudget, recency.count > 1 {
            let oldest = recency.removeFirst()
            if let evicted = memory.removeValue(forKey: oldest) {
                memoryBytes -= evicted.bytesPerRow * evicted.height
            }
        }
    }

    private func touch(_ key: SlideRenderKey) {
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }
}

/// Draws PDF pages into bitmaps with Core Graphics.
public enum SlidePageRenderer {
    /// Page size in points with `/Rotate` applied.
    public static func displaySize(of page: CGPDFPage) -> CGSize {
        let box = page.getBoxRect(.cropBox)
        return isQuarterTurn(page) ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Renders `page` `pixelWidth` pixels wide (height follows the aspect ratio) on white.
    ///
    /// Builds the transform by hand: `CGPDFPage.getDrawingTransform` never scales up.
    public static func render(_ page: CGPDFPage, pixelWidth: Int) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        let size = displaySize(of: page)
        guard pixelWidth > 0, size.width > 0, size.height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let scale = CGFloat(pixelWidth) / size.width
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)

        context.scaleBy(x: scale, y: scale)
        switch normalizedRotation(page) {
        case 90:
            context.translateBy(x: 0, y: box.width)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: box.width, y: box.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: box.height, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    static func normalizedRotation(_ page: CGPDFPage) -> Int32 {
        ((page.rotationAngle % 360) + 360) % 360
    }

    static func isQuarterTurn(_ page: CGPDFPage) -> Bool {
        let rotation = normalizedRotation(page)
        return rotation == 90 || rotation == 270
    }
}
