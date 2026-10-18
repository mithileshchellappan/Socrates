#if !os(macOS)
import Notes
import StudyCore
import StudyUI
import SwiftUI

/// iOS: a note drawn read-only (M6 is Mac-only; docs/plan-m6.md §5.1): one row per block, text
/// with its styles and links, chips as their labels, media as a quiet glyph.
struct NoteReadOnlyView: View {
    let blocks: [NoteBlock]
    let style: NoteEditorStyle
    let context: NoteEditorContext

    var body: some View {
        let metrics = context.metrics
        VStack(alignment: .leading, spacing: metrics.paragraphSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                row(block, index: index, metrics: metrics)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func row(_ block: NoteBlock, index: Int, metrics: NoteMetrics) -> some View {
        switch block.type {
        case .heading:
            Text(text(block))
                .font(.system(size: metrics.headingSize(block.level ?? 1), weight: metrics.headingWeight(block.level ?? 1)))
        case .bullet, .numbered, .checklist:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                marker(block, index: index)
                Text(text(block))
            }
            .padding(.leading, metrics.listIndent * CGFloat(block.level ?? 0))
            .font(.system(size: metrics.bodySize))
        case .quote:
            HStack(spacing: 12) {
                Rectangle().fill(Color.professor).frame(width: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: "“\(block.text)”")
                    HStack(spacing: 6) {
                        ProvenancePin(.professor)
                        if let professor = context.professor { Text(verbatim: professor) }
                        if let time = block.source?.time { Text(verbatim: TimeText.clock(time)).monospacedDigit() }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: metrics.bodySize))
        case .image, .drawing, .slide:
            mediaGlyph(block.type == .slide ? .slide : block.type == .drawing ? .drawing : .image)
        default:
            Text(text(block))
                .font(.system(size: metrics.bodySize))
        }
    }

    @ViewBuilder
    private func marker(_ block: NoteBlock, index: Int) -> some View {
        switch block.type {
        case .checklist:
            Image(systemName: block.checked == true ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(block.checked == true ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        case .numbered:
            Text(verbatim: "\(number(at: index)).").monospacedDigit()
        default:
            Text(verbatim: "•")
        }
    }

    private func mediaGlyph(_ kind: NoteAttachment.Kind) -> some View {
        Image(systemName: kind == .slide ? "display" : kind == .drawing ? "scribble" : "photo")
            .foregroundStyle(.secondary)
            .frame(width: 64, height: 44)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func number(at index: Int) -> Int {
        let level = blocks[index].level ?? 0
        var count = 1
        var cursor = index - 1
        while cursor >= 0, blocks[cursor].type == .numbered || (blocks[cursor].level ?? 0) > level {
            if blocks[cursor].type == .numbered, (blocks[cursor].level ?? 0) == level { count += 1 }
            cursor -= 1
        }
        return count
    }

    /// The block's runs as styled text: marks, links, chips as their labels, media left out.
    private func text(_ block: NoteBlock) -> AttributedString {
        guard let inlines = block.inlines else { return AttributedString(block.text) }
        var result = AttributedString()
        for inline in inlines {
            var run = AttributedString(inline.text)
            let marks = Set(inline.marks ?? [])
            var font = Font.system(size: context.metrics.bodySize)
            if marks.contains(.bold) { font = font.bold() }
            if marks.contains(.italic) { font = font.italic() }
            if block.type != .heading { run.font = font }
            if marks.contains(.underline) { run.underlineStyle = .single }
            if marks.contains(.strikethrough) { run.strikethroughStyle = .single }
            if marks.contains(.highlight) { run.backgroundColor = Color(.sRGB, red: 1, green: 214 / 255, blue: 10 / 255, opacity: 0.45) }
            switch inline.type {
            case .link:
                run.link = inline.url
            case .slideRef, .timeRef:
                run.font = .chip
                run.foregroundColor = inline.type == .timeRef ? .accentColor : .secondary
            case .attachment:
                continue
            default:
                break
            }
            result += run
        }
        return result
    }
}
#endif
