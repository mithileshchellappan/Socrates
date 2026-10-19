import CoreGraphics
import Foundation
import ImageIO
import NaturalLanguage
import StudyCore
import UniformTypeIdentifiers
// PDFKit re-exports AppKit/UIKit; only PDFDocument/PDFPage/PDFOutline are used here, and the
// internal import keeps those modules out of Documents' interface (as Capture's DeckText).
internal import PDFKit
internal import Vision

/// Reads a document's text per page (docs/plan-docs.md §4 "Text"): PDF with PDFKit (Vision OCR for
/// pages with almost no text), Word / OpenDocument / RTF with `NSAttributedString` (Mac), Pages
/// through the preview PDF inside the file, plain text and Markdown, images by Vision OCR. One
/// page in memory at a time (a PDF page is read, and rendered for OCR, inside its own autorelease
/// pool); always off the main actor, in a detached task at `.utility`.
///
/// Every failure is a `DocumentReadError` with one readable sentence; PDFKit, Vision and Swift
/// messages go to the log only (privately).
public enum DocumentExtractor {
    /// Characters per part when flowing text (Word, RTF, text) is cut into "pages".
    public static let partLength = 4_000
    /// A PDF page with fewer letters than this is read by OCR (a scanned page).
    static let ocrLetterMinimum = 40
    /// The long edge, in pixels, a PDF page or an image is read by OCR at.
    static let ocrLongEdge: CGFloat = 2_000
    /// Outline entries kept (a handbook's table of contents fits).
    static let outlineLimit = 300

    /// The text of the file at `url` (a BlobStore file or a dropped file), or a `DocumentReadError`
    /// with the readable sentence. Cancelling the caller stops reading between pages.
    public static func extract(fileAt url: URL, type: UTType) async throws -> ExtractedDocument {
        guard let kind = StudyDocument.fileKind(for: type) else { throw DocumentReadError.unsupported }
        let work = Task.detached(priority: .utility) { () async throws -> ExtractedDocument in
            try await read(url, kind: kind, type: type)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// The text of a PDF's first pages, at most `characters` (PDFKit's text only, no OCR: quick
    /// enough for the agent panel's send), with its page count; nil when it is not a readable PDF.
    /// The agent panel sends this for a PDF too long to send whole (`<attached_file>`).
    public static func leadingText(ofPDFAt url: URL, characters: Int) async -> (text: String, pageCount: Int)? {
        await Task.detached(priority: .utility) { () -> (text: String, pageCount: Int)? in
            guard let document = PDFDocument(url: url), !document.isLocked else { return nil }
            var text = ""
            for index in 0..<document.pageCount where text.count < characters {
                let page = autoreleasepool { clean(document.page(at: index)?.string ?? "") }
                if !page.isEmpty { text += (text.isEmpty ? "" : "\n\n") + page }
            }
            return (text.count > characters ? String(text.prefix(characters)) + "…" : text, document.pageCount)
        }.value
    }

    /// Pages and outline as read, before the checks every kind shares.
    struct RawText {
        var pages: [ExtractedPage]
        var outline: [DocumentSection] = []
    }

    static func read(_ url: URL, kind: StudyDocument.FileKind, type: UTType) async throws -> ExtractedDocument {
        let raw: RawText
        switch kind {
        case .pdf: raw = try await readPDF(at: url)
        case .image: raw = try await readImage(at: url)
        case .text: raw = try readPlainText(at: url)
        case .word, .richText: raw = try readAttributed(at: url, type: type)
        case .pages: raw = try await readPages(at: url)
        }
        try Task.checkCancellation()
        guard raw.pages.contains(where: { !$0.text.isEmpty }) else { throw DocumentReadError.noText }
        let texts = raw.pages.map(\.text)
        return ExtractedDocument(
            pages: raw.pages, outline: raw.outline, language: language(of: texts), textSHA256: StudyDocument.textSHA256(of: texts)
        )
    }

    // MARK: - PDF

    static func readPDF(at url: URL) async throws -> RawText {
        guard let document = PDFDocument(url: url) else { throw DocumentReadError.unreadable }
        if document.isLocked {
            throw DocumentReadError("This PDF is locked with a password. Remove the password and add it again.")
        }
        let outline = outline(of: document)
        var pages: [ExtractedPage] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let number = index + 1
            // One page at a time: its text (and, for a scan, its bitmap) in its own pool.
            let (text, label, image) = autoreleasepool { () -> (String, String, CGImage?) in
                guard let page = document.page(at: index) else { return ("", "", nil) }
                let text = clean(page.string ?? "")
                let label = page.label ?? ""
                let image = letterCount(text) < ocrLetterMinimum ? render(page) : nil
                return (text, label == String(number) ? "" : label, image)
            }
            var pageText = text
            var isOCR = false
            if let image, let read = await recognize(image), letterCount(read) > letterCount(text) {
                pageText = read
                isOCR = true
            }
            let heading = outline.first { $0.page == number }?.title ?? heading(in: pageText)
            pages.append(ExtractedPage(pageNumber: number, label: label, heading: heading, text: pageText, isOCR: isOCR))
        }
        return RawText(pages: pages, outline: outline)
    }

    /// The PDF's own outline (bookmarks), at most `outlineLimit` entries, levels 1–4.
    static func outline(of document: PDFDocument) -> [DocumentSection] {
        guard let root = document.outlineRoot else { return [] }
        var sections: [DocumentSection] = []
        func walk(_ node: PDFOutline, level: Int) {
            for index in 0..<node.numberOfChildren {
                guard sections.count < outlineLimit, let child = node.child(at: index) else { return }
                let title = clip(clean(child.label ?? "").split(whereSeparator: \.isNewline).joined(separator: " "), 120)
                let target = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
                if !title.isEmpty, let target {
                    let number = document.index(for: target) + 1
                    if number >= 1, number <= document.pageCount {
                        sections.append(DocumentSection(title: title, page: number, level: level))
                    }
                }
                if level < 4 { walk(child, level: level + 1) }
            }
        }
        walk(root, level: 1)
        return sections
    }

    /// The page as a grey bitmap, long edge at most `ocrLongEdge` pixels, the page's rotation
    /// applied (the way it is read on screen).
    static func render(_ page: PDFPage) -> CGImage? {
        guard let reference = page.pageRef else { return nil }
        let box = reference.getBoxRect(.cropBox)
        let angle = ((reference.rotationAngle % 360) + 360) % 360
        let size = angle == 90 || angle == 270 ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width > 1, size.height > 1 else { return nil }
        let scale = min(ocrLongEdge / max(size.width, size.height), 8)
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // The page's /Rotate turns it clockwise for display.
        switch angle {
        case 90:
            context.translateBy(x: 0, y: size.height)
            context.rotate(by: -.pi / 2)
        case 180:
            context.translateBy(x: size.width, y: size.height)
            context.rotate(by: .pi)
        case 270:
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        default:
            break
        }
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(reference)
        return context.makeImage()
    }

    // MARK: - Images

    static func readImage(at url: URL) async throws -> RawText {
        let image: CGImage? = autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(ocrLongEdge),
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { throw DocumentReadError.unreadable }
        let text = await recognize(image) ?? ""
        return RawText(pages: [ExtractedPage(pageNumber: 1, heading: heading(in: text), text: text, isOCR: true)])
    }

    // MARK: - OCR

    /// Vision text recognition (accurate, German and English, language correction), lines top to
    /// bottom; nil when Vision fails (logged).
    static func recognize(_ image: CGImage) async -> String? {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "de-DE"), Locale.Language(identifier: "en-US")]
        request.usesLanguageCorrection = true
        do {
            let observations = try await request.perform(on: image)
            var boxes: [(text: String, rect: CGRect)] = observations.compactMap { observation in
                let text = observation.transcript.trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : (text, observation.boundingBox.cgRect)
            }
            // Normalized coordinates, origin at the bottom left: the top line first.
            boxes.sort { $0.rect.midY > $1.rect.midY }
            var lines: [[(text: String, rect: CGRect)]] = []
            for box in boxes {
                if let first = lines.last?.first, abs(first.rect.midY - box.rect.midY) < max(first.rect.height, box.rect.height) * 0.5 {
                    lines[lines.count - 1].append(box)
                } else {
                    lines.append([box])
                }
            }
            return lines.map { line in line.sorted { $0.rect.minX < $1.rect.minX }.map(\.text).joined(separator: " ") }
                .joined(separator: "\n")
        } catch {
            DocumentsModule.log.error("OCR failed: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    // MARK: - Plain text and Markdown

    static func readPlainText(at url: URL) throws -> RawText {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw DocumentReadError.unreadable
        }
        // UTF-8, else Latin-1 (which reads any bytes).
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        let lines = clean(text).split(separator: "\n", omittingEmptySubsequences: false).map { line in
            Line(text: String(line), isHeading: line.hasPrefix("#") && line.drop { $0 == "#" }.first == " ")
        }
        return RawText(pages: parts(of: lines))
    }

    // MARK: - Flowing text

    /// A paragraph of flowing text and whether its source marks it as a heading (a Markdown
    /// `#`, a large or bold Word paragraph).
    struct Line {
        var text: String
        var isHeading: Bool
    }

    /// Flowing text cut into parts of at most `partLength` characters at paragraph ends (a
    /// paragraph longer than that at sentence ends), numbered from 1; each part's heading is its
    /// first marked heading, else the first line that reads like one.
    static func parts(of lines: [Line]) -> [ExtractedPage] {
        var pieces: [Line] = []
        for line in lines {
            if line.text.count <= partLength {
                pieces.append(line)
            } else {
                pieces += split(line.text).map { Line(text: $0, isHeading: false) }
            }
        }
        var parts: [[Line]] = []
        var current: [Line] = []
        var length = 0
        for piece in pieces {
            let added = piece.text.count + (current.isEmpty ? 0 : 1)
            if !current.isEmpty, length + added > partLength {
                parts.append(current)
                current = []
                length = 0
            }
            length += piece.text.count + (current.isEmpty ? 0 : 1)
            current.append(piece)
        }
        if !current.isEmpty { parts.append(current) }
        var pages: [ExtractedPage] = []
        for part in parts {
            let text = part.map(\.text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let marked = part.first { $0.isHeading && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { clip(String($0.text.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces), 120) }
            pages.append(ExtractedPage(pageNumber: pages.count + 1, heading: marked ?? heading(in: text), text: text))
        }
        return pages
    }

    /// A paragraph longer than a part, cut at sentence ends (else at a space, else hard).
    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var rest = Substring(text)
        while rest.count > partLength {
            let window = rest.prefix(partLength)
            var cut = window.endIndex
            if let end = window.lastIndex(where: { ".!?".contains($0) }), window.distance(from: window.startIndex, to: end) > partLength / 2 {
                cut = window.index(after: end)
            } else if let space = window.lastIndex(where: \.isWhitespace), window.distance(from: window.startIndex, to: space) > partLength / 2 {
                cut = space
            }
            pieces.append(String(rest[rest.startIndex..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...]
        }
        if !rest.isEmpty { pieces.append(String(rest).trimmingCharacters(in: .whitespaces)) }
        return pieces.filter { !$0.isEmpty }
    }

    // MARK: - Headings

    /// The first line of `text` that reads like a section heading: a Markdown heading, "§ 7 …",
    /// "4.2 Prüfungen", or a short line followed by a blank line. Nil when none does.
    static func heading(in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where !line.isEmpty && line.count <= 120 {
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return clip(title, 120) }
                continue
            }
            if isParagraphHeading(line) || isNumberedHeading(line) { return clip(line, 120) }
            let next = index + 1 < lines.count ? lines[index + 1] : nil
            if next?.isEmpty == true, index > 0 || lines.count > 2, isShortHeading(line) { return line }
        }
        return nil
    }

    /// "§ 7 Prüfungen", "§7 Wiederholung".
    static func isParagraphHeading(_ line: String) -> Bool {
        guard line.hasPrefix("§") else { return false }
        let rest = line.dropFirst().drop { $0 == " " }
        guard let first = rest.first, first.isNumber else { return false }
        let words = rest.drop { $0.isNumber || $0 == "." || $0 == "a" || $0 == "b" }.split(separator: " ")
        return !words.isEmpty && words.count <= 12 && !line.hasSuffix(",")
    }

    /// "3 Prüfungsanmeldung", "4.2 Prüfungen", "2.1. Module": a number, then a capitalised word
    /// of at least four letters, a short line not ending like a sentence.
    static func isNumberedHeading(_ line: String) -> Bool {
        guard let first = line.first, first.isNumber, line.count <= 80 else { return false }
        let number = line.prefix { $0.isNumber || $0 == "." }
        guard number.count <= 8, number.filter(\.isNumber).count <= 4 else { return false }
        let rest = line.dropFirst(number.count)
        guard rest.first == " " else { return false }
        let words = rest.split(separator: " ")
        guard let word = words.first, words.count <= 10, word.first?.isUppercase == true, word.filter(\.isLetter).count >= 4 else { return false }
        guard let last = line.last, !".,;:".contains(last) else { return false }
        return !rest.contains { $0.isNumber }
    }

    /// A short line that can stand as a title: capitalised, ≤ 80 characters, not a sentence.
    static func isShortHeading(_ line: String) -> Bool {
        guard line.count >= 3, line.count <= 80, let first = line.first, first.isUppercase || first.isNumber else { return false }
        guard let last = line.last, !".,;:".contains(last) else { return false }
        return line.split(separator: " ").count <= 10 && line.filter(\.isLetter).count >= 3
    }

    // MARK: - Text

    /// Line ends as "\n", without NULs and soft hyphens, trimmed.
    static func clean(_ text: String) -> String {
        var output = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        output.removeAll { $0 == "\u{0}" || $0 == "\u{00AD}" || $0 == "\u{FEFF}" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func letterCount(_ text: String) -> Int {
        var count = 0
        for character in text where character.isLetter { count += 1 }
        return count
    }

    static func clip(_ text: String, _ count: Int) -> String {
        guard text.count > count else { return text }
        return String(text.prefix(max(0, count - 1))) + "…"
    }

    /// BCP 47 of the text ("de", "en") from its first few thousand characters; "" when unknown.
    static func language(of pages: [String]) -> String {
        var sample = ""
        for page in pages where !page.isEmpty {
            sample += page + "\n"
            if sample.count > 6_000 { break }
        }
        guard !sample.isEmpty else { return "" }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(sample.prefix(6_000)))
        return recognizer.dominantLanguage.map(\.rawValue) ?? ""
    }
}
