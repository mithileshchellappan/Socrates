import Foundation
// PDFKit re-exports AppKit/UIKit; this file uses only PDFDocument/PDFPage text extraction, and the
// internal import keeps those modules out of Capture's interface (docs/decisions.md).
internal import PDFKit

/// Text of a slide PDF, for alignment, search and stamp titles.
public struct DeckText: Sendable, Hashable {
    public struct Page: Sendable, Hashable {
        /// 1-based.
        public var number: Int
        /// PDF page label when it differs from the number, else "".
        public var label: String
        public var text: String

        public init(number: Int, label: String = "", text: String) {
            self.number = number
            self.label = label
            self.text = text
        }

        /// A short title for lists ("Slide 15 · Paravirtualization").
        public var title: String { DeckText.title(fromPageText: text) }
    }

    /// PDF metadata title, if any.
    public var title: String?
    public var pages: [Page]

    public init(title: String? = nil, pages: [Page]) {
        self.title = title
        self.pages = pages
    }

    /// Extracts page texts and labels with PDFKit. Nil if the file is not a readable PDF.
    public static func extract(from url: URL) -> DeckText? {
        guard let document = PDFDocument(url: url) else { return nil }
        var pages: [Page] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let number = index + 1
            let label = page.label ?? ""
            pages.append(Page(
                number: number,
                label: label == String(number) ? "" : label,
                text: (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        let title = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DeckText(title: title?.isEmpty == false ? title : nil, pages: pages)
    }

    /// The first line that reads like a heading: skips blank lines, bare numbers, dates and
    /// bullets; collapses whitespace; at most `limit` characters.
    public static func title(fromPageText text: String, limit: Int = 80) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
        for raw in lines {
            var line = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            while let first = line.first, "•§▪◦-–—*·".contains(first) {
                line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
            let letters = line.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 2 else { continue }
            if line.count > limit {
                let cut = line.prefix(limit)
                let trimmed = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
                return trimmed.trimmingCharacters(in: .whitespaces) + "…"
            }
            return line
        }
        return ""
    }
}
