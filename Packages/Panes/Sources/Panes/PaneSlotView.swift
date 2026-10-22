#if os(macOS)
import AppKit

/// The maximize slot (screen 41): over the pane host's whole area while a pane is maximized. It
/// holds the maximized pane's view, moved in from its column (and back), and cross-fades in
/// 0.2 s when it takes or gives up the pane. Empty, it lets every event through to what is under
/// it (it is empty only while a restore fades out).
final class PaneSlotView: NSView {
    weak var stage: PaneStage?
    private(set) var pane: NSView?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    /// Takes `pane` in (from its column). The view moves without leaving the window.
    func hold(_ pane: NSView) {
        addSubview(pane)
        pane.frame = bounds
        self.pane = pane
        layoutSubtreeIfNeeded()
    }

    /// Gives the pane up once the caller has moved it back (a pane that closed is taken out).
    func release() {
        if pane?.superview === self { pane?.removeFromSuperview() }
        pane = nil
        layoutSubtreeIfNeeded()
    }

    /// The pane as long as it is still here (never one that went back to its column meanwhile).
    private var heldPane: NSView? {
        pane?.superview === self ? pane : nil
    }

    override func layout() {
        super.layout()
        heldPane?.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        heldPane == nil ? nil : super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { stage?.slotDidAppear(self) }
    }

    /// Core Animation cross-fades this layer's contents as they are and as the change made next
    /// (in this transaction) leaves them.
    func fadeNextChange() {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.2
        layer?.add(transition, forKey: "maximize")
    }
}
#endif
