import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The notes' figure blocks as SwiftUI views (docs/plan-learn-more.md §2.2): drawn inside the
// TextKit document as attachments, in the Ask popover and kept answers, and rendered to images
// for Edit as Note.

/// Display math, centred (`.mblk`: 17 pt, primary).
struct MathBlockView: View {
    let latex: String
    let size: CGFloat

    var body: some View {
        MathImageView(latex: latex, size: size, display: true)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

/// Code: SF Mono on the quiet fill, radius 8, scrolling sideways; on hover the language and Copy
/// at the top right (`.codew`).
struct CodeBlockView: View {
    let code: String
    let language: String
    let size: CGFloat
    /// The notes' content zoom: the padding grows with the text.
    var zoom: CGFloat = 1
    @State private var isHovered = false

    var body: some View {
        ScrollView(.horizontal) {
            Text(Self.highlighted(code, language: language, size: size))
                .lineSpacing(size * 0.5)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, 14 * zoom)
                .padding(.vertical, 12 * zoom)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuietFill(), in: .rect(cornerRadius: 8 * zoom))
        .overlay(alignment: .topTrailing) {
            if isHovered {
                HStack(spacing: 8) {
                    if !language.isEmpty {
                        Text(verbatim: language)
                    }
                    Button("Copy") { Pasteboard.copy(code) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .padding(.trailing, 10)
            }
        }
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Code"))
    }

    /// The code with its tokens coloured (DESIGN 3.1 "Code tokens"; keywords semibold).
    static func highlighted(_ code: String, language: String, size: CGFloat) -> AttributedString {
        var result = AttributedString(code)
        result.font = .system(size: size, design: .monospaced)
        result.foregroundColor = NotesInk.token(nil)
        let utf16 = code.utf16
        for token in CodeLexer.tokens(code, language: language) {
            let lower = utf16.index(utf16.startIndex, offsetBy: token.location, limitedBy: utf16.endIndex) ?? utf16.endIndex
            let upper = utf16.index(lower, offsetBy: token.length, limitedBy: utf16.endIndex) ?? utf16.endIndex
            guard let start = AttributedString.Index(lower, within: result), let end = AttributedString.Index(upper, within: result), start < end else { continue }
            result[start..<end].foregroundColor = NotesInk.token(token.kind)
            if token.kind == .keyword { result[start..<end].font = .system(size: size, weight: .semibold, design: .monospaced) }
        }
        return result
    }
}

/// A GFM table: header semibold primary over a hairline, rows between hairlines, the first column
/// primary medium, the rest in Claude's grey (`.tbl`); wider than the column: it scrolls sideways.
struct TableBlockView: View {
    let table: MarkdownBlock.Table
    let size: CGFloat
    /// The notes' content zoom: the gaps and chips grow with the text.
    var zoom: CGFloat = 1
    /// The table fills its line (nl: a breakout on the notes page, `.tbl` at 100 %): its last
    /// column takes the room left, the hairlines run the whole width.
    var fills = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid.fixedSize() }
        }
    }

    private var grid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14 * zoom, verticalSpacing: 6 * zoom) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    InlineTextView(text: cell, size: size, weight: .semibold, ink: .primary, chipSize: 10.5 * zoom)
                        .modifier(TableCellWidth(fills: fills && column == lastColumn, alignment: cellAlignment(column)))
                        .gridColumnAlignment(Self.alignment(table.alignments[safe: column] ?? .leading))
                }
            }
            Hairline().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { offset, row in
                if offset > 0 {
                    Hairline().gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        InlineTextView(
                            text: cell, size: size, weight: column == 0 ? .medium : .regular, ink: column == 0 ? .primary : .secondary,
                            chipSize: 10.5 * zoom
                        )
                        .modifier(TableCellWidth(fills: fills && column == lastColumn, alignment: cellAlignment(column)))
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var lastColumn: Int {
        max(table.header.count, table.rows.map(\.count).max() ?? 0) - 1
    }

    private func cellAlignment(_ column: Int) -> Alignment {
        switch table.alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    static func alignment(_ align: MarkdownBlock.Table.Align) -> HorizontalAlignment {
        switch align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// A table's last column taking the room its line leaves (`TableBlockView.fills`).
private struct TableCellWidth: ViewModifier {
    let fills: Bool
    let alignment: Alignment

    func body(content: Content) -> some View {
        if fills {
            content.frame(maxWidth: .infinity, alignment: alignment)
        } else {
            content
        }
    }
}

/// One block's inline words as SwiftUI text: bold primary semibold, italic, code in SF Mono on the
/// quiet fill, inline math as formula images, chips as their labels (tables, captions).
struct InlineTextView: View {
    let text: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var ink: HierarchicalShapeStyle = .secondary
    var chipSize: CGFloat = 10.5

    var body: some View {
        InlineText.text(text, size: size, weight: weight, chipSize: chipSize)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
enum InlineText {
    /// Words with their styles; chips as plain labels; formulas inline.
    static func text(
        _ text: String, size: CGFloat, weight: Font.Weight = .regular, chipSize: CGFloat = 10.5, chip: ((ChatCitation) -> URL?)? = nil
    ) -> Text {
        var result = Text(verbatim: "")
        for run in InlineMarkdown.runs(text) {
            let piece: Text
            switch run {
            case .text(let words, let style):
                var attributed = AttributedString(words)
                if style.contains(.code) {
                    attributed.font = .system(size: size - 1.5, design: .monospaced)
                    attributed.foregroundColor = .primary
                } else if style.contains(.bold) {
                    attributed.font = .system(size: size, weight: .semibold)
                    attributed.foregroundColor = .primary
                } else if style.contains(.italic) {
                    attributed.font = .system(size: size, weight: weight).italic()
                }
                if style.contains(.strikethrough) { attributed.strikethroughStyle = .single }
                piece = Text(attributed)
            case .citation(let citation):
                var label = AttributedString(" \(LectureNotesText.label(citation)) ")
                label.font = .system(size: chipSize, design: .monospaced)
                if case .moment = citation {
                    label.foregroundColor = .accentColor
                    label.backgroundColor = Color.accentColor.opacity(0.12)
                } else {
                    label.foregroundColor = .secondary
                    label.backgroundColor = Color.secondary.opacity(0.14)
                }
                if let url = chip?(citation) { label.link = url }
                piece = Text("\(Text(verbatim: " "))\(Text(label))")
            case .math(let latex):
                #if os(macOS)
                if let image = MathRendering.image(latex, size: size + 0.5, display: false) {
                    piece = Text(Image(nsImage: image).renderingMode(.template)).foregroundStyle(.primary).baselineOffset(-2)
                } else {
                    piece = Text(verbatim: InlineMath.unicode(latex) ?? latex)
                }
                #else
                piece = Text(verbatim: InlineMath.unicode(latex) ?? latex)
                #endif
            }
            result = Text("\(result)\(piece)")
        }
        return result
    }
}

/// The professor's words from their exam-hint or highlight row (`.pq`): the amber pin, the quote
/// in primary, the time chip; hairlines above and below. Never the model's words.
struct ProfessorQuoteView: View {
    let annotation: Annotation
    let size: CGFloat
    /// The notes' content zoom: the chip and the gaps grow with the words.
    var zoom: CGFloat = 1
    let play: (Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .top, spacing: 10 * zoom) {
                ProvenancePin(.professor)
                    .padding(.top, 1)
                Text(verbatim: "“\(annotation.body.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.system(size: size))
                    .foregroundStyle(.primary)
                    .lineSpacing(2 * zoom)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let time = annotation.startTime {
                    NotesChip(text: TimeText.clock(time), kind: .moment, size: 10.5 * zoom) { play(time) }
                        .fixedSize()
                }
            }
            .padding(.vertical, 9 * zoom)
            Hairline()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A placeholder at about a block's final height while its fence is still open, or a skeleton
/// line: redacted, no shimmer (DESIGN 6.6).
struct PlaceholderBlock: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(QuietFill())
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

/// Skeleton lines under a heading still to be written (`.sk`): fractions of the line's width.
struct SkeletonLines: View {
    let widths: [CGFloat]
    let lineHeight: CGFloat
    @State private var lineWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: lineHeight - 10) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                Capsule()
                    .fill(.fill.secondary)
                    .frame(width: max(0, lineWidth * width), height: 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
        .accessibilityHidden(true)
    }
}

/// The one determinate "Writing" line (`.prog`), or "Paused until 17:20".
struct NotesProgressLine: View {
    enum Kind: Equatable {
        case writing(Double)
        case paused(Date)
    }

    let kind: Kind
    /// The notes' content zoom.
    var zoom: CGFloat = 1
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        HStack(spacing: 10 * zoom) {
            switch kind {
            case .writing(let fraction):
                Text("Writing")
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 180 * zoom)
                Text(verbatim: "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                    .font(.mono(11 * zoom))
                    .monospacedDigit()
            case .paused(let until):
                Text("Paused until \(Text(verbatim: DayText.time(until, timeZone: timeZone)).font(.mono(11.5 * zoom)).monospacedDigit())")
            }
        }
        .font(.system(size: 12 * zoom))
        .foregroundStyle(.secondary)
        .frame(minHeight: 26 * zoom, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The pasteboard (Copy on code, kept answers, Copy as Markdown).
@MainActor
public enum Pasteboard {
    public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }
}

/// A chip at the notes' zoom: a slide ("S13", "L2 · S14": `SlideChip`'s grey capsule) or a moment
/// (`TimeChip`'s play glyph on the accent soft capsule). At 100 % it is drawn as those are.
struct NotesChip: View {
    enum Kind {
        case slide
        case moment
        /// mt: a course material's page (`book` + "§6.2 · p. 214", secondary on the quiet fill).
        case material
    }

    let text: String
    var kind: Kind = .slide
    /// 10.5 at 100 %.
    var size: CGFloat = 10.5
    /// The material's title (a material chip).
    var help: String?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scale = size / 10.5
        Button(action: action) {
            HStack(spacing: 3 * scale) {
                if kind == .moment {
                    Image(systemName: "play.fill")
                        .imageScale(.small)
                } else if kind == .material {
                    Image(systemName: "book")
                        .font(.system(size: size - 1.5))
                }
                Text(verbatim: text)
                    .monospacedDigit()
            }
            .font(.system(size: size, design: .monospaced))
            .padding(.horizontal, 7 * scale)
            .padding(.vertical, scale)
            .foregroundStyle(kind == .moment ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .background(kind == .moment ? AnyShapeStyle(Color.accentSoft(colorScheme)) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: help ?? ""))
        .accessibilityLabel(Text(verbatim: help.map { "\($0), \(text)" } ?? text))
    }
}

