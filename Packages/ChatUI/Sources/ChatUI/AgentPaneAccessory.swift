#if os(macOS)
import StudyCore
import StudyUI
import SwiftUI

/// The Agent pane's header accessory: the conversation's title as the history menu (recent
/// conversations by day, New Chat, Memory…; at most 200 pt). Memory… asks `.agentPanel` for its
/// sheet.
public struct AgentPaneAccessory: View {
    private let model: AgentPanelModel
    private let historyQuery: FetchAll<AgentConversation>

    public init(model: AgentPanelModel) {
        self.model = model
        historyQuery = AgentHistory.query()
    }

    public var body: some View {
        let history = historyQuery.wrappedValue
        AgentTitleMenu(model: model, history: history, conversationID: model.conversationID(newest: AgentHistory.newest(history)))
            .frame(maxWidth: AgentPanelMetrics.titleWidth, alignment: .leading)
    }
}
#endif
