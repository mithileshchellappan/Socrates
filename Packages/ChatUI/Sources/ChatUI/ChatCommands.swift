import SwiftUI

/// The chat of the screen in the key window (Today, Mail), published by `.chatInspector` while
/// Claude Code is available.
@MainActor
struct ChatInspectorFocus {
    var isPresented: Bool
    var toggle: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var chatInspector: ChatInspectorFocus?
}

extension View {
    /// M5: a screen that shows the chat its own way (Review's Tutor tab) publishes View ▸ Show
    /// Chat / Hide Chat ⌘J with this: `isPresented` is whether the chat is on screen, `toggle`
    /// shows or hides it. Only while Claude Code is available (`ChatActions.isAvailable`).
    @available(*, deprecated, message: "ma: the agent panel replaces the per-screen chat (.agentPanel, AgentPanelLauncher)")
    public func chatCommand(isPresented: Bool, toggle: @escaping @MainActor () -> Void) -> some View {
        modifier(ChatCommandPublisher(isPresented: isPresented, toggle: toggle))
    }
}

private struct ChatCommandPublisher: ViewModifier {
    let isPresented: Bool
    let toggle: @MainActor () -> Void
    @Environment(\.chatActions) private var actions

    func body(content: Content) -> some View {
        content.focusedSceneValue(
            \.chatInspector,
            actions.isAvailable ? ChatInspectorFocus(isPresented: isPresented, toggle: toggle) : nil
        )
    }
}

/// View ▸ Show Chat / Hide Chat ⌘J (reserved for it in docs/DESIGN.md §6.8). Only on a screen
/// with the chat and only with Claude Code: elsewhere the item, and its key, are absent.
///
///     WindowGroup { … }.commands { ChatCommands() }
@available(*, deprecated, message: "ma: the agent panel replaces the per-screen chat (.agentPanel, AgentPanelLauncher)")
public struct ChatCommands: Commands {
    @FocusedValue(\.chatInspector) private var chat

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            if let chat {
                Button(chat.isPresented ? "Hide Chat" : "Show Chat") { chat.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
            }
        }
    }
}
