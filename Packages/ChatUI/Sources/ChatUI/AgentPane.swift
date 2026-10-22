#if os(macOS)
import StudyCore
import StudyUI
import SwiftUI

/// The Agent pane (the Mac's side pane `.agent`): the conversation, the task line and the
/// composer, under the pane host's 36 pt header, whose accessory is `AgentPaneAccessory`. It reads
/// the window's chat only through its model (a pane is another hosting view than the screen).
/// Files dropped on it are attached. Maximized over the content area, the thread and the composer
/// keep a 720 pt measure, centred.
///
///     .pane(.agent, identity: ObjectIdentifier(model), focus: { model.focusComposer() },
///           accessory: { AgentPaneAccessory(model: model) }) { AgentPane(model: model) }
public struct AgentPane: View {
    private let model: AgentPanelModel

    @Environment(\.paneIsMaximized) private var isMaximized
    @State private var isDropTargeted = false

    public init(model: AgentPanelModel) {
        self.model = model
    }

    public var body: some View {
        AgentPanelView(style: .expanded, model: model, maxHeight: .infinity, header: .none)
            // No minimum of its own: a long answer's one-line width (a table, a code line) never
            // becomes the pane's.
            .frame(minWidth: 0, maxWidth: isMaximized ? AgentPanelMetrics.maximizedMeasure : .infinity, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { ExpandedPanelBackground(showsEdge: false) }
            .overlay {
                if isDropTargeted {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            .agentFileDrop(model: model, isTargeted: $isDropTargeted)
    }
}
#endif
