import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

// The agent writes GitHub Markdown, and one `Text` draws only its inline part. An answer's text
// is cut into blocks by the shared parser (StudyPageFormat's `MarkdownBlock`, moved there from
// here in ln: paragraphs, headings, lists, tables, code, quotes, rules); every block's words still
// go through `AnswerText`, so inline Markdown and checked chips work in each paragraph, item and
// table cell.

/// One Markdown block of an answer: the shared parser's block (alert callouts off, so an answer
/// reads as it always has).
typealias AnswerMarkdownBlock = MarkdownBlock

/// An answer's inks on the panel's opaque surface (#f8f8fa / #222225; the phone's content surface),
/// as solid colours: never the hierarchical `.secondary`, which AppKit draws vibrant in the
/// inspector column and as black 49.8 % (3.9:1 on #f8f8fa) on the compact panel (docs/DESIGN.md
/// §3.1, §8.6).
enum AnswerInk {
    /// The words: DESIGN's secondary label, #6e6e73 / #a1a1a6 (4.8:1 / 6.2:1 on the panel).
    static func body(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255) : Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
    }

    /// Bold, headings, table headers, inline code and code blocks: the label, #1d1d1f / #f5f5f7.
    static func emphasis(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255) : Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255)
    }

    /// Bullets and a quote's bar: DESIGN's tertiary label, #a1a1a6 / #6e6e73.
    static func quiet(_ scheme: ColorScheme) -> Color {
        body(scheme == .dark ? .light : .dark)
    }

    /// Behind inline code: `QuietFill` (rgb(120,120,128) at 10 % / 20 %), as a code block's.
    static func codeFill(_ scheme: ColorScheme) -> Color {
        Color(red: 120 / 255, green: 120 / 255, blue: 128 / 255).opacity(scheme == .dark ? 0.20 : 0.10)
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

/// An answer's text as its Markdown blocks, in the answer's grey (`AnswerInk.body`) with its
/// emphasis (bold, headings, table headers, code) in `AnswerInk.emphasis`: ONE sparkle at the
/// start of the first block when `sparkle`.
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
            words(text, sparkle: sparkle, size: metrics.text + (level <= 2 ? 1 : 0), weight: .semibold, ink: AnswerInk.emphasis(colorScheme))
                .padding(.top, 2)
        case .rule:
            Hairline()
        case .list(let items):
            // The sparkle goes in the first item's words (after its marker).
            list(items, sparkle: sparkle)
        case .table, .code, .quote, .callout:
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

    /// A list: its markers right-aligned in one column as wide as the widest (at least 10 pt);
    /// bullets quiet, numbers in the words' grey (a number is read).
    private func list(_ items: [AnswerMarkdownBlock.ListItem], sparkle: Bool) -> some View {
        let widest = items.map(\.marker.count).max() ?? 1
        let markerWidth = max(10, CGFloat(widest) * metrics.text * 0.6)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(verbatim: item.marker)
                        .font(.system(size: metrics.text).monospacedDigit())
                        .foregroundStyle(item.marker.hasSuffix(".") ? AnswerInk.body(colorScheme) : AnswerInk.quiet(colorScheme))
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
        case .code(let code, _):
            ScrollView(.horizontal) {
                Text(verbatim: code)
                    .font(.system(size: metrics.text - 1.5, design: .monospaced))
                    .foregroundStyle(AnswerInk.emphasis(colorScheme))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(QuietFill(), in: .rect(cornerRadius: 8))
        case .quote(let text), .callout(_, let text):
            words(text, sparkle: false)
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(AnswerInk.quiet(colorScheme)).frame(width: 2)
                }
        case .paragraph, .heading, .rule, .list:
            EmptyView()
        }
    }

    /// A table's cells: the header semibold in the emphasis ink over a full hairline, rows between
    /// half-strength ones.
    private func tableGrid(_ table: AnswerMarkdownBlock.Table) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    words(cell, sparkle: false, size: metrics.text - 1, weight: .semibold, ink: AnswerInk.emphasis(colorScheme))
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

    /// Words with inline Markdown and their checked chips: one `Text`, in `ink` (the body grey
    /// unless given), its bold and inline code in the emphasis ink.
    private func words(_ text: String, sparkle: Bool, size: CGFloat? = nil, weight: Font.Weight = .regular, ink: Color? = nil) -> some View {
        let answer = AnswerText(text, check: text.contains("[[") ? check : nil, logs: logs, openLecture: openLecture, prefixes: prefixes)
        let textSize: CGFloat = size ?? metrics.text
        let style = AnswerText.RunStyle(
            codeSize: textSize - 1.5, weight: weight, emphasis: AnswerInk.emphasis(colorScheme), codeFill: AnswerInk.codeFill(colorScheme)
        )
        let drawn = answer.text(sparkle: sparkle, style: style)
        return Group {
            if answer.hasChips {
                drawn.textRenderer(AnswerChipRenderer(colorScheme: colorScheme))
            } else {
                drawn.textSelection(.enabled)
            }
        }
        .font(.system(size: textSize, weight: weight))
        .lineSpacing(metrics.answerLineSpacing)
        .foregroundStyle(ink ?? AnswerInk.body(colorScheme))
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
