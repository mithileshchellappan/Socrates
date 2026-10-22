#if os(macOS)
import AppKit
import StudyUI

/// The AppKit side of one window's panes, which `PaneHost` owns: a controller per open pane
/// (pooled, so a pane moves between columns, screen kinds and the maximize slot without being
/// built again), the strip that lays them out, the maximize slot, and the window they live in
/// (its width, live resize and first responder go to the model).
///
/// It applies the model's state on every update of the strip: the pool, the offers' content,
/// the headers, the columns (a closed pane fades out first), the maximize slot, and a focus that
/// is due. It also takes the keyboard back from a pane that closes, folds or is covered.
@MainActor
@Observable
final class PaneStage {
    /// The pane in the maximize slot; it stays there while a restore fades out, so the slot is
    /// on screen while this or the model's `maximized` is set.
    private(set) var slotPane: PaneID?

    /// The host's environment, for the panes' hosting views.
    @ObservationIgnored let environment = PaneEnvironment()
    @ObservationIgnored private var model: PaneHostModel?
    @ObservationIgnored private weak var strip: PaneStripController?
    @ObservationIgnored private weak var slot: PaneSlotView?
    @ObservationIgnored private var items: [PaneID: PaneItemController] = [:]
    @ObservationIgnored private var state: PaneStripState?
    @ObservationIgnored private let watcher = PaneWindowWatcher()
    /// The slot fading clear after a restore.
    @ObservationIgnored private var slotFade: Task<Void, Never>?

    private var reducesMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: The strip and the slot

    func makeStrip(model: PaneHostModel) -> PaneStripController {
        self.model = model
        let strip = PaneStripController(model: model)
        strip.onWindowChange = { [weak self] window in self?.watch(window) }
        self.strip = strip
        watcher.onWidth = { [weak model] width in model?.update(windowWidth: width) }
        watcher.onLiveResize = { [weak model] resizing in model?.setLiveResizing(resizing) }
        watcher.onFirstResponder = { [weak self] responder in self?.firstResponderChanged(responder) }
        return strip
    }

    func attach(_ slot: PaneSlotView) {
        self.slot = slot
    }

    func slotDidAppear(_ slot: PaneSlotView) {
        guard slot === self.slot else { return }
        reconcileSlot()
        runDueFocus()
    }

    func detach(_ slot: PaneSlotView) {
        guard slot === self.slot else { return }
        if let id = slotPane, let item = items[id] { item.takeBack() }
        slotFade?.cancel()
        slotFade = nil
        self.slot = nil
        if slotPane != nil { slotPane = nil }
    }

    private func watch(_ window: NSWindow?) {
        watcher.watch(window)
        if window == nil {
            model?.setLiveResizing(false)
            model?.setTypingPane(nil)
        }
    }

    // MARK: Applying the model

    /// The model's state, from the strip's update.
    func apply(_ state: PaneStripState) {
        self.state = state
        guard let model, let strip else { return }
        let retired = syncItems(state)
        // A pane leaving the screen (closing, folding) gives up the keyboard first.
        let window = strip.view.window
        var leaving = strip.shownPanes.subtracting(state.arrangement.panes)
        if let closing = state.closing { leaving.insert(closing) }
        for id in leaving where id != state.maximized {
            if let item = items[id] ?? retired[id], item.holdsFirstResponder(in: window) {
                window?.makeFirstResponder(nil)
            }
        }
        strip.arrange(state.arrangement, items: items, opened: model.takeJustOpened(), closing: state.closing)
        reconcileSlot()
        for item in retired.values where item.pane.window == nil {
            item.empty()
        }
        runDueFocus()
    }

    /// One controller per open pane, with its offer's content and its header. Returns the
    /// controllers of panes that closed (emptied once they are off screen).
    private func syncItems(_ state: PaneStripState) -> [PaneID: PaneItemController] {
        guard let model else { return [:] }
        var retired: [PaneID: PaneItemController] = [:]
        for (id, item) in items where !state.openPanes.contains(id) {
            retired[id] = item
            items[id] = nil
        }
        for id in state.openPanes where items[id] == nil {
            let item = PaneItemController(id: id, model: model, environment: environment)
            item.pane.header.onMaximize = { [weak model] in model?.toggleMaximized(id) }
            item.pane.header.onClose = { [weak model] in model?.close(id) }
            item.pane.header.onDragStart = { [weak self, weak item] event in
                guard let self, let item else { return }
                self.strip?.trackHeaderDrag(of: id, from: event, header: item.pane.header)
            }
            items[id] = item
        }
        for (id, item) in items {
            item.install(state.offers[id])
            if let spec = state.specs.first(where: { $0.id == id }) {
                item.showHeader(spec, isMaximized: state.maximized == id, canRestore: state.canRestore)
            }
        }
        return retired
    }

    /// Puts the maximized pane in the slot (giving up a first responder the slot covers), or
    /// gives a restored pane back to its column, each with the slot's fade.
    private func reconcileSlot() {
        guard let state else { return }
        let target = state.maximized
        if let current = slotPane, current != target {
            slotFade?.cancel()
            if !reducesMotion, target == nil { slot?.fadeNextChange() }
            items[current]?.takeBack()
            slot?.release()
            if target == nil {
                let delay = reducesMotion ? Duration.zero : .milliseconds(200)
                slotFade = Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    self.slotFade = nil
                    self.slotPane = nil
                }
            } else {
                slotPane = nil
            }
        }
        guard let target, slotPane == nil, let slot, slot.window != nil, let item = items[target] else { return }
        slotFade?.cancel()
        slotFade = nil
        if let window = slot.window, let responder = window.firstResponder as? NSView,
           !responder.isDescendant(of: item.pane),
           responder.convert(responder.bounds, to: nil).intersects(slot.convert(slot.bounds, to: nil)) {
            window.makeFirstResponder(nil)
        }
        if !reducesMotion { slot.fadeNextChange() }
        slot.hold(item.pane)
        slotPane = target
    }

    /// Runs the offer's `focus` of a pane opened or maximized with focus, once its content is in
    /// the window (a maximized pane: in the slot, since moving a view drops the caret).
    private func runDueFocus() {
        guard let model, let id = model.pendingFocus, let item = items[id], let offer = item.installed,
              item.pane.window != nil, state?.maximized != id || slotPane == id
        else { return }
        _ = model.takePendingFocus()
        offer.focus?()
    }

    private func firstResponderChanged(_ responder: NSResponder?) {
        guard let model else { return }
        var typing: PaneID?
        if let text = responder as? NSTextView, text.isEditable {
            typing = items.first { text.isDescendant(of: $0.value.pane) }?.key
        }
        model.setTypingPane(typing)
    }
}
#endif
