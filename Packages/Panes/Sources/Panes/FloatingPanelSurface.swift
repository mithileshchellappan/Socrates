#if os(macOS)
import AppKit

/// The floating panel's body (the agent panel mockup's `.agent.compact`): the opaque panel
/// surface in a radius 14 clip, with a 0.5 pt ring (black 12 % / white 14 %) over its content.
/// The surface is drawn in `draw(_:)`, so off-screen renders show it.
final class FloatingPanelSurface: NSView {
    static let radius: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateRing()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateRing()
    }

    override func draw(_ dirtyRect: NSRect) {
        PaneColors.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    private func updateRing() {
        layer?.borderColor = PaneColors.cgColor(PaneColors.panelRing, in: effectiveAppearance)
    }
}
#endif
