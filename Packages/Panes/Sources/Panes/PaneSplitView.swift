#if os(macOS)
import AppKit

/// The strip's split views: the columns (vertical dividers) and each column's stack (horizontal
/// ones). A divider is a hairline in the separator colour on the panel surface, dragged from 3 pt
/// either side (`PaneSplitController`). A drag is wrapped: `onDividerDrag(.began)`, AppKit's own
/// tracking, `onDividerDrag(.ended)`, so the host turns the live-resize signal on and off and
/// stores the widths once.
final class PaneSplitView: NSSplitView {
    enum DividerDrag {
        case began(Int)
        case ended(Int)
    }

    var onDividerDrag: (DividerDrag) -> Void = { _ in }

    override var dividerThickness: CGFloat { PaneHostModel.dividerThickness }

    override var dividerColor: NSColor { .separatorColor }

    override func drawDivider(in rect: NSRect) {
        PaneColors.surface.setFill()
        rect.fill()
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        if isVertical {
            NSRect(x: rect.minX, y: rect.minY, width: hairline, height: rect.height).fill()
        } else {
            NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: hairline).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = dividerIndex(at: convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        onDividerDrag(.began(index))
        super.mouseDown(with: event)
        onDividerDrag(.ended(index))
    }

    /// The divider whose hit area (the hairline and 3 pt either side) holds `point`.
    private func dividerIndex(at point: NSPoint) -> Int? {
        let views = arrangedSubviews
        guard views.count > 1 else { return nil }
        for index in 0..<(views.count - 1) {
            let before = views[index].frame
            let after = views[index + 1].frame
            let area = isVertical
                ? NSRect(x: before.maxX - 3, y: bounds.minY, width: after.minX - before.maxX + 6, height: bounds.height)
                : NSRect(x: bounds.minX, y: before.maxY - 3, width: bounds.width, height: after.minY - before.maxY + 6)
            if area.contains(point) { return index }
        }
        return nil
    }
}
#endif
