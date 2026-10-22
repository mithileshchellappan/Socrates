#if os(macOS)
import SwiftUI

/// Deadlines as the Calendar screen's side pane (`.pane(.deadlines, …)`): the inspector's content
/// under the pane's own header ("Deadlines"), reading the screen's state.
struct DeadlinesPane: View {
    let state: CalendarPaneState

    var body: some View {
        if let handlers = state.handlers {
            DeadlinesInspector(data: state.data, now: state.now, selection: state.selection, handlers: handlers)
        }
    }
}
#endif
