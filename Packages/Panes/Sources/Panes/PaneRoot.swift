#if os(macOS)
import StudyUI
import SwiftUI

/// The root of a pane's hosting view (its content, or its header's accessory): the host's whole
/// environment, then what only panes get. The content is empty until the screen's offer arrives:
/// the pane shows its header and surface meanwhile (no spinner, no jump).
struct PaneRoot: View {
    let id: PaneID
    let model: PaneHostModel
    let environment: PaneEnvironment
    let content: AnyView?
    /// The content fills the pane (false: the header's accessory, at its own size).
    var fills = true

    var body: some View {
        // The whole environment first (outermost), so the values after it are not replaced.
        PaneRootContent(content: content, fills: fills)
            .environment(\.paneControl, model.control)
            .environment(\.paneIsMaximized, model.maximized == id)
            .environment(\.isLiveResizing, model.isLiveResizing)
            .environment(\.self, environment.values)
    }
}

/// The offer's content, filling the pane or at its own size.
private struct PaneRootContent: View {
    let content: AnyView?
    let fills: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let content {
                content
            }
        }
        .frame(maxWidth: fills ? .infinity : nil, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
    }
}
#endif
