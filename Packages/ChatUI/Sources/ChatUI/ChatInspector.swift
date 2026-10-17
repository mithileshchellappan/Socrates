import StudyCore
import StudyUI
import SwiftUI

extension View {
    /// The chat with the agent as this screen's inspector (Today, Mail; docs/DESIGN.md §6.4):
    /// 336 pt, a 52 pt header level with the toolbar (glyph + "Chat", New Chat, Hide Chat), on Mail
    /// one context line with the open message's subject, the conversation, the composer at the
    /// bottom. Adds the toolbar's Show Chat (only while hidden; `showsToolbarItem: false` to place
    /// `ChatToolbarItem` yourself) and publishes View ▸ Show Chat / Hide Chat ⌘J (`ChatCommands`);
    /// ⌃⌘I toggles it like any inspector. Without `ChatActions.isAvailable` (no Claude Code) none
    /// of it exists.
    ///
    /// - Parameters:
    ///   - isPresented: the inspector is shown (the screen keeps it, e.g. `@SceneStorage`).
    ///   - context: `.mail(id)` on Mail while a message is open; each message the student sends
    ///     then carries it when it changed since the last one.
    public func chatInspector(isPresented: Binding<Bool>, context: ChatContext = .none, showsToolbarItem: Bool = true) -> some View {
        modifier(ChatInspectorModifier(isPresented: isPresented, context: context, showsToolbarItem: showsToolbarItem))
    }
}

struct ChatInspectorModifier: ViewModifier {
    @Binding var isPresented: Bool
    let context: ChatContext
    let showsToolbarItem: Bool

    @Environment(\.chatActions) private var actions

    func body(content: Content) -> some View {
        let available = actions.isAvailable
        let binding = $isPresented
        content
            .toolbar {
                if showsToolbarItem {
                    ChatToolbarItem(isPresented: binding, isAvailable: available)
                }
            }
            .inspector(isPresented: Binding(get: { available && binding.wrappedValue }, set: { binding.wrappedValue = $0 })) {
                ChatInspector(isPresented: binding, context: context)
                    .inspectorColumnWidth(min: 260, ideal: ChatInspector.width, max: 440)
            }
            .focusedSceneValue(
                \.chatInspector,
                available ? ChatInspectorFocus(isPresented: isPresented, toggle: { binding.wrappedValue.toggle() }) : nil
            )
    }
}

/// Show Chat in the toolbar, only while the chat is hidden (one inspector toggle at most).
public struct ChatToolbarItem: ToolbarContent {
    @Binding private var isPresented: Bool
    private let isAvailable: Bool

    public init(isPresented: Binding<Bool>, isAvailable: Bool) {
        _isPresented = isPresented
        self.isAvailable = isAvailable
    }

    public var body: some ToolbarContent {
        if isAvailable, !isPresented {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Show Chat", systemImage: "bubble.left") { isPresented = true }
                    .help(Text("Show Chat"))
            }
        }
    }
}

/// The inspector: header (as a toolbar item level with the toolbar, only while shown), hairline,
/// the context line on Mail, the conversation, the composer. Opens on the newest `mail_chat`
/// conversation; New Chat starts an empty one that becomes a conversation with its first message.
struct ChatInspector: View {
    static let width: CGFloat = 336
    /// The toolbar's inset from the window's trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    @Binding var isPresented: Bool
    let context: ChatContext

    @FetchOne private var newest: AgentConversation?
    /// New Chat was pressed: show `started` (nil until the first message) instead of the newest.
    @State private var startsNew = false
    /// The conversation the last message went to.
    @State private var started: AgentConversation.ID?
    @State private var draft = ""
    @State private var pending: PendingMessage?
    @State private var columnWidth = ChatInspector.width

    init(isPresented: Binding<Bool>, context: ChatContext) {
        _isPresented = isPresented
        self.context = context
        let kind = ConversationKind.mailChat
        _newest = FetchOne(AgentConversation.where { $0.kind.eq(kind) }.order { $0.createdAt.desc() }.limit(1))
    }

    private var conversationID: AgentConversation.ID? {
        startsNew ? started : (started ?? newest?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            if let messageID = context.messageID {
                ChatContextLine(messageID: messageID)
                    .id(messageID)
            }
            ChatPane(
                conversationID: conversationID, context: context, draft: $draft, pending: $pending,
                started: { id in started = id }
            )
            .id(conversationID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
        .toolbar {
            // Only while shown: SwiftUI keeps a hidden inspector's content (and this item) alive.
            if isPresented {
                ToolbarItem(placement: .automatic) {
                    header
                        .frame(width: max(0, columnWidth - Self.toolbarTrailingInset))
                }
                .sharedBackgroundVisibility(.hidden)
            }
        }
    }

    /// `bubble.left` + "Chat" (13 semibold), New Chat, Hide Chat.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Chat")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button {
                startsNew = true
                started = nil
                pending = nil
            } label: {
                Label("New Chat", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("New Chat"))
            .disabled(conversationID == nil)
            Button {
                isPresented = false
            } label: {
                Label("Hide Chat", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("Hide Chat"))
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
    }
}

/// The student's words between pressing ↩ and their stored turn showing up.
struct PendingMessage: Equatable {
    var text: String
    /// The stored turns of the conversation when it was sent.
    var afterTurns: Int
}

/// On Mail: the open message's subject, one 11.5 pt secondary line (what the next message carries).
private struct ChatContextLine: View {
    @FetchOne private var message: MailMessage?

    init(messageID: MailMessage.ID) {
        _message = FetchOne(MailMessage.find(messageID))
    }

    var body: some View {
        if let message {
            HStack(spacing: 5) {
                Image(systemName: "envelope")
                    .font(.system(size: 11))
                    .accessibilityHidden(true)
                Text(message.subject.isEmpty ? String(localized: "No Subject") : message.subject)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
        }
    }
}
