import SwiftUI

/// The small chat's launcher besides ⌘J (docs/plan-agent.md §6, DESIGN 6.2 footer): `bubble.left`
/// at the bottom of the left sidebar next to the Settings gear, the same on every screen, tinted
/// while the chat is on screen (small or the Agent pane); help "Show Chat" / "Hide Chat". It does
/// what ⌘J does (with the Agent pane open: the caret into its composer and back). While the
/// sidebar is collapsed it floats at the window's bottom-left corner (32 pt glass;
/// `.agentPanel(…, floatingLauncher: true)` draws it). Absent without the chat (no Claude Code).
public struct AgentPanelLauncher: View {
    public enum Style: Hashable, Sendable {
        /// A plain glyph button for the sidebar's footer.
        case sidebarFooter
        /// 32 pt glass, for the window's bottom-left corner.
        case floating
    }

    private let style: Style
    @Environment(\.agentPanelModel) private var model

    public init(style: Style = .sidebarFooter) {
        self.style = style
    }

    public var body: some View {
        if let model {
            let isOpen = model.isShown
            let hides = model.togglesOff
            let button = Button {
                model.toggleChat()
            } label: {
                Label(hides ? "Hide Chat" : "Show Chat", systemImage: "bubble.left")
                    .labelStyle(.iconOnly)
            }
            .help(hides ? Text("Hide Chat") : Text("Show Chat"))
            switch style {
            case .sidebarFooter:
                button
                    .buttonStyle(.borderless)
                    .foregroundStyle(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            case .floating:
                button
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isOpen ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .frame(width: 32, height: 32)
                    .contentShape(Circle())
                    .glassEffect(.regular.interactive(), in: Circle())
            }
        }
    }
}

/// View ▸ Show Chat / Hide Chat ⌘J (also while typing) and Expand Chat / Shrink Chat ⌥⌘J for the
/// key window's chat (DESIGN 6.8). On the Mac ⌘J shows or hides the small chat, and while the
/// Agent pane is open puts the caret in its composer (Show Chat) or gives it back to the screen
/// (Hide Chat); ⌥⌘J opens the Agent pane (the small chat hides with its draft) or closes it and
/// shows the small chat. Absent without the chat (no Claude Code).
///
///     WindowGroup { … }.commands { AgentPanelCommands() }
public struct AgentPanelCommands: Commands {
    @FocusedValue(\.agentPanel) private var panel

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            if let panel {
                Button(panel.togglesOff ? "Hide Chat" : "Show Chat") { panel.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
                Button(panel.isExpanded ? "Shrink Chat" : "Expand Chat") { panel.toggleExpanded() }
                    .keyboardShortcut("j", modifiers: [.command, .option])
            }
        }
    }
}
