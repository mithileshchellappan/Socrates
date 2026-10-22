#if os(macOS)
import AppKit
import StudyUI
import SwiftUI

/// One main window's panes: what the screen on display offers, which panes are open, which one is
/// maximized, the room the window must keep for them, and whether a drag is resizing anything.
/// The app owns it (`@State` in its root view) and hands it to `PaneHost`, the toolbar's
/// `PaneToolbarToggles` and `PaneCommands` (through `.paneCommandsTarget`).
///
/// Nothing closes another pane: only Close, the pane's toggle or its View menu item close one.
/// Opening follows the room rules (`open`), and the window never grows:
/// 1. the columns at the student's widths fit beside the sidebar: the pane opens at its width;
/// 2. else, where the window holds the columns' minimums without the sidebar, the sidebar hides
///    first (the app's sidebar fit reads `requestedNeed` and `requestedMinimum`) and the column is
///    placed in the update the sidebar has gone; the widest pane gives way toward its minimum;
/// 3. else the pane opens maximized only, with no column, until the window has room.
/// A width the window imposes (a tile, full screen, a screen with a larger minimum, the
/// student's own sidebar) folds the most recently opened columns: they stay open, their toggles
/// show unlit, and they come back by themselves when the room returns.
///
/// Layouts are written only when a student's action ends (a toggle, Close, Maximize, a divider,
/// edge or header drag); room decisions are never written. Observed properties are the ones
/// views read; a drag in flight writes none of them per frame, except the strip's width while
/// the student drags the screen's edge.
@MainActor
@Observable
public final class PaneHostModel {
    /// The screen kind on display and its panes in toolbar order (the agent last). Set by
    /// `PaneHost` in the update the screen changes.
    public private(set) var kind: PaneScreenKind = .general
    public private(set) var specs: [PaneSpec] = []
    /// The panes on screen: laid out in a column, maximized, or about to show where the sidebar
    /// makes room. A pane folded for room is open but not listed (its toggle shows unlit).
    public private(set) var openIDs: Set<PaneID> = []
    /// The pane laid over the content area, if any (the others stay open behind it).
    public private(set) var maximized: PaneID?
    /// A pane divider, the screen's edge, a stack divider or the window's edge is being dragged
    /// (`\.isLiveResizing`). Flips twice per drag.
    public private(set) var isLiveResizing = false
    /// The pane holding the keyboard (an editable text view inside it is the window's first
    /// responder); the app folds it into `\.isSearchFieldFocused`, so the screen's plain keys stand
    /// down while the student types in a pane.
    public private(set) var typingPane: PaneID?
    /// What the window must hold beside the screen's minimum and the sidebar for the columns laid
    /// out now: their minimums and the dividers. The app adds it to the detail column's and the
    /// split view's declared minimums, so the student can narrow the window until every open pane
    /// is at its minimum (the widest gives way first), never further.
    public private(set) var placedNeed: CGFloat = 0
    /// The width the columns that fit without the sidebar want (the student's widths and the
    /// dividers), and their minimums. The app's sidebar fit hides the sidebar while the window
    /// cannot hold it beside `requestedNeed`, as long as the window holds `requestedMinimum`
    /// without it (the sidebar gives way first, then the panes). It comes back once the window
    /// holds it 40 pt past `requestedNeed`, or when the need is 0.
    public private(set) var requestedNeed: CGFloat = 0
    public private(set) var requestedMinimum: CGFloat = 0
    /// The screen's offers, by pane (their content arrives a moment after the screen).
    public private(set) var offers: [PaneID: PaneOffer] = [:]

    /// The columns laid out now.
    private(set) var arrangement = PaneArrangement()
    /// Every open pane of the kind on display, shown or folded (and one fading out): the panes
    /// whose controllers the window keeps.
    private(set) var openPanes: Set<PaneID> = []
    /// A pane the student just closed, fading out (0.12 s) in its column: it keeps its place
    /// until the fade ends, then the columns change once. Its toggle is already unlit.
    private(set) var closing: PaneID?
    /// The strip's width while the student drags the screen's edge (nil otherwise).
    private(set) var edgeWidth: CGFloat?

    /// The same requests for feature screens (`\.paneControl`); one value for the model's
    /// lifetime, so setting it in the environment never invalidates a view.
    @ObservationIgnored public private(set) var control = PaneControl.none

    /// The kind's layout as the student left it.
    @ObservationIgnored private var layout = PaneLayout(columns: [], open: [])
    @ObservationIgnored private var loadedKind: PaneScreenKind?
    /// Open for the whole window (`PaneSpec.opensPerWindow`).
    @ObservationIgnored private var windowOpen: Set<PaneID>
    @ObservationIgnored private var room = PaneRoom(screenMinimum: 480, sidebar: 0)
    /// The window's width (0 until the strip is in a window: every column then fits).
    @ObservationIgnored private var windowWidth: CGFloat = 0
    /// The open panes, the oldest opened first (the most recent fold first).
    @ObservationIgnored private var openOrder: [PaneID] = []
    /// A pane opened where the sidebar must hide first: it shows in the update the sidebar has
    /// gone (or, should the sidebar stay, after `holdLimit`, folded or placed as the room allows).
    @ObservationIgnored private var awaitingSidebar: PaneID?
    @ObservationIgnored private var holdTimeout: Task<Void, Never>?
    /// A pane whose offer's `focus` runs once its content is installed.
    @ObservationIgnored private(set) var pendingFocus: PaneID?
    /// The pane the student just opened, for the strip to slide in (taken once).
    @ObservationIgnored private var justOpened: PaneID?
    @ObservationIgnored private var closingFade: Task<Void, Never>?

    /// The dividers' thickness (a hairline in the separator colour, a wider hit area).
    public nonisolated static let dividerThickness: CGFloat = 1
    /// How long an opened pane waits for the sidebar to make room.
    private static let holdLimit: Duration = .milliseconds(400)
    /// A closed pane's fade before the columns change.
    private static let closeFade: Duration = .milliseconds(120)

    public init() {
        windowOpen = PaneLayoutStore.loadWindowOpen()
        control = PaneControl(
            isInstalled: true,
            isOpen: { [weak self] id in self?.isOpen(id) ?? false },
            open: { [weak self] id, focus in self?.open(id, focus: focus) },
            close: { [weak self] id in self?.close(id) }
        )
    }

    // MARK: Requests

    public func isOpen(_ id: PaneID) -> Bool {
        openIDs.contains(id)
    }

    /// The toggle, its View menu item (⌥⌘n): opens a closed pane, closes an open one. While
    /// another pane is maximized it restores the layout first (a closed pane then opens too).
    public func toggle(_ id: PaneID) {
        if let maximized, maximized != id {
            restore()
            if !isOpen(id) { open(id) }
            return
        }
        if isOpen(id) { close(id) } else { open(id) }
    }

    /// Opens `id` under the room rules; `focus` runs the offer's focus (the agent's composer) once
    /// its content is installed. A folded pane opens again by the same rules: the student's
    /// latest action wins.
    public func open(_ id: PaneID, focus: Bool = false) {
        guard let spec = specs.first(where: { $0.id == id }) else { return }
        if closing == id { endClosing() }
        let wasShown = isOpen(id)
        if spec.opensPerWindow {
            if windowOpen.insert(id).inserted { PaneLayoutStore.saveWindowOpen(windowOpen) }
        } else if !layout.open.contains(id) {
            layout.open.append(id)
            PaneLayoutStore.save(layout, for: kind)
        }
        if !wasShown {
            openOrder.removeAll { $0 == id }
            openOrder.append(id)
            justOpened = id
            place(opening: id)
        }
        if focus {
            if wasShown, let offer = offers[id] {
                offer.focus?()
            } else {
                pendingFocus = id
            }
        }
    }

    /// Close, the toggle of an open pane. A maximized pane that closes gives the layout back.
    /// A pane in a column fades out first (none with Reduce Motion); the columns change after.
    public func close(_ id: PaneID) {
        let fades = arrangement.panes.contains(id) && maximized != id
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if maximized == id {
            maximized = nil
            layout.maximized = nil
        }
        if windowOpen.remove(id) != nil { PaneLayoutStore.saveWindowOpen(windowOpen) }
        layout.open.removeAll { $0 == id }
        PaneLayoutStore.save(layout, for: kind)
        openOrder.removeAll { $0 == id }
        if awaitingSidebar == id { endHold() }
        if pendingFocus == id { pendingFocus = nil }
        if justOpened == id { justOpened = nil }
        endClosing()
        if fades {
            closing = id
            closingFade = Task { [weak self] in
                try? await Task.sleep(for: Self.closeFade)
                guard !Task.isCancelled, let self else { return }
                self.endClosing()
                self.refresh()
            }
        }
        refresh()
    }

    /// ⤢ / ⤡ and ⇧⌘↩: restores while a pane is maximized; else maximizes `id` (nil: the pane with
    /// the keyboard, else the agent, else the first open pane) and runs its offer's focus.
    public func toggleMaximized(_ id: PaneID? = nil) {
        if maximized != nil {
            restore()
            return
        }
        let target = id ?? typingPane ?? (isOpen(.agent) ? PaneID.agent : specs.first { isOpen($0.id) }?.id)
        guard let target, isOpen(target) else { return }
        maximized = target
        layout.maximized = target
        PaneLayoutStore.save(layout, for: kind)
        pendingFocus = target
        refresh()
    }

    /// The pane's toggle number in toolbar order (⌥⌘1…⌥⌘9), nil past nine.
    public func shortcutNumber(of id: PaneID) -> Int? {
        guard let index = specs.firstIndex(where: { $0.id == id }), index < 9 else { return nil }
        return index + 1
    }

    /// The maximized pane has a column to go back to (⤡ and Restore Pane are on).
    var canRestore: Bool {
        maximized.map { arrangement.panes.contains($0) } ?? false
    }

    /// The strip's width as the student wants it: the columns at their widths, or the width the
    /// screen's edge is being dragged to.
    var stripWidth: CGFloat {
        edgeWidth ?? arrangement.wantedWidth
    }

    private func restore() {
        guard maximized != nil else { return }
        maximized = nil
        layout.maximized = nil
        PaneLayoutStore.save(layout, for: kind)
        refresh()
    }

    // MARK: From the host

    /// Another screen kind (or its offered panes), in the update the screen changes: the kind's
    /// layout as stored, for these specs. Read from the store every time (it always holds the
    /// student's last action), so a pane offered again (the agent after a practice exam, or once
    /// Claude Code is back) returns at its place and width.
    func configure(kind: PaneScreenKind, specs: [PaneSpec], room: PaneRoom) {
        layout = (PaneLayoutStore.load(kind) ?? PaneLayout.initial(for: specs)).normalized(for: specs)
        if kind != loadedKind {
            loadedKind = kind
            maximized = layout.maximized
        }
        self.kind = kind
        self.specs = specs
        self.room = room
        refresh()
    }

    /// The screen's minimum or the sidebar changed: the room rules again (nothing is saved).
    func update(room: PaneRoom) {
        guard room != self.room else { return }
        self.room = room
        if awaitingSidebar != nil, room.sidebar == 0 { endHold() }
        refresh()
    }

    /// The window's width changed (every frame of a live resize: arithmetic only, unless a column
    /// folds or comes back).
    func update(windowWidth: CGFloat) {
        let width = windowWidth.rounded()
        guard width != self.windowWidth else { return }
        self.windowWidth = width
        refresh()
    }

    func receive(_ offers: [PaneOffer]) {
        var byID: [PaneID: PaneOffer] = [:]
        for offer in offers { byID[offer.id] = offer }
        if byID != self.offers { self.offers = byID }
    }

    func setLiveResizing(_ resizing: Bool) {
        if isLiveResizing != resizing { isLiveResizing = resizing }
    }

    func setTypingPane(_ id: PaneID?) {
        if typingPane != id { typingPane = id }
    }

    /// The pane whose focus is due, taken once its content is installed.
    func takePendingFocus() -> PaneID? {
        defer { pendingFocus = nil }
        return pendingFocus
    }

    /// The pane the student just opened (the strip slides it in once).
    func takeJustOpened() -> PaneID? {
        defer { justOpened = nil }
        return justOpened
    }

    /// The fading pane leaves its column (the caller refreshes).
    private func endClosing() {
        closingFade?.cancel()
        closingFade = nil
        closing = nil
    }

    // MARK: The student's drags

    /// A divider between columns (or the screen's edge) was let go: the columns holding these
    /// panes keep these widths.
    func setColumnWidths(_ widths: [PaneID: CGFloat]) {
        var changed = false
        for (id, width) in widths {
            guard let index = layout.columnIndex(of: id) else { continue }
            let rounded = Double(width.rounded())
            if layout.columns[index].width != rounded {
                layout.columns[index].width = rounded
                changed = true
            }
        }
        guard changed else { return }
        PaneLayoutStore.save(layout, for: kind)
        refresh()
    }

    /// A stack's divider was let go: the shown panes of one column share its height so (the
    /// closed panes of the column keep their shares).
    func setStackFractions(_ fractions: [PaneID: CGFloat]) {
        guard let anyID = fractions.keys.first, let index = layout.columnIndex(of: anyID) else { return }
        var column = layout.columns[index]
        let rows = column.panes.indices.filter { fractions[column.panes[$0]] != nil && $0 < column.heights.count }
        let total = rows.reduce(0) { $0 + column.heights[$1] }
        for row in rows {
            column.heights[row] = Double(fractions[column.panes[row]] ?? 0) * total
        }
        guard column != layout.columns[index] else { return }
        layout.columns[index] = column
        PaneLayoutStore.save(layout, for: kind)
        refresh()
    }

    /// The screen's edge is dragged: the strip follows `width` (its first column takes the change).
    func dragEdge(to width: CGFloat) {
        if !isLiveResizing { isLiveResizing = true }
        let width = max(width.rounded(), placedNeed)
        if edgeWidth != width { edgeWidth = width }
    }

    /// The screen's edge was let go: the first column keeps its width.
    func endEdgeDrag(widths: [PaneID: CGFloat]) {
        edgeWidth = nil
        setLiveResizing(false)
        setColumnWidths(widths)
    }

    /// A header was dropped: the pane moves (a new column beside another, or stacked under one).
    func move(_ id: PaneID, to drop: PaneDrop) {
        let width = Double(specs.first { $0.id == id }?.idealWidth ?? 336)
        let moved = layout.moving(id, to: drop, width: width)
        guard moved != layout else { return }
        layout = moved.normalized(for: specs)
        PaneLayoutStore.save(layout, for: kind)
        refresh()
    }

    // MARK: Room rules

    /// What the window has for the columns beside the screen's minimum: with the sidebar as it
    /// shows, and without it.
    private var roomBesideSidebar: CGFloat {
        windowWidth > 0 ? windowWidth - room.screenMinimum - room.sidebar : .infinity
    }

    private var roomWithoutSidebar: CGFloat {
        windowWidth > 0 ? windowWidth - room.screenMinimum : .infinity
    }

    private var specsByID: [PaneID: PaneSpec] {
        Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Rules 1–3 for a pane being opened (it is already in `openOrder`).
    private func place(opening id: PaneID) {
        let specs = specsByID
        let beside = PaneArrangement.fitting(openOrder, layout: layout, specs: specs, available: roomBesideSidebar)
        let without = PaneArrangement.fitting(openOrder, layout: layout, specs: specs, available: roomWithoutSidebar)
        if beside.panes.contains(id), beside.wantedWidth <= roomBesideSidebar + 0.5 {
            // 1: it fits at the student's widths.
        } else if without.panes.contains(id) {
            // 2: the sidebar hides first (where it shows); the widest gives way.
            if room.sidebar > 0 {
                PanesLog.host.debug("\(id.rawValue, privacy: .public) waits for the sidebar to make room")
                hold(id)
            }
        } else {
            // 3: maximized only, until the window has room.
            PanesLog.host.debug("\(id.rawValue, privacy: .public) opens maximized: no room for its column")
            maximized = id
        }
        refresh()
    }

    private func hold(_ id: PaneID) {
        awaitingSidebar = id
        holdTimeout?.cancel()
        holdTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.holdLimit)
            guard !Task.isCancelled, let self else { return }
            PanesLog.host.notice("The sidebar did not make room; \(id.rawValue, privacy: .public) shows as the room allows")
            self.endHold()
            self.refresh()
        }
    }

    private func endHold() {
        awaitingSidebar = nil
        holdTimeout?.cancel()
        holdTimeout = nil
    }

    /// The open panes, the columns that fit, the needs: after every request and room change.
    private func refresh() {
        let offered = Set(specs.map(\.id))
        let open = Set(layout.open).union(windowOpen).intersection(offered)
        var order = openOrder.filter { open.contains($0) }
        for id in layout.open + windowOpen.sorted(by: { $0.rawValue < $1.rawValue }) where open.contains(id) && !order.contains(id) {
            order.append(id)
        }
        openOrder = order
        if let held = awaitingSidebar, !open.contains(held) { endHold() }
        if let maximized, !open.contains(maximized) { self.maximized = nil }

        let specs = specsByID
        var placed = PaneArrangement.fitting(order.filter { $0 != awaitingSidebar }, layout: layout, specs: specs, available: roomBesideSidebar)
        let requested = PaneArrangement.fitting(order, layout: layout, specs: specs, available: roomWithoutSidebar)
        var shown = Set(placed.panes)
        if let maximized { shown.insert(maximized) }
        if let awaitingSidebar { shown.insert(awaitingSidebar) }
        var kept = open
        if let closing, layout.columnIndex(of: closing) != nil {
            // The fading pane keeps its column until its fade ends.
            placed = PaneArrangement(layout: layout, specs: specs, shown: Set(placed.panes).union([closing]))
            kept.insert(closing)
        }

        if arrangement != placed { arrangement = placed }
        if openPanes != kept { openPanes = kept }
        if openIDs != shown { openIDs = shown }
        if placedNeed != placed.minimumWidth { placedNeed = placed.minimumWidth }
        if requestedNeed != requested.wantedWidth { requestedNeed = requested.wantedWidth }
        if requestedMinimum != requested.minimumWidth { requestedMinimum = requested.minimumWidth }
        if let typingPane, !shown.contains(typingPane) { self.typingPane = nil }
    }
}
#endif
