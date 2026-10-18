#if os(macOS)
import AppKit

/// A list item's paragraph: draws its marker in the indent before the first line: a bullet, the
/// item's number, or the round 15 pt checkbox (accent and checked when done; mockup 04 with
/// DESIGN 1.3's accent instead of orange). Clicks on the box toggle it (`NoteTextView`).
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
    static let boxSize: CGFloat = 15
    static let boxGap: CGFloat = 8

    init(textElement: NSTextElement, range: NSTextRange?, marker: Marker, indent: CGFloat, font: NSFont) {
        self.marker = marker
        self.indent = indent
        self.font = font
        lineHeight = ceil(font.ascender - font.descender + font.leading)
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    /// Where the first line's text starts in the fragment's coordinates (TextKit places the
    /// fragment at the paragraph's indent, so this is usually 0).
    private var textStart: CGFloat {
        textLineFragments.first?.typographicBounds.minX ?? 0
    }

    /// The marker's box in the fragment's coordinates (the first line's top is 0): in the indent
    /// before the text.
    var markerRect: CGRect {
        let size = Self.boxSize
        let center = lineHeight / 2
        switch marker {
        case .checkbox:
            return CGRect(x: textStart - Self.boxGap - size, y: center - size / 2, width: size, height: size)
        case .bullet, .number:
            return CGRect(x: textStart - 40, y: 0, width: 40, height: lineHeight)
        }
    }

    /// The checkbox's hit area, a little larger than the box.
    var hitRect: CGRect {
        markerRect.insetBy(dx: -4, dy: -4)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(CGRect(x: -indent - 48, y: -2, width: indent + 48, height: lineHeight + 4))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let top = textLineFragments.first?.typographicBounds.minY ?? 0
        let rect = markerRect.offsetBy(dx: point.x, dy: point.y + top)
        context.saveGState()
        defer { context.restoreGState() }
        switch marker {
        case .checkbox(let checked):
            let box = rect.insetBy(dx: 0.75, dy: 0.75)
            if checked {
                context.setFillColor(NSColor.controlAccentColor.cgColor)
                context.fillEllipse(in: rect)
                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(1.8)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: rect.minX + 4.2, y: rect.midY + 0.2))
                context.addLine(to: CGPoint(x: rect.minX + 6.6, y: rect.midY + 2.6))
                context.addLine(to: CGPoint(x: rect.minX + 10.9, y: rect.midY - 2.6))
                context.strokePath()
            } else {
                context.setStrokeColor(NSColor.tertiaryLabelColor.cgColor)
                context.setLineWidth(1.5)
                context.strokeEllipse(in: box)
            }
        case .bullet(let level):
            let diameter: CGFloat = 5
            let dot = CGRect(x: rect.maxX - 14 - diameter / 2, y: rect.midY - diameter / 2, width: diameter, height: diameter)
            if level % 2 == 0 {
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fillEllipse(in: dot)
            } else {
                context.setStrokeColor(NSColor.labelColor.cgColor)
                context.setLineWidth(1)
                context.strokeEllipse(in: dot.insetBy(dx: 0.5, dy: 0.5))
            }
        case .number(let number):
            let label = NSAttributedString(string: "\(number).", attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
                .foregroundColor: NSColor.labelColor
            ])
            let width = label.size().width
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            label.draw(at: CGPoint(x: rect.maxX - 6 - width, y: point.y + top))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
#endif
