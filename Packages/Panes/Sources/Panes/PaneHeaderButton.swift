#if os(macOS)
import AppKit

/// A pane header's ⤢ / ⤡ or ✕ (mockup 40's `.pa-b`): 24 × 24, borderless, a 13 pt symbol in the
/// secondary label colour; under the pointer a radius 6 fill (fill 2) with the label colour.
/// Drawn in `draw(_:)`, so off-screen renders (`cacheDisplay`) show it.
final class PaneHeaderButton: NSButton {
    static let side: CGFloat = 24

    private var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            contentTintColor = isHovered ? .labelColor : .secondaryLabelColor
            needsDisplay = true
        }
    }

    init(target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        self.target = target
        self.action = action
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        contentTintColor = .secondaryLabelColor
        focusRingType = .none
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    /// The symbol, its help and its spoken name.
    func show(symbol: String, help: String, label: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(configuration)
        toolTip = help
        setAccessibilityLabel(label)
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = isEnabled
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered, isEnabled {
            PaneColors.hoverFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}
#endif
