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
    @State private var isHovered = false

    var body: some View {
        ScrollView(.horizontal) {
            Text(Self.highlighted(code, language: language, size: size))
                .lineSpacing(size * 0.5)
                .textSelection(.enabled)
                .fixedSize()
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .scrollIndicators(.automatic)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuietFill(), in: .rect(cornerRadius: 8))
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

    var body: some View {
        ViewThatFits(in: .horizontal) {
            grid
            ScrollView(.horizontal) { grid.fixedSize() }
        }
    }

    private var grid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    InlineTextView(text: cell, size: size, weight: .semibold, ink: .primary)
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
                        InlineTextView(text: cell, size: size, weight: column == 0 ? .medium : .regular, ink: column == 0 ? .primary : .secondary)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    static func alignment(_ align: MarkdownBlock.Table.Align) -> HorizontalAlignment {
        switch align {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
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

    var body: some View {
        InlineText.text(text, size: size, weight: weight)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(ink)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
enum InlineText {
    /// Words with their styles; chips as plain labels; formulas inline.
    static func text(_ text: String, size: CGFloat, weight: Font.Weight = .regular, chip: ((ChatCitation) -> URL?)? = nil) -> Text {
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
                label.font = .system(size: 10.5, design: .monospaced)
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
    let play: (Double) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            HStack(alignment: .top, spacing: 10) {
                ProvenancePin(.professor)
                    .padding(.top, 1)
                Text(verbatim: "“\(annotation.body.trimmingCharacters(in: .whitespacesAndNewlines))”")
                    .font(.system(size: size))
                    .foregroundStyle(.primary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let time = annotation.startTime {
                    TimeChip(time, showsPlayGlyph: true) { play(time) }
                        .fixedSize()
                }
            }
            .padding(.vertical, 9)
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
    @Environment(\.timeZone) private var timeZone

    var body: some View {
        HStack(spacing: 10) {
            switch kind {
            case .writing(let fraction):
                Text("Writing")
                ProgressView(value: min(max(fraction, 0), 1))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .frame(width: 180)
                Text(verbatim: "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%")
                    .font(.mono(11))
                    .monospacedDigit()
            case .paused(let until):
                Text("Paused until \(Text(verbatim: DayText.time(until, timeZone: timeZone)).font(.mono(11.5)).monospacedDigit())")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .frame(minHeight: 26, alignment: .leading)
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
