#if os(macOS)
import AppKit

/// The screen's edge: a 5 pt band at the strip's leading side with the column-resize pointer; it
/// draws the edge's hairline (the strip under it is the panel surface). Its drag reports the
/// pointer's horizontal travel since the press (window points, right positive); the strip turns
/// it into the first column's width.
final class PaneEdgeHandle: NSView {
    static let width: CGFloat = 5

    enum Drag {
        case began
        case changed(CGFloat)
        case ended
    }

    var onDrag: (Drag) -> Void = { _ in }

    private var start: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .columnResize)
    }

    override func mouseDown(with event: NSEvent) {
        start = event.locationInWindow.x
        onDrag(.began)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        onDrag(.changed(event.locationInWindow.x - start))
    }

    override func mouseUp(with event: NSEvent) {
        guard start != nil else { return }
        start = nil
        onDrag(.ended)
    }
}
#endif
