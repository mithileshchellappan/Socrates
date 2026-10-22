#if os(macOS)
import AppKit

/// The floating panel's shadow on a layer of its own, under the panel: the mockup's
/// `--panel-shadow` (0 18 40, spread −14 light / −12 dark), cast by an inset copy of the panel's
/// shape (`shadowPath`), so it falls below the panel and costs no offscreen pass when it moves.
final class FloatingPanelShadow: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.shadowOpacity = 1
        layer?.shadowRadius = 20
        layer?.shadowOffset = CGSize(width: 0, height: -18)
        updateShadow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateShadow()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShadow()
    }

    private func updateShadow() {
        let spread: CGFloat = PaneColors.isDark(effectiveAppearance) ? 12 : 14
        let shape = bounds.insetBy(dx: min(spread, bounds.width / 2), dy: min(spread, bounds.height / 2))
        layer?.shadowPath = CGPath(rect: shape, transform: nil)
        layer?.shadowColor = PaneColors.cgColor(PaneColors.panelShadow, in: effectiveAppearance)
    }
}
#endif
