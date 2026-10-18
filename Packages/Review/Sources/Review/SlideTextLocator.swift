import CoreGraphics
import Foundation
// PDFKit re-exports AppKit/UIKit; only PDFDocument/PDFPage text geometry is used here, and the
// internal import keeps those modules out of Review's interface (as Capture's DeckText).
internal import PDFKit

/// Where a span of a slide's text sits on the page, for the professor's pins (docs/plan-m4.md
/// §5): the pin goes after the end of the line its `anchor_text` ends on. Looked up with PDFKit
/// on the deck's PDF, once per page and text (cached), off the main actor.
public actor SlideTextLocator {
    private let url: URL
    private var document: PDFDocument?
    private var opened = false
    private var cache: [Key: Point] = [:]

    private struct Key: Hashable {
        var page: Int
        var text: String
    }

    /// A spot on the page, 0…1 from its top left.
    public struct Point: Hashable, Sendable {
        public var x: Double
        public var y: Double
        /// The cache's mark for a text that is not on the page (its pin goes to the corner).
        static let missing = Point(x: -1, y: -1)
        var isMissing: Bool { x < 0 }
    }

    public init(url: URL) {
        self.url = url
    }

    /// The trailing end of the line `text` ends on, on 1-based `page`, as a fraction of the
    /// page's crop box from its top left (x the line's right edge, y its middle). Nil when the
    /// text is not found (whitespace, case, quotes and dashes folded), or the page is rotated.
    public func endOfLine(of text: String, page: Int) -> Point? {
        let key = Key(page: page, text: text)
        if let cached = cache[key] { return cached.isMissing ? nil : cached }
        let point = locate(text, page: page)
        cache[key] = point ?? .missing
        return point
    }

    private func locate(_ text: String, page number: Int) -> Point? {
        if !opened {
            opened = true
            document = PDFDocument(url: url)
        }
        guard let document, number >= 1, number <= document.pageCount,
              let page = document.page(at: number - 1), page.rotation % 360 == 0,
              let pageText = page.string
        else { return nil }
        let haystack = Folded(pageText)
        let needle = Folded(text)
        guard !needle.units.isEmpty, let match = haystack.range(of: needle) else { return nil }
        // The whole line the anchor's last character is on.
        guard match.length > 0,
              let selection = page.selection(for: NSRange(location: match.location + match.length - 1, length: 1))
        else { return nil }
        selection.extendForLineBoundaries()
        let line = selection.bounds(for: page)
        guard !line.isEmpty else { return nil }
        let box = page.bounds(for: .cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        return Point(
            x: min(1, max(0, (line.maxX - box.minX) / box.width)),
            y: min(1, max(0, 1 - (line.midY - box.minY) / box.height))
        )
    }
}

/// Text folded for matching an anchor against a page: lower case, curly quotes and dashes made
/// plain, ligatures spelled out, whitespace left out (a PDF breaks lines, and words after a
/// hyphen, wherever its layout did); each unit remembers its UTF-16 offset in the original.
private struct Folded {
    var units: [UInt16] = []
    var origins: [Int] = []

    init(_ text: String) {
        for (offset, unit) in text.utf16.enumerated() {
            for folded in Self.fold(unit) {
                units.append(folded)
                origins.append(offset)
            }
        }
    }

    /// The original NSRange of `needle` in this text.
    func range(of needle: Folded) -> NSRange? {
        let count = needle.units.count
        guard count > 0, units.count >= count else { return nil }
        let first = needle.units[0]
        var start = 0
        while start + count <= units.count {
            if units[start] == first, Array(units[start..<(start + count)]) == needle.units {
                let lower = origins[start]
                let upper = origins[start + count - 1] + 1
                return NSRange(location: lower, length: upper - lower)
            }
            start += 1
        }
        return nil
    }

    private static func fold(_ unit: UInt16) -> [UInt16] {
        switch unit {
        case 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20, 0xA0, 0x2028, 0x2029: return []
        case 0x2018, 0x2019, 0x201A, 0x2032: return [0x27]
        case 0x201C, 0x201D, 0x201E, 0x2033: return [0x22]
        case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2212: return [0x2D]
        case 0xFB00: return [0x66, 0x66]
        case 0xFB01: return [0x66, 0x69]
        case 0xFB02: return [0x66, 0x6C]
        case 0xFB03: return [0x66, 0x66, 0x69]
        case 0xFB04: return [0x66, 0x66, 0x6C]
        case 0x41...0x5A: return [unit + 0x20]
        default: return [unit]
        }
    }
}
