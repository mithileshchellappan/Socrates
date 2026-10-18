import SwiftUI

/// The one way in besides ⌘J (docs/plan-agent.md §6, DESIGN 6.2 footer): `bubble.left` at the
/// bottom of the left sidebar next to the Settings gear, the same on every screen, tinted while
/// the panel is open; help "Show Chat" / "Hide Chat". While the sidebar is collapsed it floats at
/// the window's bottom-left corner (32 pt glass; `.agentPanel(…, floatingLauncher: true)` draws
/// it). Absent without the panel (no Claude Code).
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
            let isOpen = model.isOpen
            let button = Button {
                model.toggle()
            } label: {
                Label(isOpen ? "Hide Chat" : "Show Chat", systemImage: "bubble.left")
                    .labelStyle(.iconOnly)
            }
            .help(isOpen ? Text("Hide Chat") : Text("Show Chat"))
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
/// key window's panel (DESIGN 6.8). Absent without the panel (no Claude Code).
///
///     WindowGroup { … }.commands { AgentPanelCommands() }
public struct AgentPanelCommands: Commands {
    @FocusedValue(\.agentPanel) private var panel

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .sidebar) {
            if let panel {
                Button(panel.isOpen ? "Hide Chat" : "Show Chat") { panel.toggle() }
                    .keyboardShortcut("j", modifiers: .command)
                Button(panel.isExpanded ? "Shrink Chat" : "Expand Chat") { panel.toggleExpanded() }
                    .keyboardShortcut("j", modifiers: [.command, .option])
            }
        }
    }
}
