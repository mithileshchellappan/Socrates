import StudyCore
import SwiftUI

/// The chat alone, as the window would show it, for off-screen renders (`tools/parity`): the small
/// chat at its width with its surface and edge, or the expanded chat with its header drawn inline
/// (an off-screen host has no toolbar). Reads the rows like the real chat; needs
/// `\.agentPanelActions` with `isAvailable` only for the composer's Send and Stop.
public struct AgentPanelSnapshot: View {
    public enum Style: Hashable, Sendable {
        case compact
        case expanded
    }

    private let style: Style
    private let windowHeight: CGFloat
    @State private var model: AgentPanelModel

    /// - Parameters:
    ///   - context: the screen the chat is on (its prompt and context lines).
    ///   - launch: the conversation, the exchanges shown (compact), the composer's text and files.
    ///   - windowHeight: the window it would be in (the small chat is at most half of it).
    public init(style: Style, context: AgentContext, launch: AgentPanelLaunch, windowHeight: CGFloat = 740) {
        self.style = style
        self.windowHeight = windowHeight
        let model = AgentPanelModel(launch: launch)
        model.appContext = context
        _model = State(initialValue: model)
    }

    public var body: some View {
        switch style {
        case .compact:
            AgentPanelView(style: .compact, model: model, maxHeight: (windowHeight > 0 ? windowHeight : 740) / 2, header: .inline)
                .modifier(CompactPanelChrome(isCachedDisplay: true))
        case .expanded:
            AgentPanelView(style: .expanded, model: model, maxHeight: .infinity, header: .inline)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background { ExpandedPanelBackground() }
        }
    }
}
