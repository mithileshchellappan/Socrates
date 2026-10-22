#if os(macOS)
import AppKit

/// The floating panel's body (the agent panel mockup's `.agent.compact`): the opaque panel
/// surface in a radius 14 clip, with a 0.5 pt ring (black 12 % / white 14 %) over its content.
final class FloatingPanelSurface: PanelSurfaceView {
    static let radius: CGFloat = 14

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = Self.radius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isOpaque: Bool { false }

    override func updateLayer() {
        super.updateLayer()
        layer?.borderColor = PaneColors.cgColor(PaneColors.panelRing, in: effectiveAppearance)
    }
}
#endif
