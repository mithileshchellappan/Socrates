import Panes
import StudyUI
import SwiftUI

/// Typing in a pane counts as typing in the window's search field (`\.isSearchFieldFocused`): every
/// screen's plain keys (Review's Space and ← / →, the notes page's ↩) stand down while the student
/// types in a note or the agent's composer beside it. Its own modifier, so the keyboard moving in
/// or out of a pane re-renders this, not the window's root.
struct PaneTypingFold: ViewModifier {
    let panes: PaneHostModel
    let searchFocused: Bool

    func body(content: Content) -> some View {
        content.environment(\.isSearchFieldFocused, searchFocused || panes.typingPane != nil)
    }
}
