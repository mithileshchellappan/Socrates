import CoreGraphics
import Foundation
import StudyCore
internal import PDFKit

/// A file material's chapters and sections and its printed page numbers, found in code
/// (docs/plan-materials.md §3.1), in this order:
///
/// 1. the PDF outline (level 1 chapters, level 2 sections; deeper levels are not kept);
/// 2. the contents pages ("Contents", "Inhaltsverzeichnis"): lines ending in a page number with a
///    leading "6" / "6.2", printed pages mapped to PDF pages, each kept only when its title is on
///    that page ±2;
/// 3. headings by type size (a line among the first of a page set ≥ 1.4 × the page's body size,
///    reading "6 …", "6.2 …", "Chapter 6", "Kapitel 6");
/// 4. (later) the card's sections (`MaterialCard`, only when none of these found any).
///
/// Exercises / Problems / Übungen / Aufgaben are kind `exercises`; Appendix, Index, Bibliography
/// `back`; what comes before chapter 1 `front`. Keys are `MaterialSection.key` of the number and
/// title (an unnumbered section under its chapter's number), so a re-read keeps them.
///
/// Printed pages: the offset most numeric page labels agree on; else the offset most sampled
/// pages agree on between their index and a number alone at the start or end of their text (a
/// running head or foot); each needs ≥ 60 % of the pages it could be read on. Nil: none known.
public enum SectionReader {
    public struct Result: Sendable, Hashable {
        public var sections: [MaterialSection]
        public var printedOffset: Int?
        public var source: MaterialSectionSource?
    }

    /// Entries are not looked for in books longer than this by type size (the slowest step).
    static let headingPageLimit = 900
    static let sectionLimit = 400
    static let agreement = 0.6

    /// The sections of the material's file and its printed offset. `url`: the PDF (nil for other
    /// files: only the printed offset from the pages' text). `pages`: the document's pages as read.
    public static func read(pdfAt url: URL?, pages: [StudyDocumentPage], materialID: CourseMaterial.ID) async -> Result {
        await Task.detached(priority: .utility) {
            let texts = pages.sorted { $0.pageNumber < $1.pageNumber }
            let offset = printedOffset(pages: texts)
            let pageCount = texts.map(\.pageNumber).max() ?? 0
            var entries: [Entry] = []
            var source: MaterialSectionSource?
            if let url, let document = PDFDocument(url: url), !document.isLocked {
                entries = outline(of: document)
                source = entries.isEmpty ? nil : .outline
                if entries.isEmpty {
                    entries = contents(pages: texts, offset: offset)
                    source = entries.isEmpty ? nil : .contents
                }
                if entries.isEmpty, document.pageCount <= headingPageLimit {
                    entries = headings(of: document)
                    source = entries.isEmpty ? nil : .headings
                }
            }
            let sections = build(entries, materialID: materialID, pageCount: max(pageCount, entries.map(\.page).max() ?? 0),
                                 pages: texts, offset: offset, source: source ?? .outline)
            return Result(sections: sections, printedOffset: offset, source: sections.isEmpty ? nil : source)
        }.value
    }

    /// One heading found: its number ("6.2", "" when none), title, level (1, 2) and PDF page.
    struct Entry: Hashable {
        var number: String
        var title: String
        var level: Int
        var page: Int
    }

    // MARK: - Outline

    static func outline(of document: PDFDocument) -> [Entry] {
        guard var root = document.outlineRoot, root.numberOfChildren > 0 else { return [] }
        // A single top entry holding the rest (the book's own title): its children are the chapters.
        if root.numberOfChildren == 1, let only = root.child(at: 0), only.numberOfChildren >= 3 { root = only }
        var entries: [Entry] = []
        func page(_ node: PDFOutline) -> Int? {
            guard let target = node.destination?.page ?? (node.action as? PDFActionGoTo)?.destination.page else { return nil }
            let index = document.index(for: target)
            return index >= 0 && index < document.pageCount ? index + 1 : nil
        }
        for chapterIndex in 0..<root.numberOfChildren {
            guard entries.count < sectionLimit, let chapter = root.child(at: chapterIndex) else { break }
            if let number = page(chapter), let heading = parse(chapter.label ?? "") {
                entries.append(Entry(number: heading.number, title: heading.title, level: 1, page: number))
            }
            for sectionIndex in 0..<chapter.numberOfChildren {
                guard entries.count < sectionLimit, let section = chapter.child(at: sectionIndex),
                      let number = page(section), let heading = parse(section.label ?? "") else { continue }
                entries.append(Entry(number: heading.number, title: heading.title, level: 2, page: number))
            }
        }
        return entries
    }

    // MARK: - Contents pages

    /// Entries of the contents pages among the first 40: lines ending in a printed page number.
    static func contents(pages: [StudyDocumentPage], offset: Int?) -> [Entry] {
        let head = pages.prefix(40)
        guard let start = head.firstIndex(where: { MaterialClassifier.hasContentsHeading(String($0.text.prefix(400))) }) else { return [] }
        var lines: [(number: String, title: String, level: Int, printed: Int)] = []
        var index = start
        while index < head.endIndex {
            let found = contentsLines(head[index].text)
            if index != start, found.count < 3 { break }
            lines += found
            index = head.index(after: index)
        }
        guard lines.count >= 3 else { return [] }
        // Printed pages to PDF pages: the offset, else the one that finds most titles on their page.
        let shift = offset ?? bestShift(lines.map { ($0.title, $0.printed) }, pages: pages)
        guard let shift else { return [] }
        var entries: [Entry] = []
        for line in lines {
            guard let page = located(line.title, near: line.printed + shift, pages: pages) else { continue }
            entries.append(Entry(number: line.number, title: line.title, level: line.level, page: page))
        }
        return entries.count >= 3 ? entries : []
    }

    /// "6.2 Logical clocks ........ 214", "Chapter 6 Coordination 201", "Preface xv" (roman pages
    /// are left out: front matter).
    static func contentsLines(_ text: String) -> [(number: String, title: String, level: Int, printed: Int)] {
        guard let expression = try? NSRegularExpression(pattern: #"^(.*?\S)[\s.·…_]*?\s+(\d{1,4})$"#) else { return [] }
        var lines: [(String, String, Int, Int)] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 4, line.count <= 160,
                  let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let titleRange = Range(match.range(at: 1), in: line), let pageRange = Range(match.range(at: 2), in: line),
                  let printed = Int(line[pageRange])
            else { continue }
            let label = String(line[titleRange]).trimmingCharacters(in: CharacterSet(charactersIn: " .·…_"))
            guard let heading = parse(label), heading.title.filter(\.isLetter).count >= 3 else { continue }
            let level = heading.number.isEmpty ? 1 : min(2, heading.number.split(separator: ".").count)
            lines.append((heading.number, heading.title, level, printed))
        }
        return lines
    }

    /// The shift (PDF page − printed page, 0…60) under which most titles are found on their page.
    static func bestShift(_ lines: [(title: String, printed: Int)], pages: [StudyDocumentPage]) -> Int? {
        let sample = Array(lines.prefix(12))
        var best: (shift: Int, hits: Int)?
        for shift in 0...60 {
            let hits = sample.filter { found($0.title, onPage: $0.printed + shift, pages: pages) }.count
            if hits > (best?.hits ?? 0) { best = (shift, hits) }
        }
        guard let best, Double(best.hits) >= Double(sample.count) * 0.5 else { return nil }
        return best.shift
    }

    // MARK: - Headings by type size

    static func headings(of document: PDFDocument) -> [Entry] {
        var entries: [Entry] = []
        for index in 0..<document.pageCount {
            guard entries.count < sectionLimit else { break }
            let found: [Entry] = autoreleasepool {
                guard let page = document.page(at: index), let text = page.attributedString, text.length > 0 else { return [] }
                return headingLines(text, page: index + 1)
            }
            entries += found
        }
        return entries
    }

    /// The first five lines of a page set ≥ 1.4 × its body size that read like a numbered heading.
    static func headingLines(_ text: NSAttributedString, page: Int) -> [Entry] {
        var sizes: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let size = pointSize(value) { sizes[(size * 2).rounded() / 2, default: 0] += range.length }
        }
        guard let body = sizes.max(by: { $0.value < $1.value })?.key, body > 0 else { return [] }
        let string = text.string as NSString
        var entries: [Entry] = []
        var location = 0
        var lines = 0
        while location < string.length, lines < 5 {
            let range = string.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            let line = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            lines += 1
            var largest: CGFloat = 0
            text.enumerateAttribute(.font, in: range) { value, _, _ in largest = max(largest, pointSize(value) ?? 0) }
            guard largest >= body * 1.4, line.count <= 100, let heading = parse(line), !heading.number.isEmpty else { continue }
            let level = min(2, heading.number.split(separator: ".").count)
            entries.append(Entry(number: heading.number, title: heading.title, level: level, page: page))
        }
        return entries
    }

    /// A font attribute's point size (AppKit's or UIKit's font, read by key).
    static func pointSize(_ value: Any?) -> CGFloat? {
        guard let font = value as? NSObject, let size = font.value(forKey: "pointSize") as? CGFloat, size > 0 else { return nil }
        return size
    }

    // MARK: - Building

    /// Entries as sections: sorted, given their last pages (up to the next entry of the same or a
    /// higher level), kinds and stable keys.
    static func build(
        _ entries: [Entry], materialID: CourseMaterial.ID, pageCount: Int, pages: [StudyDocumentPage], offset: Int?,
        source: MaterialSectionSource
    ) -> [MaterialSection] {
        guard !entries.isEmpty, pageCount > 0 else { return [] }
        let ordered = entries.enumerated().sorted { ($0.element.page, $0.offset) < ($1.element.page, $1.offset) }.map(\.element)
        let labels = Dictionary(pages.map { ($0.pageNumber, $0.label) }, uniquingKeysWith: { first, _ in first })
        let firstChapter = ordered.firstIndex { $0.level == 1 && ($0.number == "1" || $0.number.hasPrefix("1.")) }
            ?? ordered.firstIndex { $0.level == 1 && !$0.number.isEmpty }
        var sections: [MaterialSection] = []
        var keys: Set<String> = []
        var chapterNumber = ""
        for (index, entry) in ordered.enumerated() {
            let next = ordered[(index + 1)...].first { $0.level <= entry.level && $0.page > entry.page }
            let last = min(pageCount, max(entry.page, (next?.page ?? pageCount + 1) - 1))
            if entry.level == 1 { chapterNumber = entry.number }
            var kind: MaterialSectionKind = entry.level <= 1 ? .chapter : .section
            if isExercises(entry.title) {
                kind = .exercises
            } else if isBackMatter(entry.title) {
                kind = .back
            } else if let firstChapter, index < firstChapter, entry.number.isEmpty {
                kind = .front
            }
            // An unnumbered section is keyed under its chapter's number ("6/Exercises").
            var keyNumber = entry.number.isEmpty && entry.level >= 2 && !chapterNumber.isEmpty ? "\(chapterNumber)/" : entry.number
            var key = MaterialSection.key(number: keyNumber, title: entry.title)
            var copy = 2
            while keys.contains(key) {
                keyNumber = "\(keyNumber)#\(copy)"
                key = MaterialSection.key(number: keyNumber, title: entry.title)
                copy += 1
            }
            keys.insert(key)
            var printed: String?
            if let label = labels[entry.page], !label.isEmpty {
                printed = label
            } else if let offset, entry.page - offset >= 1 {
                printed = String(entry.page - offset)
            }
            sections.append(MaterialSection(
                materialID: materialID, key: key, number: entry.number, title: String(entry.title.prefix(160)), level: entry.level,
                kind: kind, firstPage: entry.page, lastPage: last, printedFirst: printed, source: source, sortOrder: index
            ))
        }
        return sections
    }

    static func isExercises(_ title: String) -> Bool {
        let folded = TopicKey.fold(title)
        return ["exercises", "exercise", "problems", "problem set", "problem sets", "ubungen", "ubungsaufgaben", "aufgaben"]
            .contains { folded == $0 || folded.hasPrefix($0 + " ") }
    }

    static func isBackMatter(_ title: String) -> Bool {
        let folded = TopicKey.fold(title)
        return ["appendix", "appendices", "index", "bibliography", "references", "literatur", "literaturverzeichnis", "anhang",
                "glossary", "stichwortverzeichnis", "register", "sachverzeichnis"]
            .contains { folded == $0 || folded.hasPrefix($0 + " ") }
    }

    // MARK: - Headings' text

    /// "Chapter 6: Coordination" → ("6", "Coordination"); "6.2. Logical clocks" → ("6.2", "Logical
    /// clocks"); "Preface" → ("", "Preface"). Nil for an empty label.
    static func parse(_ label: String) -> (number: String, title: String)? {
        var text = label.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        for word in ["Chapter ", "Kapitel ", "CHAPTER ", "KAPITEL ", "Part ", "Teil "] where text.hasPrefix(word) {
            let rest = text.dropFirst(word.count)
            let number = rest.prefix { $0.isNumber }
            guard !number.isEmpty else { break }
            let title = rest.dropFirst(number.count).drop { $0 == ":" || $0 == "." || $0 == " " || $0 == "–" || $0 == "-" }
            return (String(number), title.isEmpty ? text : String(title))
        }
        let number = text.prefix { $0.isNumber || $0 == "." }
        let digits = number.split(separator: ".")
        if !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.count <= 3 }), number.first?.isNumber == true {
            let rest = text.dropFirst(number.count)
            if rest.first == " " || rest.first == "\u{00A0}" {
                text = rest.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, text.contains(where: \.isLetter) {
                    return (digits.joined(separator: "."), text)
                }
            }
        }
        return ("", label.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The page in `page`'s ±2 whose text holds the title (its first words, folded); nil when none.
    static func located(_ title: String, near page: Int, pages: [StudyDocumentPage]) -> Int? {
        for delta in [0, 1, -1, 2, -2] where found(title, onPage: page + delta, pages: pages) { return page + delta }
        return nil
    }

    /// Whether `title` (its first five words, folded) is on PDF page `page`.
    public static func found(_ title: String, onPage page: Int, pages: [StudyDocumentPage]) -> Bool {
        guard page >= 1, let text = pages.first(where: { $0.pageNumber == page })?.text else { return false }
        let wanted = words(title).prefix(5).joined(separator: " ")
        guard !wanted.isEmpty else { return false }
        return words(text).joined(separator: " ").contains(wanted)
    }

    /// The page in `page`'s ±2 holding `title` (the card's sections are checked with it).
    public static func page(of title: String, near page: Int, pages: [StudyDocumentPage]) -> Int? {
        located(title, near: page, pages: pages)
    }

    static func words(_ text: String) -> [String] {
        TopicKey.fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    // MARK: - Printed pages

    /// PDF page − printed page, agreed by ≥ 60 % of the pages it can be read on (labels first,
    /// then a running head's or foot's number); nil when none is.
    public static func printedOffset(pages: [StudyDocumentPage]) -> Int? {
        var labelled: [Int] = []
        for page in pages where !page.label.isEmpty {
            if let number = Int(page.label) { labelled.append(page.pageNumber - number) }
        }
        if labelled.count >= 5, let offset = agreed(labelled.map { [$0] }) { return offset }
        // A running head's or foot's number: sampled pages past the front matter.
        let body = pages.count > 20 ? Array(pages.dropFirst(pages.count / 10)) : pages
        let step = max(1, body.count / 60)
        var candidates: [[Int]] = []
        for (index, page) in body.enumerated() where index % step == 0 {
            let offsets = printedNumbers(in: page.text).map { page.pageNumber - $0 }
            if !offsets.isEmpty { candidates.append(Array(Set(offsets))) }
        }
        guard candidates.count >= 5 else { return nil }
        return agreed(candidates)
    }

    /// The offset most pages agree on (each page's set of candidates counts once), when ≥ 60 %.
    static func agreed(_ candidates: [[Int]]) -> Int? {
        var counts: [Int: Int] = [:]
        for offsets in candidates { for offset in Set(offsets) where (-50...600).contains(offset) { counts[offset, default: 0] += 1 } }
        guard let best = counts.max(by: { ($0.value, -$0.key) < ($1.value, -$1.key) }) else { return nil }
        return Double(best.value) >= Double(candidates.count) * agreement ? best.key : nil
    }

    /// Numbers alone at the start or end of a page's first two and last two lines ("214",
    /// "214 Chapter 6 Coordination", "6.2 Logical Clocks 215").
    static func printedNumbers(in text: String) -> [Int] {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }
        var numbers: [Int] = []
        for line in Array(lines.prefix(2)) + Array(lines.suffix(2)) {
            let tokens = line.split(separator: " ")
            for token in [tokens.first, tokens.last].compactMap(\.self) {
                guard token.count <= 4, token.allSatisfy(\.isNumber), let number = Int(token), number >= 1 else { continue }
                numbers.append(number)
            }
        }
        return numbers
    }
}
