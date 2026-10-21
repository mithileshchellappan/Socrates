#if os(macOS)
import AppKit

/// A callout's paragraph (`> [!WARNING]` …): the quiet fill (radius 10, padding 10/14) behind its
/// lines and one secondary glyph before them (`.call`); a plain quote gets a quiet 2 pt bar. Both
/// sit at the measure: `inset` in from the text view's edges (nl), and grow with the zoom.
final class NotesCalloutFragment: NSTextLayoutFragment {
    let kind: String
    let isDark: Bool
    let inset: CGFloat
    let zoom: CGFloat

    init(textElement: NSTextElement, range: NSTextRange?, kind: String, isDark: Bool, inset: CGFloat, zoom: CGFloat) {
        self.kind = kind
        self.isDark = isDark
        self.inset = inset
        self.zoom = zoom
        super.init(textElement: textElement, range: range)
    }

    required init?(coder: NSCoder) { nil }

    private var isQuote: Bool { kind == "quote" }

    /// The fill in the fragment's coordinates: the lines, 10 pt above and below, the measure's
    /// width.
    private var fillRect: CGRect {
        guard let first = textLineFragments.first?.typographicBounds, let last = textLineFragments.last?.typographicBounds else { return .zero }
        let width = (textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.width) - 2 * inset
        let left = inset - layoutFragmentFrame.minX
        if isQuote {
            return CGRect(x: left, y: first.minY, width: 2 * zoom, height: last.maxY - first.minY)
        }
        return CGRect(x: left, y: first.minY - 10 * zoom, width: width, height: last.maxY - first.minY + 20 * zoom)
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(fillRect.insetBy(dx: -1, dy: -1))
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        let rect = fillRect.offsetBy(dx: point.x, dy: point.y)
        context.saveGState()
        let fill = NSColor(srgbRed: 120 / 255, green: 120 / 255, blue: 128 / 255, alpha: isQuote ? (isDark ? 0.55 : 0.45) : (isDark ? 0.20 : 0.10))
        context.setFillColor(fill.cgColor)
        if isQuote {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: zoom, cornerHeight: zoom, transform: nil))
        } else {
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 10 * zoom, cornerHeight: 10 * zoom, transform: nil))
        }
        context.fillPath()
        context.restoreGState()
        if !isQuote, let first = textLineFragments.first?.typographicBounds {
            let symbol = kind == "warning" || kind == "caution" ? "exclamationmark.triangle" : "info.circle"
            let color = isDark
                ? NSColor(srgbRed: 0xA1 / 255, green: 0xA1 / 255, blue: 0xA6 / 255, alpha: 1)
                : NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
            let configuration = NSImage.SymbolConfiguration(pointSize: 13 * zoom, weight: .regular).applying(.init(paletteColors: [color]))
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let size = image.size
                let origin = CGPoint(
                    x: rect.minX + 14 * zoom + (16 * zoom - size.width) / 2,
                    y: point.y + first.minY + (min(first.height, 22 * zoom) - size.height) / 2
                )
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                image.draw(in: CGRect(origin: origin, size: size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        super.draw(at: point, in: context)
    }
}
#endif
