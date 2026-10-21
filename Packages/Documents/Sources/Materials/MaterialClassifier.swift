import CoreGraphics
import Foundation
import StudyCore
// PDFKit re-exports AppKit/UIKit; only PDFDocument / PDFPage / PDFOutline are used, and the
// internal import keeps them out of the module's interface (as Documents' extractor).
internal import PDFKit

/// Tells a book or a paper from slides by the PDF's pages, in code (docs/plan-materials.md §2.4):
/// the page count, the crop boxes of pages 1–5, the text of pages 1–8 and the outline, read off
/// the main thread within `budget` (what is not read by then does not count). No model.
///
/// - most of pages 1–5 landscape (width > 1.15 × height) → slides (smart import, unchanged);
/// - portrait and (an ISBN-10/13 in pages 1–8, or ≥ 120 pages with a contents page or ≥ 5
///   top-level outline entries) → book;
/// - portrait, ≤ 60 pages and ("Abstract" / "Zusammenfassung" on page 1–2, or a DOI or an arXiv
///   identifier on page 1) → paper;
/// - anything else → other (filed as today; a reference on the Materials screen).
public enum MaterialClassifier {
    public enum Kind: String, Sendable, Hashable {
        case slides
        case book
        case paper
        case other

        /// The material kind it becomes on the Materials screen (slides and others: a reference).
        public var materialKind: MaterialKind {
            switch self {
            case .book: .book
            case .paper: .paper
            case .slides, .other: .reference
            }
        }

        /// A book or a paper: a course material wherever it is dropped.
        public var isMaterial: Bool { self == .book || self == .paper }
    }

    /// What the classifier read (also what the drop's HUD and toast show, and what matching a
    /// window drop to a course reads).
    public struct Reading: Sendable, Hashable {
        public var kind: Kind
        public var pageCount: Int
        /// The PDF's own Title and Author metadata (untrusted text).
        public var title: String?
        public var author: String?
        /// The text of the first pages read (≤ 6,000 characters): the title page's words.
        public var leadingText: String
        public var isbn: String?
        public var doi: String?
        public var arxivID: String?

        public init(
            kind: Kind, pageCount: Int, title: String? = nil, author: String? = nil, leadingText: String = "", isbn: String? = nil,
            doi: String? = nil, arxivID: String? = nil
        ) {
            self.kind = kind
            self.pageCount = pageCount
            self.title = title
            self.author = author
            self.leadingText = leadingText
            self.isbn = isbn
            self.doi = doi
            self.arxivID = arxivID
        }
    }

    /// The HUD's budget (DESIGN: the drop HUD shows within 300 ms).
    public static let budget: Duration = .milliseconds(300)
    static let landscapeRatio: CGFloat = 1.15
    static let bookPages = 120
    static let paperPages = 60
    static let outlineEntries = 5

    /// The kind of the PDF at `url`; `.other` when it cannot be opened.
    public static func kind(ofPDFAt url: URL) async -> Kind {
        await read(pdfAt: url)?.kind ?? .other
    }

    /// The kind and what was read for it; nil when the file is not a readable PDF.
    public static func read(pdfAt url: URL) async -> Reading? {
        await Task.detached(priority: .userInitiated) { classify(url) }.value
    }

    static func classify(_ url: URL) -> Reading? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else { return nil }
        let clock = ContinuousClock()
        let started = clock.now
        let count = document.pageCount
        let attributes = document.documentAttributes ?? [:]
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String).flatMap(Self.clean)
        let author = (attributes[PDFDocumentAttribute.authorAttribute] as? String).flatMap(Self.clean)

        // Pages 1–5: landscape or portrait.
        var landscape = 0
        var measured = 0
        for index in 0..<min(5, count) {
            guard let page = document.page(at: index) else { continue }
            var box = page.bounds(for: .cropBox).size
            if page.rotation % 180 != 0 { box = CGSize(width: box.height, height: box.width) }
            guard box.width > 0, box.height > 0 else { continue }
            measured += 1
            if box.width > landscapeRatio * box.height { landscape += 1 }
        }
        if measured > 0, landscape * 2 > measured {
            return Reading(kind: .slides, pageCount: count, title: title, author: author)
        }

        // Pages 1–8: their text (what fits the budget).
        var texts: [String] = []
        for index in 0..<min(8, count) {
            if clock.now - started > budget { break }
            let text = autoreleasepool { document.page(at: index)?.string ?? "" }
            texts.append(text)
        }
        let leading = String(texts.joined(separator: "\n\n").prefix(6_000))
        let outline = document.outlineRoot?.numberOfChildren ?? 0
        let isbn = texts.lazy.compactMap(Self.isbn(in:)).first
        let doi = texts.first.flatMap(Self.doi(in:))
        let arxiv = texts.first.flatMap(Self.arxivID(in:))
        let contents = texts.contains(where: Self.hasContentsHeading)

        var kind = Kind.other
        if isbn != nil || (count >= bookPages && (contents || outline >= outlineEntries)) {
            kind = .book
        } else if count <= paperPages, doi != nil || arxiv != nil || texts.prefix(2).contains(where: Self.hasAbstractHeading) {
            kind = .paper
        }
        return Reading(kind: kind, pageCount: count, title: title, author: author, leadingText: leading, isbn: isbn, doi: doi, arxivID: arxiv)
    }

    // MARK: - Signs

    /// An ISBN-10 or ISBN-13 after the word "ISBN" whose check digit holds.
    static func isbn(in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"ISBN(?:-1[03])?:?\s*((?:97[89][\s-]?)?(?:\d[\s-]?){9}[\dXx])"#) else { return nil }
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range(at: 1), in: text) else { continue }
            let digits = text[range].filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
            if isValidISBN(digits) { return digits }
        }
        return nil
    }

    static func isValidISBN(_ digits: String) -> Bool {
        let values = digits.map { $0 == "X" ? 10 : Int(String($0)) ?? -1 }
        guard !values.contains(-1) else { return false }
        if values.count == 10 {
            let sum = values.enumerated().reduce(0) { $0 + (10 - $1.offset) * $1.element }
            return sum % 11 == 0
        }
        if values.count == 13, !values.contains(10) {
            let sum = values.enumerated().reduce(0) { $0 + ($1.offset % 2 == 0 ? 1 : 3) * $1.element }
            return sum % 10 == 0
        }
        return false
    }

    /// A DOI ("10.5555/12345678").
    static func doi(in text: String) -> String? {
        firstMatch(#"\b10\.\d{4,9}/[^\s"<>]+"#, in: text).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)")) }
    }

    /// An arXiv identifier ("arXiv:2401.01234").
    static func arxivID(in text: String) -> String? {
        guard let match = firstMatch(#"arXiv:\s?\d{4}\.\d{4,5}(?:v\d+)?"#, in: text) else { return nil }
        return String(match.drop { $0 != ":" }.dropFirst()).trimmingCharacters(in: .whitespaces)
    }

    /// A line that is a contents heading ("Contents", "Table of Contents", "Inhaltsverzeichnis").
    static func hasContentsHeading(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let folded = TopicKey.fold(String(line))
            return folded == "contents" || folded == "table of contents" || folded == "inhaltsverzeichnis" || folded == "inhalt"
                || folded == "brief contents"
        }
    }

    /// A line starting with "Abstract" or "Zusammenfassung".
    static func hasAbstractHeading(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            let folded = TopicKey.fold(String(line))
            return folded.hasPrefix("abstract") || folded.hasPrefix("zusammenfassung")
        }
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    static func clean(_ text: String) -> String? {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? nil : String(flat.prefix(200))
    }
}
