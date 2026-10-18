import Capture
import CoreGraphics
import Foundation
import ImageIO
import StudyCore
import UniformTypeIdentifiers

/// Figure slides as JPEG (≤ 1024 px wide) for a read call, rendered from the deck PDF with
/// `Capture.SlidePageRenderer` (no AppKit/UIKit).
enum SlideImages {
    static let quality = 0.8

    /// One JPEG per page that renders; pages that fail are left out (logged).
    static func jpegs(pages: [Int], deck: Deck?, blobs: BlobStore) -> [(page: Int, data: Data)] {
        guard !pages.isEmpty, let ref = deck?.blob else { return [] }
        let url = blobs.url(for: ref)
        guard let document = CGPDFDocument(url as CFURL) else {
            StudyPass.log.error("Deck PDF unreadable for slide images")
            return []
        }
        var images: [(page: Int, data: Data)] = []
        for page in pages {
            guard let pdfPage = document.page(at: page),
                  let image = SlidePageRenderer.render(pdfPage, pixelWidth: ReadStage.imageWidth),
                  let data = jpeg(image) else {
                StudyPass.log.error("Slide \(page) did not render as an image")
                continue
            }
            images.append((page, data))
        }
        return images
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
