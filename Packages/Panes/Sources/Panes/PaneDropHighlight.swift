#if os(macOS)
import AppKit

/// The one lit drop target of a header drag, in the window's drop style (DESIGN 6.2): accent soft
/// with a 1.5 pt accent ring, radius 7. Moved without animation.
final class PaneDropHighlight: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 7, yRadius: 7)
        PaneColors.accentSoft.setFill()
        shape.fill()
        shape.lineWidth = 1.5
        NSColor.controlAccentColor.setStroke()
        shape.stroke()
    }
}
#endif
