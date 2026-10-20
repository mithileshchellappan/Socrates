import Foundation

// GitHub Markdown cut into blocks (paragraphs, headings, lists, tables, code, quotes, rules and,
// on request, GitHub alert callouts). One `Text` or one TextKit paragraph draws only the inline
// part of a block, so every renderer cuts the text here first: the agent panel's answers
// (ChatUI) and the lecture notes (StudyPageUI). Moved from ChatUI's `AnswerMarkdownBlock`
// (docs/DESIGN.md 1.4: moved, never copied); its behaviour is unchanged when `alerts` is off.

/// One Markdown block.
public enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    /// `#` to `######`: `level` 1 to 6.
    case heading(level: Int, text: String)
    case list([ListItem])
    case table(Table)
    /// A fenced code block and its info string's first word ("python"; "" when none).
    case code(String, language: String)
    case quote(String)
    /// A GitHub alert (`> [!NOTE]`, `> [!WARNING]`, …), only when `alerts` is on: its kind and the
    /// quote's text after the marker line.
    case callout(CalloutKind, String)
    case rule

    public struct ListItem: Hashable, Sendable {
        /// "•" (depth 0) or "◦" for a bullet, "3." for a numbered item.
        public var marker: String
        public var depth: Int
        public var text: String

        public init(marker: String, depth: Int, text: String) {
            self.marker = marker
            self.depth = depth
            self.text = text
        }

        /// A numbered item ("3.").
        public var isNumbered: Bool { marker.hasSuffix(".") }
    }

    public struct Table: Hashable, Sendable {
        public enum Align: Hashable, Sendable { case leading, center, trailing }

        public var header: [String]
        /// One per column.
        public var alignments: [Align]
        /// Each row has exactly one cell per column.
        public var rows: [[String]]

        public init(header: [String], alignments: [Align], rows: [[String]]) {
            self.header = header
            self.alignments = alignments
            self.rows = rows
        }
    }

    /// GitHub's alert kinds. NOTE, TIP and IMPORTANT read as a note; WARNING and CAUTION as a
    /// warning (the renderer's glyph).
    public enum CalloutKind: String, Hashable, Sendable, CaseIterable {
        case note, tip, important, warning, caution

        public var isWarning: Bool { self == .warning || self == .caution }
    }

    /// The blocks of `text`. While text streams, its last line may be cut: a table row short of
    /// cells gets empty ones, an open code fence runs to the end. `alerts`: a quote that starts
    /// with `[!NOTE]` (and the other kinds) is a callout.
    public static func blocks(_ text: String, alerts: Bool = false) -> [MarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var items: [ListItem] = []
        var indents: [Int] = []
        var blankAfterItem = false

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            if alerts, let kind = alertKind(quote[0]) {
                blocks.append(.callout(kind, quote.dropFirst().joined(separator: "\n")))
            } else {
                blocks.append(.quote(quote.joined(separator: "\n")))
            }
            quote = []
        }
        func flushList() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items))
            items = []
            indents = []
            blankAfterItem = false
        }
        func flushAll() {
            flushParagraph()
            flushQuote()
            flushList()
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flushParagraph()
                flushQuote()
                blankAfterItem = !items.isEmpty
                index += 1
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushAll()
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.drop { $0 == "`" || $0 == "~" }.split(separator: " ").first ?? "").lowercased()
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n"), language: language))
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.count, let alignments = separator(lines[index + 1]) {
                flushAll()
                // The header names the columns (a separator still being written has fewer cells).
                let header = cells(trimmed)
                let columns = alignments.prefix(header.count) + Array(repeating: Table.Align.leading, count: max(0, header.count - alignments.count))
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(fitted(cells(row), count: header.count))
                    index += 1
                }
                blocks.append(.table(Table(header: header, alignments: Array(columns), rows: rows)))
                continue
            }
            if let heading = heading(trimmed) {
                flushAll()
                if !heading.text.isEmpty { blocks.append(.heading(level: heading.level, text: heading.text)) }
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushAll()
                blocks.append(.rule)
                index += 1
                continue
            }
            if let item = listItem(line) {
                flushParagraph()
                flushQuote()
                while let last = indents.last, last > item.indent { indents.removeLast() }
                if indents.last != item.indent { indents.append(item.indent) }
                let depth = indents.count - 1
                let marker = item.marker ?? (depth == 0 ? "•" : "◦")
                items.append(ListItem(marker: marker, depth: depth, text: item.text))
                blankAfterItem = false
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph()
                flushList()
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
                continue
            }
            if !items.isEmpty, !blankAfterItem || line.first?.isWhitespace == true, let last = items.indices.last {
                // An item's next line.
                items[last].text += (blankAfterItem ? "\n\n" : "\n") + trimmed
                blankAfterItem = false
                index += 1
                continue
            }
            flushList()
            flushQuote()
            paragraph.append(line.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression))
            index += 1
        }
        flushAll()
        return blocks
    }

    /// `[!NOTE]` (any case, alone on the quote's first line) → its kind.
    static func alertKind(_ line: String) -> CalloutKind? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        return CalloutKind(rawValue: trimmed.dropFirst(2).dropLast().lowercased())
    }

    /// A table's separator line ("|---|:--:|--:|"): its columns' alignments.
    private static func separator(_ line: String) -> [Table.Align]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return nil }
        var alignments: [Table.Align] = []
        for cell in cells(trimmed) {
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments.isEmpty ? nil : alignments
    }

    /// A table line's cells: split at pipes that are not escaped or in a code span, outer pipes
    /// dropped; `<br>` becomes a line break.
    private static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        var inCode = false
        for character in body {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "`" {
                inCode.toggle()
                cell.append(character)
            } else if character == "|", !inCode {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell)
        return cells.map {
            $0.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Exactly `count` cells: extra ones dropped, missing ones empty.
    private static func fitted(_ cells: [String], count: Int) -> [String] {
        Array(cells.prefix(count)) + Array(repeating: "", count: max(0, count - cells.count))
    }

    private static func heading(_ trimmed: String) -> (level: Int, text: String)? {
        let level = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var text = rest.trimmingCharacters(in: .whitespaces)
        // A closing "##".
        if let closing = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(closing) }
        return (level, text)
    }

    private static func isRule(_ trimmed: String) -> Bool {
        let marks = trimmed.filter { !$0.isWhitespace }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    /// "- word", "* word", "+ word", "3. word" or "3) word": its indent (a tab counts 4), the
    /// numbered marker as written (nil for a bullet) and its words.
    private static func listItem(_ line: String) -> (indent: Int, marker: String?, text: String)? {
        var indent = 0
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" {
            indent += first == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        if let first = rest.first, "-*+".contains(first), rest.dropFirst().first == " " {
            return (indent, nil, rest.dropFirst(2).trimmingCharacters(in: .whitespaces))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count) else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delimiter = after.first, delimiter == "." || delimiter == ")", after.dropFirst().first == " " else { return nil }
        return (indent, digits + ".", after.dropFirst(2).trimmingCharacters(in: .whitespaces))
    }
}
