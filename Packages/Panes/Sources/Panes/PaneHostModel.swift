#if os(macOS)
import StudyUI
import SwiftUI

/// One main window's panes: what the screen on display offers, which panes are open, which one is
/// maximized, the room the window must keep for them, and whether a drag is resizing anything.
/// The app owns it (`@State` in its root view) and hands it to `PaneHost`, the toolbar's
/// `PaneToolbarToggles` and `PaneCommands` (through `.paneCommandsTarget`).
///
/// Nothing closes another pane: only Close, the pane's toggle or its View menu item close one.
/// Opening follows the room rules (`open`): the sidebar hides first (the app's sidebar fit reads
/// `requestedNeed`), then the widest open pane gives way toward its minimum, and where even that
/// is too little the pane opens maximized. The window never grows.
///
/// Observed properties are the ones views read; a drag in flight writes none of them per frame.
@MainActor
@Observable
public final class PaneHostModel {
    /// The screen kind on display and its panes in toolbar order (the agent last). Set by
    /// `PaneHost` in the update the screen changes.
    public private(set) var kind: PaneScreenKind = .general
    public private(set) var specs: [PaneSpec] = []
    /// The open panes of the screen on display (window-wide ones included).
    public private(set) var openIDs: Set<PaneID> = []
    /// The pane laid over the content area, if any (the others stay open behind it).
    public private(set) var maximized: PaneID?
    /// A pane divider, the screen's edge, a stack divider, the window's edge or the floating panel
    /// is being dragged (`\.isLiveResizing`). Flips twice per drag.
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
    /// The width the columns being shown or opened want (their remembered widths and the dividers)
    /// and their minimums. The app's sidebar fit hides the sidebar while the window cannot hold
    /// it beside `requestedNeed`, as long as the window holds `requestedMinimum` without it (the
    /// sidebar gives way first, then the panes); the column is placed in the update the sidebar
    /// has gone. The sidebar comes back once the window holds it 40 pt past `requestedNeed`.
    public private(set) var requestedNeed: CGFloat = 0
    public private(set) var requestedMinimum: CGFloat = 0
    /// The screen's offers, by pane (their content arrives a moment after the screen).
    public private(set) var offers: [PaneID: PaneOffer] = [:]

    /// The kind's layout as the student left it.
    @ObservationIgnored var layout = PaneLayout(columns: [], open: [])
    /// Open for the whole window (`PaneSpec.opensPerWindow`).
    @ObservationIgnored var windowOpen: Set<PaneID>
    @ObservationIgnored var room = PaneRoom(screenMinimum: 480, sidebar: 0)

    public init() {
        windowOpen = PaneLayoutStore.loadWindowOpen()
    }

    // MARK: Requests

    public func isOpen(_ id: PaneID) -> Bool {
        openIDs.contains(id)
    }

    /// The toggle, its View menu item (⌥⌘n): opens a closed pane, closes an open one. While
    /// another pane is maximized it restores the layout first (a closed pane then opens too).
    public func toggle(_ id: PaneID) {
        if let maximized, maximized != id {
            self.maximized = nil
            if !isOpen(id) { open(id) }
            return
        }
        if isOpen(id) { close(id) } else { open(id) }
    }

    /// Opens `id` under the room rules; `focus` runs the offer's focus (the agent's composer).
    public func open(_ id: PaneID, focus: Bool = false) {
        guard let spec = specs.first(where: { $0.id == id }) else { return }
        if spec.opensPerWindow {
            windowOpen.insert(id)
            PaneLayoutStore.saveWindowOpen(windowOpen)
        } else if !layout.open.contains(id) {
            layout.open.append(id)
            PaneLayoutStore.save(layout, for: kind)
        }
        refreshOpen()
        if focus { offers[id]?.focus?() }
    }

    /// Close, the toggle of an open pane. A maximized pane that closes gives the layout back.
    public func close(_ id: PaneID) {
        if maximized == id { maximized = nil }
        if windowOpen.remove(id) != nil { PaneLayoutStore.saveWindowOpen(windowOpen) }
        if let index = layout.open.firstIndex(of: id) {
            layout.open.remove(at: index)
            PaneLayoutStore.save(layout, for: kind)
        }
        refreshOpen()
    }

    /// ⤢ / ⤡ and ⇧⌘↩: restores while a pane is maximized; else maximizes `id` (nil: the pane with
    /// the keyboard, else the agent, else the first open pane).
    public func toggleMaximized(_ id: PaneID? = nil) {
        if maximized != nil {
            maximized = nil
        } else {
            let target = id ?? typingPane ?? (isOpen(.agent) ? PaneID.agent : specs.first { isOpen($0.id) }?.id)
            guard let target, isOpen(target) else { return }
            maximized = target
        }
        layout.maximized = maximized
        PaneLayoutStore.save(layout, for: kind)
    }

    /// The pane's toggle number in toolbar order (⌥⌘1…⌥⌘9), nil past nine.
    public func shortcutNumber(of id: PaneID) -> Int? {
        guard let index = specs.firstIndex(where: { $0.id == id }), index < 9 else { return nil }
        return index + 1
    }

    /// The same requests for feature screens (`\.paneControl`).
    public var control: PaneControl {
        PaneControl(
            isInstalled: true,
            isOpen: { [weak self] id in self?.isOpen(id) ?? false },
            open: { [weak self] id, focus in self?.open(id, focus: focus) },
            close: { [weak self] id in self?.close(id) }
        )
    }

    // MARK: From the host

    /// Another screen kind (or its offered panes) in the same update as the screen: its layout,
    /// as stored, for these specs.
    func configure(kind: PaneScreenKind, specs: [PaneSpec], room: PaneRoom) {
        if kind != self.kind || layout.columns.isEmpty {
            layout = (PaneLayoutStore.load(kind) ?? PaneLayout.initial(for: specs)).normalized(for: specs)
        } else {
            layout = layout.normalized(for: specs)
        }
        self.kind = kind
        self.specs = specs
        self.room = room
        maximized = layout.maximized
        refreshOpen()
    }

    func update(room: PaneRoom) {
        self.room = room
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

    private func refreshOpen() {
        let offered = Set(specs.map(\.id))
        let open = Set(layout.open).union(windowOpen).intersection(offered)
        if open != openIDs { openIDs = open }
        if let maximized, !open.contains(maximized) { self.maximized = nil }
        let widths = neededWidths(open: open)
        if placedNeed != widths.minimum { placedNeed = widths.minimum }
        if requestedMinimum != widths.minimum { requestedMinimum = widths.minimum }
        if requestedNeed != widths.wanted { requestedNeed = widths.wanted }
    }

    /// The open columns' widths as remembered and at their minimums, with the dividers between
    /// the screen and them.
    private func neededWidths(open: Set<PaneID>) -> (wanted: CGFloat, minimum: CGFloat) {
        let byID = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var wanted: CGFloat = 0
        var minimum: CGFloat = 0
        for column in layout.columns {
            let shown = column.panes.filter { open.contains($0) }
            guard !shown.isEmpty else { continue }
            let lower = shown.compactMap { byID[$0]?.minWidth }.max() ?? PaneSpec.minimumWidth
            minimum += lower + PaneHostModel.dividerThickness
            wanted += max(lower, CGFloat(column.width)) + PaneHostModel.dividerThickness
        }
        return (wanted, minimum)
    }

    /// The dividers' thickness (a hairline in the separator colour, a wider hit area).
    public static let dividerThickness: CGFloat = 1
}
#endif
