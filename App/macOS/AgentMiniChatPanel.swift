import ChatUI
import Panes
import StudyUI
import SwiftUI

/// The agent's small chat in the window's floating panel (DESIGN 8.6): moved by its title row and
/// resized from every edge and corner by AppKit, its place and size kept per window
/// (`agent.panel.frame`). Shown while the chat is compact and the Agent pane is closed; hidden,
/// never closed, while the pane is open (one conversation is never on screen twice). Its own
/// modifier, so showing or hiding it re-renders this, not the window's root.
struct AgentMiniChatPanel: ViewModifier {
    let model: AgentPanelModel

    @SceneStorage("agent.panel.frame") private var frame = FloatingPanelFrame.initial

    func body(content: Content) -> some View {
        let model = model
        content
            .floatingPanel(isPresented: model.isMiniShown, frame: $frame) {
                AgentMiniChat(model: model)
            }
    }
}
