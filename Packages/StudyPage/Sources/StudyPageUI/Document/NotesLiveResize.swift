#if os(macOS)
import Observation
import StudyUI
import SwiftUI

/// A divider or the window's edge is being dragged (`\.isLiveResizing`), for the notes document's
/// figures. Each figure is hosted in an attachment view of its own, another SwiftUI tree than the
/// notes view, so the flag comes to them through this box (one per document, the coordinator's).
@MainActor
@Observable
final class NotesLiveResize {
    var isActive = false
}

/// A figure of the notes document (code, a table, a diagram, a chart, a slide) that keeps the width
/// it had when a drag began and lays out again once, when it ends; the prose around it reflows live.
struct ResizeDeferredFigure<Content: View>: View {
    let resize: NotesLiveResize
    let content: Content

    var body: some View {
        content
            .defersReflowWhileResizing()
            .environment(\.isLiveResizing, resize.isActive)
    }
}
#endif
