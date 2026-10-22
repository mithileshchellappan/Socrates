#if os(macOS)
import AppKit

/// An `NSSplitViewController` on a `PaneSplitView`: the strip's columns side by side, or one
/// column's panes stacked. Its dividers are drawn as hairlines and hit 3 pt either side.
final class PaneSplitController: NSSplitViewController {
    let paneSplitView = PaneSplitView()
    /// A stack's shares waiting for the stack to have a height (one inserted in this layout pass
    /// has none yet).
    private var pendingFractions: [CGFloat]?

    /// - Parameter stacked: panes over each other (horizontal dividers), else columns.
    init(stacked: Bool) {
        super.init(nibName: nil, bundle: nil)
        paneSplitView.isVertical = !stacked
        paneSplitView.dividerStyle = .thin
        splitView = paneSplitView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
        _ = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        return splitView.isVertical ? drawnRect.insetBy(dx: -3, dy: 0) : drawnRect.insetBy(dx: 0, dy: -3)
    }

    override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
        _ = super.splitView(splitView, shouldHideDividerAt: dividerIndex)
        return false
    }

    /// The views of its items, in order.
    var itemViews: [NSView] {
        splitViewItems.map(\.viewController.view)
    }

    /// A stack's dividers at these shares of its height (one per pane, summing to 1): now, or once
    /// the stack has a height.
    func position(fractions: [CGFloat]) {
        let divider = PaneHostModel.dividerThickness
        let height = splitView.bounds.height - CGFloat(fractions.count - 1) * divider
        guard height > 0 else {
            pendingFractions = fractions
            return
        }
        pendingFractions = nil
        var y: CGFloat = 0
        for (row, fraction) in fractions.enumerated().dropLast() {
            y += height * fraction
            splitView.setPosition(y, ofDividerAt: row)
            y += divider
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if let pendingFractions { position(fractions: pendingFractions) }
    }
}
#endif
