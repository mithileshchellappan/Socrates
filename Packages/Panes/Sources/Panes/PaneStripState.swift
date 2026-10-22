#if os(macOS)
import StudyUI

/// What the strip shows, read from the model in `PaneHost`'s body (so a change of any of it
/// updates the strip): the columns, the open panes, the offers, the maximized pane, the pane
/// fading out.
struct PaneStripState: Equatable {
    var arrangement: PaneArrangement
    var openPanes: Set<PaneID>
    var offers: [PaneID: PaneOffer]
    var maximized: PaneID?
    var closing: PaneID?
    var specs: [PaneSpec]

    @MainActor
    init(_ model: PaneHostModel) {
        arrangement = model.arrangement
        openPanes = model.openPanes
        offers = model.offers
        maximized = model.maximized
        closing = model.closing
        specs = model.specs
    }

    /// The maximized pane has a column to go back to.
    var canRestore: Bool {
        maximized.map { arrangement.panes.contains($0) } ?? false
    }
}
#endif
