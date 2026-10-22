#if os(macOS)
import AppKit
import StudyUI

/// One pane as it shows: its header over its content, on the panel surface. It lives in its
/// column's slot (`PaneItemView`) and moves, as it is, into the maximize slot and back.
final class PaneView: PanelSurfaceView {
    let header = PaneHeaderView()
    /// The content's hosting view (frame-sized; it never sizes the pane).
    private let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: NSRect(x: 0, y: 0, width: 336, height: 400))
        autoresizingMask = [.width, .height]
        header.translatesAutoresizingMaskIntoConstraints = true
        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)
        addSubview(header)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func layout() {
        super.layout()
        let headerHeight = PaneSpec.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        content.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: max(0, bounds.height - headerHeight))
    }
}
#endif
