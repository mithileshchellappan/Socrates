#if os(macOS)
import AppKit

/// A list item's paragraph: draws its marker in the indent before the first line: a bullet, the
/// item's number, or the round 15 pt checkbox (accent and checked when done; mockup 04 with
/// DESIGN 1.3's accent instead of orange). Clicks on the box toggle it (`NoteTextView`). Markers
/// grow with the content zoom (`scale`).
final class NoteListFragment: NSTextLayoutFragment {
    enum Marker: Equatable {
        case bullet(level: Int)
        case number(Int)
        case checkbox(checked: Bool)
    }

    let marker: Marker
    /// Where the text starts (the paragraph's head indent).
    let indent: CGFloat
    /// The body font's line (ascender to descender), which the marker is centred on.
    let lineHeight: CGFloat
    let font: NSFont
    /// The content zoom the marker is drawn at (nl).
    let scale: CGFloat
    static let boxSize: CGFloat = 15
    static let boxGap: CGFloat = 8

    init(textElement: NSTextElement, range: NSTextRange?, marker: Marker, indent: CGFloat, font: NSFont, scale: CGFloat = 1) {
        self.marker = marker
        self.indent = indent
        self.font = font
        self.scale = scale
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    /// A list item's fragment with its marker (bullet, number, box), sized from the paragraph's own
    /// attributes (its head indent holds the zoom: `NoteTypesetter`); nil for any other paragraph.
    /// Called from layout managers' delegates (the editor's, and hosts of `NoteTextRendering`).
    static func make(for textElement: NSTextElement, in manager: NSTextLayoutManager, style: NoteEditorStyle) -> NSTextLayoutFragment? {
        guard let paragraph = textElement as? NSTextParagraph, paragraph.attributedString.length > 0,
              let format = paragraph.attributedString.attribute(.noteBlock, at: 0, effectiveRange: nil) as? BlockFormat,
              format.isList
        else { return nil }
        let metrics = NoteMetrics(style: style)
        let natural = metrics.listIndent * CGFloat(format.level + 1)
        let paragraphStyle = paragraph.attributedString.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let indent = paragraphStyle.map(\.headIndent).flatMap { $0 > 0 ? $0 : nil } ?? natural
        let scale = indent / natural
        let marker: Marker = switch format.kind {
        case .checklist: .checkbox(checked: format.checked)
        case .numbered: .number(NoteEditorCoordinator.number(of: paragraph, level: format.level, in: manager.textContentManager))
        default: .bullet(level: format.level)
        }
        return NoteListFragment(
            textElement: textElement, range: textElement.elementRange, marker: marker, indent: indent,
            font: NSFont.systemFont(ofSize: metrics.bodySize * scale), scale: scale
        )
    }

    /// Where the first line's text starts in the fragment's coordinates (TextKit places the
    /// fragment at the paragraph's indent, so this is usually 0).
    private var textStart: CGFloat {
        textLineFragments.first?.typographicBounds.minX ?? 0
    }

    /// The marker's box in the fragment's coordinates (the first line's top is 0): in the indent
    /// before the text.
    var markerRect: CGRect {
        let size = Self.boxSize * scale
        let center = lineHeight / 2
        switch marker {
        case .checkbox:
            return CGRect(x: textStart - Self.boxGap * scale - size, y: center - size / 2, width: size, height: size)
        case .bullet, .number:
            return CGRect(x: textStart - 40 * scale, y: 0, width: 40 * scale, height: lineHeight)
        }
    }

    /// The checkbox's hit area, a little larger than the box.
    var hitRect: CGRect {
        markerRect.insetBy(dx: -4, dy: -4)
    }

    override var renderingSurfaceBounds: CGRect {
        let room = 48 * scale
        return super.renderingSurfaceBounds.union(CGRect(x: -indent - room, y: -2, width: indent + room, height: lineHeight + 4))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let top = textLineFragments.first?.typographicBounds.minY ?? 0
        let rect = markerRect.offsetBy(dx: point.x, dy: point.y + top)
        let s = scale
        context.saveGState()
        defer { context.restoreGState() }
        switch marker {
        case .checkbox(let checked):
            let box = rect.insetBy(dx: 0.75 * s, dy: 0.75 * s)
            if checked {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.fillEllipse(in: rect)
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1.8 * s)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: rect.minX + 4.2 * s, y: rect.midY + 0.2 * s))
                context.addLine(to: CGPoint(x: rect.minX + 6.6 * s, y: rect.midY + 2.6 * s))
                context.addLine(to: CGPoint(x: rect.minX + 10.9 * s, y: rect.midY - 2.6 * s))
                context.strokePath()
            } else {
                context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                context.setLineWidth(1.5 * s)
                context.strokeEllipse(in: box)
            }
        case .bullet(let level):
            let diameter = 5 * s
            let dot = CGRect(x: rect.maxX - 14 * s - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            if level % 2 == 0 {
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fillEllipse(in: dot)
            } else {
                context.setStrokeColor(NSColor.labelColor.cgColor)
                context.setLineWidth(1 * s)
                context.strokeEllipse(in: dot.insetBy(dx: 0.5 * s, dy: 0.5 * s))
            }
        case .number(let number):
            let label = NSAttributedString(string: "\(number).", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
            let width = label.size().width
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            label.draw(at: CGPoint(x: rect.maxX - 6 * s - width, y: point.y + top))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
#endif
