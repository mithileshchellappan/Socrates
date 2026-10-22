#if os(macOS)
import AppKit

/// A pane's place in its column. It holds the pane (`PaneView`) at its own size and, while the
/// pane is maximized, stands in for it as the bare panel surface at the same width, so nothing in
/// the strip moves.
final class PaneItemView: PanelSurfaceView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }
}
#endif
