import StudyCore
import StudyPageFormat
import StudyUI
import SwiftUI

/// Claude's answer to an Ask (`LectureNotesFormat` Markdown) in SwiftUI: grey words with primary
/// emphasis, ONE sparkle at its start, formulas, code and small figures through the same renderer
/// as the notes, chips that open what they cite (S27 opens Review at the slide, 55:10 plays).
struct NotesAnswerView: View {
    let text: String
    let size: CGFloat
    var sparkle = true
    /// The notes' content zoom (a kept answer in the notes; the Ask popover stays at 1).
    var zoom: CGFloat = 1
    let chips: NotesChipResolver
    let open: (NotesChipTarget) -> Void

    var body: some View {
        let blocks = Self.blocks(text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(block, sparkle: sparkle && index == 0)
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "socrates-chip", let target = Self.target(url, chips: chips) else { return .systemAction }
            open(target)
            return .handled
        })
    }

    enum Block {
        case markdown(MarkdownBlock)
        case fence(NotesFence)
    }

    static func blocks(_ text: String) -> [Block] {
        LectureNotesFormat.parse(text).parts.flatMap(\.blocks).flatMap { block -> [Block] in
            switch block {
            case .markdown(let markdown): MarkdownBlock.blocks(markdown, alerts: true).map(Block.markdown)
            case .fence(let fence): [.fence(fence)]
            }
        }
    }

    @ViewBuilder
    private func view(_ block: Block, sparkle: Bool) -> some View {
        switch block {
        case .markdown(.paragraph(let words)), .markdown(.quote(let words)), .markdown(.callout(_, let words)):
            prose(words, sparkle: sparkle)
        case .markdown(.heading(_, let words)):
            InlineText.text(words, size: size, weight: .semibold)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
        case .markdown(.list(let items)):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(verbatim: item.marker)
                            .font(.system(size: size).monospacedDigit())
                            .foregroundStyle(item.isNumbered ? .secondary : .tertiary)
                            .frame(minWidth: 12, alignment: .trailing)
                        prose(item.text, sparkle: sparkle && index == 0)
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                }
            }
        case .markdown(.table(let table)):
            TableBlockView(table: table, size: size - 0.5 * zoom, zoom: zoom)
        case .markdown(.code(let code, let language)):
            CodeBlockView(code: code, language: language, size: size - 1.5 * zoom, zoom: zoom)
        case .markdown(.rule):
            Hairline()
        case .fence(let fence):
            fenceView(fence)
        }
    }

    @ViewBuilder
    private func fenceView(_ fence: NotesFence) -> some View {
        if !fence.isClosed, fence.kind != .code {
            PlaceholderBlock(height: fence.kind == .math ? 26 : 90)
        } else {
            switch fence.kind {
            case .math:
                MathBlockView(latex: fence.body.trimmingCharacters(in: .whitespacesAndNewlines), size: size + 2 * zoom)
            case .diagram:
                if case .success(let diagram) = Diagram.parse(fence.body) { DiagramView(diagram: diagram, scale: zoom) }
            case .chart:
                if case .success(let spec) = ChartSpec.parse(fence.body) { ChartBlockView(spec: spec, height: 130 * zoom, zoom: zoom) }
            case .code:
                CodeBlockView(code: fence.body, language: fence.language, size: size - 1.5 * zoom, zoom: zoom)
            case .slide, .quote, .note, .check:
                EmptyView()
            }
        }
    }

    private func prose(_ text: String, sparkle: Bool) -> some View {
        let chips = chips
        let drawn = InlineText.text(text, size: size, chipSize: 10.5 * zoom, chip: { citation in
            guard let target = chips.target(citation) else { return nil }
            return Self.url(target)
        })
        let leading = sparkle ? Text("\(Text(Image(systemName: "sparkle")).foregroundStyle(Color.ai)) ") : Text(verbatim: "")
        return Text("\(leading)\(drawn)")
            .font(.system(size: size))
            .foregroundStyle(.secondary)
            .lineSpacing(3 * zoom)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    static func url(_ target: NotesChipTarget) -> URL? {
        switch target {
        case .slide(let lecture, let page):
            URL(string: "socrates-chip://slide/\(lecture.uuidString)/\(page)")
        case .moment(let lecture, let recording, let seconds):
            URL(string: "socrates-chip://moment/\(lecture.uuidString)/\(Int(seconds))/\(recording?.uuidString ?? "-")")
        }
    }

    static func target(_ url: URL, chips: NotesChipResolver) -> NotesChipTarget? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let host = url.host(), let first = parts.first, let lecture = UUID(uuidString: first) else { return nil }
        switch host {
        case "slide":
            guard parts.count >= 2, let page = Int(parts[1]) else { return nil }
            return .slide(lecture: lecture, page: page)
        case "moment":
            guard parts.count >= 2, let seconds = Int(parts[1]) else { return nil }
            let recording = parts.count >= 3 ? UUID(uuidString: parts[2]) : nil
            return .moment(lecture: lecture, recording: recording, seconds: Double(seconds))
        default:
            return nil
        }
    }
}

/// A kept answer under the paragraph where its passage ends (`.kept`): the quiet fill, radius 10,
/// padding 10/14; the student's question in primary (13 medium), Claude's answer in grey with its
/// own sparkle. An orphan (its passage gone from a new version) quotes the passage above it.
/// Hovering marks its passage accent soft; its menu: Remove from Notes, Continue in Chat, Copy.
struct KeptAnswerView: View {
    let mark: LectureNotesMark
    let orphaned: Bool
    let size: CGFloat
    /// The notes' content zoom.
    var zoom: CGFloat = 1
    let chips: NotesChipResolver
    let open: (NotesChipTarget) -> Void
    let hovered: (Bool) -> Void
    let remove: () -> Void
    let continueInChat: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4 * zoom) {
            if orphaned {
                Text(verbatim: "“\(Self.quoted(mark.exact))”")
                    .font(.system(size: size - zoom))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2 * zoom)
            }
            if let question = mark.question, !question.isEmpty {
                Text(verbatim: question)
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(.primary)
            }
            NotesAnswerView(text: mark.answer ?? "", size: size, zoom: zoom, chips: chips, open: open)
        }
        .padding(.horizontal, 14 * zoom)
        .padding(.top, 10 * zoom)
        .padding(.bottom, 8 * zoom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHovered ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(QuietFill()), in: .rect(cornerRadius: 10 * zoom))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
            hovered(hovering)
        }
        .contextMenu {
            Button("Remove from Summary", action: remove)
            Button("Continue in Chat", action: continueInChat)
            Divider()
            Button("Copy") {
                Pasteboard.copy([mark.question ?? "", LectureNotesText.readable(mark.answer ?? "")].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// At most about 15 words of the passage (DESIGN 4.10).
    static func quoted(_ passage: String) -> String {
        let words = passage.split(whereSeparator: \.isWhitespace)
        guard words.count > 15 else { return words.joined(separator: " ") }
        return words.prefix(15).joined(separator: " ") + "…"
    }
}
