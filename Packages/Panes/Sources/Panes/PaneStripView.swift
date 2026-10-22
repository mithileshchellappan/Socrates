#if os(macOS)
import AppKit

/// The strip's root view: the screen's edge (a hairline on the panel surface, under a 5 pt drag
/// handle) and the columns right of it. Reports the window it moves to.
final class PaneStripView: NSView {
    let edge = PaneEdgeHandle()
    var columns: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let columns { addSubview(columns, positioned: .below, relativeTo: edge) }
        }
    }

    var onWindowChange: (NSWindow?) -> Void = { _ in }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(edge)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let divider = PaneHostModel.dividerThickness
        columns?.frame = NSRect(x: divider, y: 0, width: max(0, bounds.width - divider), height: bounds.height)
        edge.frame = NSRect(x: 0, y: 0, width: min(PaneEdgeHandle.width, bounds.width), height: bounds.height)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange(window)
    }

    override func draw(_ dirtyRect: NSRect) {
        let divider = PaneHostModel.dividerThickness
        guard bounds.width >= divider else { return }
        PaneColors.surface.setFill()
        NSRect(x: 0, y: 0, width: divider, height: bounds.height).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: 1 / (window?.backingScaleFactor ?? 2), height: bounds.height).fill()
    }
}
#endif
