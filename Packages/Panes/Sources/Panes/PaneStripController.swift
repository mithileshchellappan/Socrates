#if os(macOS)
import AppKit
import StudyUI

/// The pane strip right of the screen: an `NSSplitViewController` with one item per column, each
/// column a vertical split of its stacked panes. It lays out what the model arranged and turns
/// the student's drags into the model's writes. A drag lays out only AppKit views: the two
/// columns beside a divider (and their hosting views), nothing else.
///
/// Widths: each column's maximum is the student's width and its holding priority falls with its
/// width, so when the strip narrows the widest column gives way first, down to its minimum, and
/// when it widens again each column grows back to the student's width. During a divider drag the
/// two columns beside it take the change; during the edge drag, the first column.
final class PaneStripController: NSViewController {
    private enum Drag {
        case none
        case divider(Int)
        case edge(strip: CGFloat, first: CGFloat)
    }

    private let model: PaneHostModel
    private let columns = PaneSplitController(stacked: false)
    private var stacks: [PaneSplitController] = []
    /// The columns as laid out (pane ids, left to right, top to bottom).
    private var built: [[PaneID]] = []
    private var arrangement = PaneArrangement()
    private var drag = Drag.none
    /// The dividers go to the arranged widths and shares once the strip has its new width.
    private var needsPositions = false

    var onWindowChange: (NSWindow?) -> Void = { _ in }

    init(model: PaneHostModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let strip = PaneStripView(frame: NSRect(x: 0, y: 0, width: 0, height: 400))
        strip.onWindowChange = { [weak self] window in self?.onWindowChange(window) }
        addChild(columns)
        strip.columns = columns.view
        columns.paneSplitView.onDividerDrag = { [weak self] drag in self?.columnDividerDragged(drag) }
        strip.edge.onDrag = { [weak self] drag in self?.edgeDragged(drag) }
        view = strip
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard needsPositions else { return }
        needsPositions = false
        positionDividers()
    }

    /// The panes laid out as columns now.
    var shownPanes: Set<PaneID> {
        Set(built.joined())
    }

    // MARK: Arranging

    /// Lays out `arrangement` with these controllers: the columns that changed again (one layout
    /// change; a column whose panes are the same keeps its views in place), else only their
    /// limits. `opened` slides in; `closing` fades out (it keeps its column until the model lets
    /// it go).
    func arrange(_ arrangement: PaneArrangement, items: [PaneID: PaneItemController], opened: PaneID?, closing: PaneID?) {
        self.arrangement = arrangement
        let structure = arrangement.columns.map(\.panes)
        if structure != built {
            rebuild(structure, items: items)
            needsPositions = true
            view.needsLayout = true
        }
        applyLimits()
        for id in shownPanes {
            guard let pane = items[id]?.pane else { continue }
            if id == closing {
                fadeOut(pane)
            } else if pane.alphaValue < 1 {
                pane.alphaValue = 1
            }
        }
        if let opened, shownPanes.contains(opened), let item = items[opened] {
            slideIn(item.pane)
        }
    }

    /// The columns of `structure`: a column with the same panes as before keeps its stack (its
    /// views never leave the window); the others are built from the pooled controllers.
    private func rebuild(_ structure: [[PaneID]], items: [PaneID: PaneItemController]) {
        var unused = Array(zip(built, stacks))
        var reused: [Int: PaneSplitController] = [:]
        for (index, panes) in structure.enumerated() {
            if let match = unused.firstIndex(where: { $0.0 == panes }) {
                reused[index] = unused.remove(at: match).1
            }
        }
        for (_, stack) in unused {
            for item in stack.splitViewItems { stack.removeSplitViewItem(item) }
            if let item = columns.splitViewItem(for: stack) { columns.removeSplitViewItem(item) }
        }
        stacks = structure.enumerated().map { index, panes in
            reused[index] ?? makeStack(panes, items: items)
        }
        // The columns in order: a new stack goes in at its place, a reused one out of place moves.
        for (index, stack) in stacks.enumerated() {
            let current = columns.splitViewItems
            if index < current.count, current[index].viewController === stack { continue }
            if let item = columns.splitViewItem(for: stack) { columns.removeSplitViewItem(item) }
            columns.insertSplitViewItem(NSSplitViewItem(viewController: stack), at: min(index, columns.splitViewItems.count))
        }
        built = structure
    }

    private func makeStack(_ panes: [PaneID], items: [PaneID: PaneItemController]) -> PaneSplitController {
        let stack = PaneSplitController(stacked: true)
        for id in panes {
            guard let item = items[id] else { continue }
            stack.addSplitViewItem(NSSplitViewItem(viewController: item))
        }
        stack.paneSplitView.onDividerDrag = { [weak self, weak stack] drag in
            guard let self, let stack else { return }
            self.stackDividerDragged(drag, stack: stack)
        }
        return stack
    }

    /// The student closed it: 0.12 s to clear, in place.
    private func fadeOut(_ pane: NSView) {
        guard pane.alphaValue == 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            pane.animator().alphaValue = 0
        }
    }

    /// Minimums, maximums and holding priorities for the drag in progress (or none). At rest the
    /// narrowest column (the last to give way and to grow back) keeps its spec's maximum, so a
    /// strip a moment wider than its columns (while SwiftUI catches up) is never unsatisfiable.
    private func applyLimits() {
        let items = columns.splitViewItems
        guard items.count == arrangement.columns.count, stacks.count == items.count else { return }
        let byWidth = arrangement.columns.indices.sorted { arrangement.columns[$0].width > arrangement.columns[$1].width }
        for (index, column) in arrangement.columns.enumerated() {
            var maximum = index == byWidth.last ? column.maximum : column.width
            var priority = 250 + Float(byWidth.firstIndex(of: index) ?? 0)
            switch drag {
            case .divider(let divider) where index == divider || index == divider + 1:
                maximum = column.maximum
                priority = 200
            case .edge where index == 0:
                maximum = column.maximum
                priority = 200
            case .divider, .edge:
                priority = 490
            case .none:
                break
            }
            items[index].minimumThickness = column.minimum
            items[index].maximumThickness = maximum
            items[index].holdingPriority = NSLayoutConstraint.Priority(priority)
            let panes = stacks[index].splitViewItems
            for (row, pane) in panes.enumerated() {
                pane.minimumThickness = PaneSpec.headerHeight + PaneSpec.minimumStackedContent
                pane.holdingPriority = NSLayoutConstraint.Priority(row == panes.count - 1 ? 250 : 260)
            }
        }
    }

    /// The columns at their widths in the strip as it is (the widest giving way first), the
    /// stacks at their shares.
    private func positionDividers() {
        let divider = PaneHostModel.dividerThickness
        var x: CGFloat = 0
        for (index, width) in arrangement.fittedWidths(in: view.bounds.width).enumerated().dropLast() {
            x += width
            columns.splitView.setPosition(x, ofDividerAt: index)
            x += divider
        }
        for (index, column) in arrangement.columns.enumerated() where column.panes.count > 1 && index < stacks.count {
            stacks[index].position(fractions: column.fractions)
        }
    }

    private func slideIn(_ pane: NSView) {
        guard let layer = pane.layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 16
        slide.toValue = 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = 0.18
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "paneOpens")
    }

    // MARK: Drags

    private func columnDividerDragged(_ event: PaneSplitView.DividerDrag) {
        switch event {
        case .began(let index):
            drag = .divider(index)
            applyLimits()
            model.setLiveResize(.panes)
        case .ended(let index):
            drag = .none
            let views = columns.itemViews
            var widths: [PaneID: CGFloat] = [:]
            for column in [index, index + 1] where column < views.count && column < arrangement.columns.count {
                let width = views[column].frame.width.rounded()
                arrangement.columns[column].width = width
                widths[arrangement.columns[column].panes[0]] = width
            }
            applyLimits()
            model.setLiveResize(nil)
            model.setColumnWidths(widths)
        }
    }

    private func stackDividerDragged(_ event: PaneSplitView.DividerDrag, stack: PaneSplitController) {
        switch event {
        case .began:
            model.setLiveResize(.panes)
        case .ended:
            model.setLiveResize(nil)
            guard let column = stacks.firstIndex(where: { $0 === stack }), column < arrangement.columns.count else { return }
            let views = stack.itemViews
            let total = views.reduce(0) { $0 + $1.frame.height }
            guard total > 0 else { return }
            var fractions: [PaneID: CGFloat] = [:]
            for (row, id) in arrangement.columns[column].panes.enumerated() where row < views.count {
                fractions[id] = views[row].frame.height / total
            }
            model.setStackFractions(fractions)
        }
    }

    private func edgeDragged(_ event: PaneEdgeHandle.Drag) {
        guard let first = arrangement.columns.first, let firstView = columns.itemViews.first else { return }
        switch event {
        case .began:
            drag = .edge(strip: view.bounds.width, first: firstView.frame.width)
            applyLimits()
            model.setLiveResize(.screen)
        case .changed(let travel):
            guard case .edge(let strip, let start) = drag else { return }
            let width = min(max(start - travel, first.minimum), first.maximum)
            model.dragEdge(to: strip + width - start)
        case .ended:
            guard case .edge = drag else { return }
            drag = .none
            let width = firstView.frame.width.rounded()
            arrangement.columns[0].width = width
            applyLimits()
            model.endEdgeDrag(widths: [first.panes[0]: width])
        }
    }

    /// A press on `header` of pane `id`: the header drag, then the move it ends in.
    func trackHeaderDrag(of id: PaneID, from event: NSEvent, header: NSView) {
        guard model.maximized == nil, shownPanes.contains(id) else { return }
        guard let drop = PaneHeaderDrag.track(from: event, header: header, in: view, targets: dropTargets(dragging: id)) else { return }
        model.move(id, to: drop)
    }

    /// Every column's outer 24 pt bands (a new column on that side) and every other pane's lower
    /// half (stacked under it), leaving out the drops that would change nothing; the bands first.
    private func dropTargets(dragging id: PaneID) -> [PaneDropTarget] {
        var bands: [PaneDropTarget] = []
        var halves: [PaneDropTarget] = []
        let source = arrangement.columns.firstIndex { $0.panes.contains(id) }
        let alone = source.map { arrangement.columns[$0].panes.count == 1 } ?? false
        for (index, column) in arrangement.columns.enumerated() where index < stacks.count {
            let stack = stacks[index].view
            let frame = stack.convert(stack.bounds, to: view)
            let anchor = column.panes[0]
            let leadingIsHome = alone && (index == source || index == source.map { $0 + 1 })
            let trailingIsHome = alone && (index == source || index == source.map { $0 - 1 })
            if !leadingIsHome {
                bands.append(PaneDropTarget(area: NSRect(x: frame.minX, y: frame.minY, width: 24, height: frame.height), drop: .column(beside: anchor, after: false)))
            }
            if !trailingIsHome {
                bands.append(PaneDropTarget(area: NSRect(x: frame.maxX - 24, y: frame.minY, width: 24, height: frame.height), drop: .column(beside: anchor, after: true)))
            }
            let views = stacks[index].itemViews
            for (row, pane) in column.panes.enumerated() where pane != id && row < views.count {
                if row + 1 < column.panes.count, column.panes[row + 1] == id { continue }
                let paneFrame = views[row].convert(views[row].bounds, to: view)
                let lowerHalf = NSRect(x: paneFrame.minX, y: paneFrame.midY, width: paneFrame.width, height: paneFrame.height / 2)
                halves.append(PaneDropTarget(area: lowerHalf, drop: .stack(under: pane)))
            }
        }
        return bands + halves
    }
}
#endif
