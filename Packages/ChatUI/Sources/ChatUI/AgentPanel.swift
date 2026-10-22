import StudyCore
import StudyUI
import SwiftUI

// The agent chat (ma, docs/plan-agent.md §6; panes, DESIGN 6.4 and 8.6): ONE conversation for the
// whole main window. On the Mac it is the small floating chat (`AgentMiniChat` in the app's
// floating panel) or the Agent pane (`AgentPane` in the window's pane host), never both; on the
// iPad the compact overlay or the trailing inspector column. The screen only changes what the next
// message is about (the context, read at ↩).

extension View {
    /// Installs the window's agent chat on the main window's split view (once), on the model the
    /// app owns: View ▸ Show Chat ⌘J / Expand Chat ⌥⌘J (`AgentPanelCommands`), `\.openAgentPanel`,
    /// Memory…'s sheet, the floating launcher and the composer's focus (`\.isAgentComposerFocused`,
    /// also folded into `\.isSearchFieldFocused`, so apply it inside the app's own
    /// `.environment(\.isSearchFieldFocused, …)`). On the Mac the model holds the window's panes
    /// (`AgentPanelModel(launch:panes:)`); the app presents `AgentMiniChat` in its floating panel
    /// while `model.isMiniShown` and offers `AgentPane` as the Agent pane. On iOS it draws the
    /// compact overlay and the expanded inspector column itself (`\.agentPanelExpanded`). Without
    /// `AgentPanelActions.isAvailable` none of it shows.
    ///
    /// - Parameters:
    ///   - model: the window's chat (`AgentPanelModel(launch:)`, kept by the app).
    ///   - context: what the app knows of where the student is (screen, course, mail, note,
    ///     search); a screen's `.agentContext` publication is merged over it.
    ///   - floatingLauncher: draws the launcher's floating form at the window's bottom-left corner
    ///     (while the sidebar, whose footer holds `AgentPanelLauncher`, is collapsed).
    public func agentPanel(model: AgentPanelModel, context: AgentContext, floatingLauncher: Bool = false) -> some View {
        modifier(AgentPanelModifier(model: model, context: context, floatingLauncher: floatingLauncher))
    }

    /// Reads what the screen in this column publishes (`.agentContext`) for the window's chat.
    /// `.agentPanel` reads it too, but a split view's columns are hosted apart and their
    /// preferences may stop at the column: apply this to the detail column's root as well.
    public func agentPanelContextReader() -> some View {
        modifier(AgentContextReader())
    }
}

extension EnvironmentValues {
    /// The window's chat, for its launcher (nil: no chat installed, or no Claude Code).
    @Entry var agentPanelModel: AgentPanelModel?
}

/// View ▸ Show Chat / Expand Chat of the key window's chat (`AgentPanelCommands`).
@MainActor
struct AgentPanelFocus {
    /// ⌘J hides something now (the item reads Hide Chat).
    var togglesOff: Bool
    var isExpanded: Bool
    var toggle: @MainActor () -> Void
    var toggleExpanded: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var agentPanel: AgentPanelFocus?
}

struct AgentPanelModifier: ViewModifier {
    let model: AgentPanelModel
    let context: AgentContext
    let floatingLauncher: Bool

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.isSearchFieldFocused) private var isSearchFieldFocused

    func body(content: Content) -> some View {
        let model = model
        let available = actions.isAvailable
        let composing = available && model.composerFocused
        content
            .environment(\.isSearchFieldFocused, isSearchFieldFocused || composing)
            .environment(\.isAgentComposerFocused, composing)
            .environment(\.openAgentPanel, OpenAgentPanelAction { expanded in
                if available { model.open(expanded: expanded) }
            })
            .environment(\.agentPanelModel, available ? model : nil)
            .onPreferenceChange(AgentContextPreferenceKey.self) { value in
                Task { @MainActor in model.source = value }
            }
            .overlay(alignment: .bottomLeading) {
                if available, floatingLauncher {
                    AgentPanelLauncher(style: .floating)
                        .padding(AgentPanelMetrics.margin)
                }
            }
            #if os(iOS)
            .modifier(AgentPanelInspector(model: model, isAvailable: available))
            #endif
            .sheet(isPresented: Bindable(model).showsMemory) {
                ChatMemorySheet()
            }
            .onChange(of: context, initial: true) { _, context in
                model.appContext = context
            }
            .focusedSceneValue(\.agentPanel, available ? AgentPanelFocus(
                togglesOff: model.togglesOff, isExpanded: model.isExpanded,
                toggle: { model.toggleChat() }, toggleExpanded: { model.toggleExpanded() }
            ) : nil)
    }
}

/// `agentPanelContextReader()`: the column's publication into the window's chat.
private struct AgentContextReader: ViewModifier {
    @Environment(\.agentPanelModel) private var model

    func body(content: Content) -> some View {
        content.onPreferenceChange(AgentContextPreferenceKey.self) { value in
            Task { @MainActor in model?.source = value }
        }
    }
}
