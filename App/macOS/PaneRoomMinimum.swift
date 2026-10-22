import Panes
import SwiftUI

/// A declared minimum width that holds the side panes laid out now at their minimums
/// (`PaneHostModel.placedNeed`): the window can be narrowed until every open pane is at its
/// minimum, never further, and never grows for a pane (a pane waits for the sidebar to hide
/// first). Its own modifier, so a pane opening or closing re-renders this, not the window's root.
struct PaneRoomMinimum: ViewModifier {
    let panes: PaneHostModel
    /// What the window keeps without panes (the screen's minimum, the sidebar while it shows).
    let minimum: CGFloat
    /// The ideal without panes (nil: none declared).
    var ideal: CGFloat?

    func body(content: Content) -> some View {
        let need = panes.placedNeed
        content.frame(minWidth: minimum + need, idealWidth: ideal.map { $0 + need }, maxWidth: .infinity)
    }
}
