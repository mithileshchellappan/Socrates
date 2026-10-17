import SwiftUI

/// The chat of the screen in the key window (Today, Mail), published by `.chatInspector` while
/// Claude Code is available.
@MainActor
struct ChatInspectorFocus {
    var isPresented: Bool
    var toggle: () -> Void
}

extension FocusedValues {
    @Entry var chatInspector: ChatInspectorFocus?
}

/// View ▸ Show Chat / Hide Chat ⌘J (reserved for it in docs/DESIGN.md §6.8). Only on a screen
/// with the chat and only with Claude Code: elsewhere the item, and its key, are absent.
///
///     WindowGroup { … }.commands { ChatCommands() }
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
