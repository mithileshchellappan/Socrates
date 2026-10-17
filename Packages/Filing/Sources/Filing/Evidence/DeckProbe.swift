import Foundation
// PDFKit re-exports AppKit/UIKit; this file uses only PDFDocument/PDFPage text and metadata, and
// the internal import keeps those modules out of Filing's interface (same exception as Capture's
// DeckText, docs/decisions.md).
internal import PDFKit

/// A quick look at a slide PDF for filing: page count, metadata and the text of a few pages
/// (the first ones and an even spread), enough for footer, title slide and numbering without
/// reading the whole deck (an 88-page deck takes ≈ 10 ms instead of ≈ 125 ms).
struct DeckProbe: Sendable, Hashable {
    var pageCount: Int
    var pdfTitle: String?
    var pdfAuthor: String?
    /// Sampled pages in page order, first page first.
    var pages: [Page]

    struct Page: Sendable, Hashable {
        /// 1-based.
        var number: Int
        var text: String
    }

    /// Pages read besides the first: footers repeat on most pages, so an even spread suffices.
    static let sampleSize = 12

    static func read(_ url: URL, sampleSize: Int = DeckProbe.sampleSize) -> DeckProbe? {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { return nil }
        let count = document.pageCount
        let pages = sample(pageCount: count, size: sampleSize).compactMap { index -> Page? in
            guard let page = document.page(at: index) else { return nil }
            return Page(number: index + 1, text: page.string ?? "")
        }
        let attributes = document.documentAttributes ?? [:]
        func attribute(_ key: PDFDocumentAttribute) -> String? {
            let value = (attributes[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        return DeckProbe(
            pageCount: count,
            pdfTitle: attribute(.titleAttribute),
            pdfAuthor: attribute(.authorAttribute),
            pages: pages
        )
    }

    /// 0-based page indices: the first three, then evenly spread up to `size` in all.
    static func sample(pageCount: Int, size: Int) -> [Int] {
        guard pageCount > size else { return Array(0..<pageCount) }
        var indices = Set(0..<min(3, pageCount))
        let rest = size - indices.count
        for step in 0..<rest {
            let position = 3 + Int((Double(step) + 0.5) * Double(pageCount - 3) / Double(rest))
            indices.insert(min(pageCount - 1, position))
        }
        return indices.sorted()
    }
}
