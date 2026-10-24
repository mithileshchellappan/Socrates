#if os(macOS)
import AppKit
import StudyUI
import SwiftUI

/// The floating panel's AppKit view: the panel's own size plus a 6 pt resize band on every side,
/// placed by SwiftUI (`FloatingPanelHost`). Outside the panel and its band it takes no event.
///
/// - Moving: the content's title row reports its drag through `\.floatingPanelMover`; only this
///   view's layer moves (a translation, clamped to the content area less 12 pt), with no layout
///   and no body. When the drag ends the place is written once, and the translation is cleared in
///   the update in which SwiftUI places the view there.
/// - Resizing: the 4 edges and 4 corners (12 pt squares) show the system's frame-resize pointers;
///   a drag resizes the panel live (`\.isLiveResizing` on), 280 × 160 at least, the content area
///   less its margins at most, and writes the frame once when it ends (a click writes nothing; a
///   panel hugging its content keeps hugging after a resize of its width alone).
/// - Fades in and out in 0.15 s (at once with Reduce Motion); keeps inside the window when the
///   window changes.
final class FloatingPanelView: NSView {
    static let band: CGFloat = 6
    private static let corner: CGFloat = 12
    private static let margin = CGFloat(FloatingPanelFrame.margin)
    private static let minimumSize = FloatingPanelFrame.minimumSize

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private enum Gesture {
        /// The panel's rectangle (window points) when the move began, and the clamped travel.
        case move(start: NSRect, travel: CGSize)
        /// The edges dragged, the rectangle and pointer when the drag began, the rectangle now.
        case resize(edges: Edges, start: NSRect, pointer: NSPoint, now: NSRect)
    }

    let state = FloatingPanelState()
    /// Writes the panel's frame (the end of a move or resize, a clamp).
    var onPlace: (FloatingPanelFrame) -> Void = { _ in }

    private let shadowView = FloatingPanelShadow()
    private let surface = FloatingPanelSurface()
    private let hosting: NSHostingView<FloatingPanelRoot>
    /// The content's `\.isLiveResizing` follows it: on for a resize, off however the resize ends
    /// (mouse-up, or the panel hiding under it).
    private var gesture: Gesture? {
        didSet {
            let resizing = isResizing
            if state.isLiveResizing != resizing { state.isLiveResizing = resizing }
        }
    }
    /// The frame written at the end of a gesture, until SwiftUI places the view there.
    private var placed: FloatingPanelFrame?
    private var fading: Task<Void, Never>?
    private var clamping: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    override init(frame: NSRect) {
        hosting = NSHostingView(rootView: FloatingPanelRoot(state: state))
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        hosting.safeAreaRegions = []
        hosting.autoresizingMask = [.width, .height]
        addSubview(shadowView)
        addSubview(surface)
        surface.addSubview(hosting)
        state.mover = FloatingPanelMover(
            changed: { [weak self] translation in self?.move(by: translation) },
            ended: { [weak self] in self?.endMove() }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    // MARK: From SwiftUI

    /// The update of `FloatingPanelHost`: the environment, the stored frame, the content (nil:
    /// not presented; installed when the panel is presented, never again while it shows).
    func update(frame: FloatingPanelFrame, environment: EnvironmentValues, content: AnyView?) {
        state.environment = environment
        let previous = state.frame
        if previous != frame { state.frame = frame }
        if placed != nil, frame != previous {
            // SwiftUI places the view at the written frame in this pass: the gesture's offset goes.
            placed = nil
            clearTranslation()
            needsLayout = true
        }
        let hugs = frame.height == nil && !isResizing
        if state.hugs != hugs { state.hugs = hugs }
        present(content)
    }

    private var isResizing: Bool {
        if case .resize? = gesture { return true }
        return false
    }

    private func present(_ content: AnyView?) {
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let content {
            // Installed when the panel is presented only (as a pane's offer, README rule 2): an
            // update while it shows (its height following the content, a move, the window's
            // environment) never hands its content a new view.
            guard isHidden || fading != nil else { return }
            state.content = content
            fading?.cancel()
            fading = nil
            isHidden = false
            if reducesMotion {
                alphaValue = 1
            } else {
                alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    animator().alphaValue = 1
                }
            }
            scheduleClamp()
        } else if !isHidden, fading == nil {
            guard !reducesMotion else { return finishHiding() }
            fading = Task { [weak self] in
                await NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self?.animator().alphaValue = 0
                }
                guard !Task.isCancelled, let self else { return }
                self.finishHiding()
            }
        }
    }

    private func finishHiding() {
        fading = nil
        isHidden = true
        state.content = nil
        gesture = nil
        clearTranslation()
    }

    // MARK: Layout

    /// The panel inside the band, in this view's coordinates.
    private var panelRect: NSRect {
        bounds.insetBy(dx: Self.band, dy: Self.band)
    }

    private var panelRectInWindow: NSRect {
        convert(panelRect, to: nil)
    }

    override func layout() {
        super.layout()
        // A resize lays the panel out itself until SwiftUI has placed the written frame.
        window?.invalidateCursorRects(for: self)
        guard !isResizing, placed == nil else { return }
        surface.frame = panelRect
        shadowView.frame = panelRect
        hosting.frame = surface.bounds
    }

    override func resetCursorRects() {
        for (area, edges) in resizeZones {
            addCursorRect(area, cursor: NSCursor.frameResize(position: Self.position(edges), directions: .all))
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, state.content != nil, let superview else { return nil }
        let local = convert(point, from: superview)
        if edges(at: local) != nil { return self }
        return panelRect.contains(local) ? super.hitTest(point) : nil
    }

    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Moving

    private func move(by translation: CGSize) {
        guard let window, !isHidden, !isResizing else { return }
        let start: NSRect
        if case .move(let began, _)? = gesture { start = began } else { start = panelRectInWindow }
        let area = window.contentLayoutRect.insetBy(dx: Self.margin, dy: Self.margin)
        // Window coordinates (y up); the drag's translation is right and down.
        let travel = CGSize(
            width: Self.clamp(translation.width.rounded(), area.minX - start.minX, area.maxX - start.maxX),
            height: Self.clamp(-translation.height.rounded(), area.minY - start.minY, area.maxY - start.maxY)
        )
        gesture = .move(start: start, travel: travel)
        let down: CGFloat = superview?.isFlipped == true ? -1 : 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setAffineTransform(CGAffineTransform(translationX: travel.width, y: travel.height * down))
        CATransaction.commit()
    }

    private func endMove() {
        guard case .move(_, let travel)? = gesture else { return }
        gesture = nil
        guard travel != .zero else { return clearTranslation() }
        var frame = state.frame
        frame.dx -= Double(travel.width)
        frame.dy += Double(travel.height)
        place(frame)
    }

    private func clearTranslation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.setAffineTransform(.identity)
        CATransaction.commit()
    }

    // MARK: Resizing

    override func mouseDown(with event: NSEvent) {
        guard let edges = edges(at: convert(event.locationInWindow, from: nil)) else { return }
        let start = panelRectInWindow
        gesture = .resize(edges: edges, start: start, pointer: event.locationInWindow, now: start)
        state.hugs = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .resize(let edges, let start, let pointer, _)? = gesture, let window else { return }
        let area = window.contentLayoutRect.insetBy(dx: Self.margin, dy: Self.margin)
        let delta = CGSize(width: event.locationInWindow.x - pointer.x, height: event.locationInWindow.y - pointer.y)
        let now = Self.resized(start, edges: edges, by: delta, in: area)
        gesture = .resize(edges: edges, start: start, pointer: pointer, now: now)
        let local = convert(now, from: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.frame = local
        shadowView.frame = local
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        guard case .resize(let edges, let start, _, let now)? = gesture else { return }
        gesture = nil
        guard now != start else {
            // A click on the band: nothing moved, nothing is written (a hugging panel keeps hugging).
            return place(state.frame)
        }
        var frame = state.frame
        frame.dx -= Double(now.maxX - start.maxX)
        frame.dy += Double(now.minY - start.minY)
        frame.width = Double(now.width.rounded())
        // A hugging panel resized only in width keeps hugging its content.
        if frame.height != nil || !edges.isDisjoint(with: [.top, .bottom]) {
            frame.height = Double(now.height.rounded())
        }
        place(frame)
    }

    /// `start` with the dragged edges moved by `delta`, inside `area`, at least the minimum size.
    private static func resized(_ start: NSRect, edges: Edges, by delta: CGSize, in area: NSRect) -> NSRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) { minX = min(max(start.minX + delta.width, area.minX), maxX - minimumSize.width) }
        if edges.contains(.right) { maxX = max(min(start.maxX + delta.width, area.maxX), minX + minimumSize.width) }
        if edges.contains(.bottom) { minY = min(max(start.minY + delta.height, area.minY), maxY - minimumSize.height) }
        if edges.contains(.top) { maxY = max(min(start.maxY + delta.height, area.maxY), minY + minimumSize.height) }
        return NSRect(x: minX.rounded(), y: minY.rounded(), width: (maxX - minX).rounded(), height: (maxY - minY).rounded())
    }

    /// The resize zones (this view's coordinates, y up): the corners' 12 pt squares, then the
    /// band along each edge between them.
    private var resizeZones: [(NSRect, Edges)] {
        let panel = panelRect
        let half = Self.corner / 2
        let band = Self.band
        func square(_ x: CGFloat, _ y: CGFloat) -> NSRect {
            NSRect(x: x - half, y: y - half, width: Self.corner, height: Self.corner)
        }
        return [
            (square(panel.minX, panel.maxY), [.left, .top]),
            (square(panel.maxX, panel.maxY), [.right, .top]),
            (square(panel.minX, panel.minY), [.left, .bottom]),
            (square(panel.maxX, panel.minY), [.right, .bottom]),
            (NSRect(x: panel.minX + half, y: panel.maxY, width: panel.width - Self.corner, height: band), .top),
            (NSRect(x: panel.minX + half, y: panel.minY - band, width: panel.width - Self.corner, height: band), .bottom),
            (NSRect(x: panel.minX - band, y: panel.minY + half, width: band, height: panel.height - Self.corner), .left),
            (NSRect(x: panel.maxX, y: panel.minY + half, width: band, height: panel.height - Self.corner), .right)
        ]
    }

    private func edges(at point: NSPoint) -> Edges? {
        resizeZones.first { $0.0.contains(point) }?.1
    }

    private static func position(_ edges: Edges) -> NSCursor.FrameResizePosition {
        switch edges {
        case [.left, .top]: .topLeft
        case [.right, .top]: .topRight
        case [.left, .bottom]: .bottomLeft
        case [.right, .bottom]: .bottomRight
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        default: .right
        }
    }

    // MARK: Keeping inside the window

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let changed: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.windowChanged() }
        }
        observers = [
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: changed),
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main, using: changed)
        ]
        windowChanged()
    }

    /// After a resize of the window (at the end of a live one): the cap, and the panel back
    /// inside the content area.
    private func windowChanged() {
        guard let window, !window.inLiveResize else { return }
        let cap = (window.contentLayoutRect.height / 2).rounded()
        if state.cap != cap { state.cap = cap }
        scheduleClamp()
    }

    /// The clamp, after the update in progress (it writes SwiftUI state).
    private func scheduleClamp() {
        clamping?.cancel()
        clamping = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.clamp()
        }
    }

    private func clamp() {
        clamping = nil
        guard let window, !isHidden, gesture == nil, placed == nil, bounds.width > 0 else { return }
        let area = window.contentLayoutRect.insetBy(dx: Self.margin, dy: Self.margin)
        let rect = panelRectInWindow
        var fitted = rect
        fitted.size.width = min(rect.width, area.width)
        if state.frame.height != nil { fitted.size.height = min(rect.height, area.height) }
        fitted.origin.x = min(max(fitted.minX, area.minX), area.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, area.minY), max(area.minY, area.maxY - fitted.height))
        guard fitted != rect else { return }
        PanesLog.floating.debug("The panel moves back inside the window")
        var frame = state.frame
        frame.dx -= Double(fitted.maxX - rect.maxX)
        frame.dy += Double(fitted.minY - rect.minY)
        frame.width = Double(fitted.width)
        if frame.height != nil { frame.height = Double(fitted.height) }
        onPlace(frame)
    }

    private func place(_ frame: FloatingPanelFrame) {
        let frame = FloatingPanelFrame(dx: frame.dx.rounded(), dy: frame.dy.rounded(), width: frame.width.rounded(), height: frame.height.map { $0.rounded() })
        guard frame != state.frame else {
            clearTranslation()
            let hugs = frame.height == nil
            if state.hugs != hugs { state.hugs = hugs }
            needsLayout = true
            return
        }
        placed = frame
        onPlace(frame)
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        lower > upper ? 0 : min(max(value, lower), upper)
    }
}
#endif
