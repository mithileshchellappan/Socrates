#if os(macOS)
import AppKit

/// The strip's root view, on the panel surface: the screen's edge (a 5 pt drag handle drawing the
/// hairline) and the columns right of it. Reports the window it moves to.
final class PaneStripView: PanelSurfaceView {
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
}
#endif
