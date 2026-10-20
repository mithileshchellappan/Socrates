import StudyCore
import StudyUI
import SwiftUI

// The agent writes GitHub Markdown, and one `Text` draws only its inline part. An answer's text
// is cut into blocks here (paragraphs, headings, lists, tables, code, quotes, rules); every
// block's words still go through `AnswerText`, so inline Markdown and checked chips work in each
// paragraph, item and table cell.

/// One Markdown block of an answer.
enum AnswerMarkdownBlock: Hashable {
    case paragraph(String)
    /// `#` to `######`: `level` 1 to 6.
    case heading(level: Int, text: String)
    case list([ListItem])
    case table(Table)
    case code(String)
    case quote(String)
    case rule

    struct ListItem: Hashable {
        /// "•" (depth 0) or "◦" for a bullet, "3." for a numbered item.
        var marker: String
        var depth: Int
        var text: String
    }

    struct Table: Hashable {
        enum Align: Hashable { case leading, center, trailing }

        var header: [String]
        /// One per column.
        var alignments: [Align]
        /// Each row has exactly one cell per column.
        var rows: [[String]]
    }

    /// The blocks of `text`. While an answer streams, its last line may be cut: a table row
    /// short of cells gets empty ones, an open code fence runs to the end.
    static func blocks(_ text: String) -> [AnswerMarkdownBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [AnswerMarkdownBlock] = []
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
            blocks.append(.quote(quote.joined(separator: "\n")))
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
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(code.joined(separator: "\n")))
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

/// The answer's sparkle where it stands apart from a paragraph (before a list, a table, change
/// rows, the skeleton line): drawn as the paragraph's inline sparkle, at the answer's text size,
/// so every answer's one sparkle has one size and the skeleton-to-text swap keeps it.
struct AnswerSparkle: View {
    @Environment(\.agentThreadMetrics) private var metrics

    var body: some View {
        Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(Color.ai))")
            .font(.system(size: metrics.text))
            .accessibilityLabel(Text("AI"))
    }
}

/// An answer's text as its Markdown blocks, in the answer's grey: ONE sparkle at the start of
/// the first block when `sparkle`.
struct AnswerMarkdownView: View {
    let text: String
    let sparkle: Bool
    let check: CitationCheck
    /// Dropped markers are logged (not while streaming).
    let logs: Bool
    let openLecture: Lecture.ID?
    /// "L2 · " before lecture chips, decided for the whole answer.
    let prefixes: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.agentThreadMetrics) private var metrics

    var body: some View {
        let blocks = AnswerMarkdownBlock.blocks(text)
        // The sparkle goes on the first block that is not a rule.
        let first = blocks.firstIndex { $0 != .rule }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, sparkle: sparkle && index == first)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: AnswerMarkdownBlock, sparkle: Bool) -> some View {
        switch block {
        case .paragraph(let text):
            words(text, sparkle: sparkle)
        case .heading(let level, let text):
            words(text, sparkle: sparkle, size: metrics.text + (level <= 2 ? 1 : 0), weight: .semibold)
                .padding(.top, 2)
        case .rule:
            Hairline()
        case .list(let items):
            // The sparkle goes in the first item's words (after its marker).
            list(items, sparkle: sparkle)
        case .table, .code, .quote:
            if sparkle {
                // On its own line above: a figure keeps the answer's leading edge.
                VStack(alignment: .leading, spacing: 4) {
                    AnswerSparkle()
                    figure(block)
                }
            } else {
                figure(block)
            }
        }
    }

    /// A list: its markers right-aligned in one column as wide as the widest (at least 10 pt).
    private func list(_ items: [AnswerMarkdownBlock.ListItem], sparkle: Bool) -> some View {
        let widest = items.map(\.marker.count).max() ?? 1
        let markerWidth = max(10, CGFloat(widest) * metrics.text * 0.6)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: item.marker)
                        .font(.system(size: metrics.text).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: markerWidth, alignment: .trailing)
                    words(item.text, sparkle: sparkle && index == 0)
                }
                .padding(.leading, CGFloat(item.depth) * 14)
            }
        }
    }

    @ViewBuilder
    private func figure(_ block: AnswerMarkdownBlock) -> some View {
        switch block {
        case .table(let table):
            // As wide as its cells when that fits the panel; else it scrolls sideways, never
            // squeezing its columns into a word per line.
            ViewThatFits(in: .horizontal) {
                tableGrid(table)
                ScrollView(.horizontal) {
                    tableGrid(table)
                        .fixedSize()
                }
                .scrollIndicators(.automatic)
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(size: metrics.text - 1.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuietFill(), in: .rect(cornerRadius: 8))
        case .quote(let text):
            words(text, sparkle: false)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(width: 2)
                }
        case .paragraph, .heading, .rule, .list:
            EmptyView()
        }
    }

    /// A table's cells: the header semibold over a full hairline, rows between half-strength ones.
    private func tableGrid(_ table: AnswerMarkdownBlock.Table) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    words(cell, sparkle: false, size: metrics.text - 1, weight: .semibold)
                        .gridColumnAlignment(Self.alignment(table.alignments[column]))
                }
            }
            Hairline()
                .gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { offset, row in
                if offset > 0 {
                    Hairline()
                        .opacity(0.5)
                        .gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        words(cell, sparkle: false, size: metrics.text - 1)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Words with inline Markdown and their checked chips: one `Text`.
    private func words(_ text: String, sparkle: Bool, size: CGFloat? = nil, weight: Font.Weight = .regular) -> some View {
        let answer = AnswerText(text, check: text.contains("[[") ? check : nil, logs: logs, openLecture: openLecture, prefixes: prefixes)
        let textSize: CGFloat = size ?? metrics.text
        let codeSize: CGFloat = textSize - 1.5
        return Group {
            if answer.hasChips {
                answer.text(sparkle: sparkle, codeSize: codeSize)
                    .textRenderer(AnswerChipRenderer(colorScheme: colorScheme))
            } else {
                answer.text(sparkle: sparkle, codeSize: codeSize)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: textSize, weight: weight))
        .lineSpacing(metrics.answerLineSpacing)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        // md: a document chip's help is its title.
        .documentChipHelp(answer)
    }

    private static func alignment(_ align: AnswerMarkdownBlock.Table.Align) -> HorizontalAlignment {
        switch align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
