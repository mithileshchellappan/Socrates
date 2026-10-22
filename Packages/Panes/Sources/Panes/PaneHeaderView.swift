#if os(macOS)
import AppKit
import StudyUI

/// A pane's header (mockup 40's `.pa-head`): 36 pt on the panel surface with a hairline above
/// (the toolbar's edge) and below; the title in 12.5 pt semibold, then the offer's accessory (or
/// the accessory in the title's place), then ⤢ / ⤡ and ✕. A press on its free part (the title
/// included) starts the header drag. Drawn in `draw(_:)`, so off-screen renders show it.
final class PaneHeaderView: NSView {
    var onMaximize: () -> Void = {}
    var onClose: () -> Void = {}
    var onDragStart: (NSEvent) -> Void = { _ in }

    private let title = NSTextField(labelWithString: "")
    private lazy var maximize = PaneHeaderButton(target: self, action: #selector(maximizeClicked))
    private lazy var close = PaneHeaderButton(target: self, action: #selector(closeClicked))
    private var accessory: NSView?
    private var accessoryConstraints: [NSLayoutConstraint] = []
    /// The accessory's leading edge: after the title, or in its place.
    private var afterTitle: NSLayoutConstraint?
    private var inTitlePlace: NSLayoutConstraint?
    /// ⤢ or ⤡ as shown (nil: not yet).
    private var shownMaximized: Bool?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: PaneSpec.headerHeight))
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        close.show(symbol: "xmark", help: String(localized: "Close"), label: String(localized: "Close"))
        for view in [title, maximize, close] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: maximize.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            maximize.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -2),
            maximize.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The title (nil: the accessory takes its place), the accessory, and ⤢ or ⤡ (off while the
    /// maximized pane has no column to go back to).
    func show(title text: String?, accessory view: NSView?, isMaximized: Bool, canRestore: Bool) {
        title.stringValue = text ?? ""
        title.isHidden = text == nil
        setAccessibilityLabel(text)
        if view !== accessory { install(accessory: view) }
        afterTitle?.isActive = text != nil
        inTitlePlace?.isActive = text == nil
        let enabled = canRestore || !isMaximized
        if maximize.isEnabled != enabled { maximize.isEnabled = enabled }
        guard shownMaximized != isMaximized else { return }
        shownMaximized = isMaximized
        if isMaximized {
            maximize.show(symbol: "arrow.down.right.and.arrow.up.left", help: String(localized: "Restore ⇧⌘↩"), label: String(localized: "Restore"))
        } else {
            maximize.show(symbol: "arrow.up.left.and.arrow.down.right", help: String(localized: "Maximize ⇧⌘↩"), label: String(localized: "Maximize"))
        }
    }

    private func install(accessory view: NSView?) {
        accessory?.removeFromSuperview()
        NSLayoutConstraint.deactivate(accessoryConstraints)
        accessoryConstraints = []
        afterTitle = nil
        inTitlePlace = nil
        accessory = view
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        addSubview(view)
        accessoryConstraints = [
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
            view.trailingAnchor.constraint(lessThanOrEqualTo: maximize.leadingAnchor, constant: -4)
        ]
        NSLayoutConstraint.activate(accessoryConstraints)
        afterTitle = view.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 4)
        inTitlePlace = view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14)
    }

    override func draw(_ dirtyRect: NSRect) {
        PaneColors.surface.setFill()
        bounds.fill()
        let hairline = 1 / (window?.backingScaleFactor ?? 2)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: hairline).fill()
        NSRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onDragStart(event)
    }

    @objc private func maximizeClicked() {
        onMaximize()
    }

    @objc private func closeClicked() {
        onClose()
    }
}
#endif
