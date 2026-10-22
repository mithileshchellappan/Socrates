#if os(macOS)
import AppKit

/// A view on the panel surface, filled through its layer's background colour: no backing store
/// (a pane-sized one is megabytes of flat colour), so a resize redraws nothing. `cacheDisplay`
/// renders the layer's background, so off-screen renders show it.
class PanelSurfaceView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateLayer() {
        layer?.backgroundColor = PaneColors.cgColor(PaneColors.surface, in: effectiveAppearance)
    }
}
#endif
