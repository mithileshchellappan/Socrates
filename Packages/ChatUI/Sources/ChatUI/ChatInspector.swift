import StudyCore
import StudyUI
import SwiftUI

extension View {
    /// The chat with the agent as this screen's inspector (docs/DESIGN.md §6.4): 336 pt, a 52 pt
    /// header level with the toolbar, one context line, the conversation, the composer at the
    /// bottom. The context decides which chat it is (`ChatContext.kind`, `.subject`): the mail
    /// chat ("Chat") on Today (`.none`) and Mail (`.mail(id)`), the tutor ("Tutor") on a course's
    /// screen (`.course(id)`) and Search (`.search(query:sources:)`); it opens the newest
    /// conversation of that kind and subject. Adds the toolbar's Show Chat (only while hidden) or,
    /// with `toolbarStyle: .tutorToggle` (Search), the "Tutor" toggle shown on and off
    /// (`showsToolbarItem: false` to place `ChatToolbarItem` yourself), and publishes View ▸ Show
    /// Chat / Hide Chat ⌘J (`ChatCommands`); ⌃⌘I toggles it like any inspector. Without
    /// `ChatActions.isAvailable` (no Claude Code) none of it exists.
    ///
    /// - Parameters:
    ///   - isPresented: the inspector is shown (the screen keeps it, e.g. `@SceneStorage`).
    ///   - context: what each message carries when it changed since the last one (the open mail,
    ///     the course, the search and its selected hits).
    @available(*, deprecated, message: "ma: the agent panel replaces the per-screen chat (.agentPanel, AgentPanelLauncher)")
    public func chatInspector(
        isPresented: Binding<Bool>,
        context: ChatContext = .none,
        showsToolbarItem: Bool = true,
        toolbarStyle: ChatToolbarItem.Style = .showChat
    ) -> some View {
        modifier(ChatInspectorModifier(isPresented: isPresented, context: context, showsToolbarItem: showsToolbarItem, toolbarStyle: toolbarStyle))
    }
}

@available(*, deprecated, message: "ma: the agent panel replaces the per-screen chat (.agentPanel, AgentPanelLauncher)")
struct ChatInspectorModifier: ViewModifier {
    @Binding var isPresented: Bool
    let context: ChatContext
    let showsToolbarItem: Bool
    let toolbarStyle: ChatToolbarItem.Style

    @Environment(\.chatActions) private var actions

    func body(content: Content) -> some View {
        let available = actions.isAvailable
        let binding = $isPresented
        content
            .toolbar {
                if showsToolbarItem {
                    ChatToolbarItem(isPresented: binding, isAvailable: available, style: toolbarStyle)
                }
            }
            .inspector(isPresented: Binding(get: { available && binding.wrappedValue }, set: { binding.wrappedValue = $0 })) {
                ChatInspector(isPresented: binding, context: context, showsHideButton: toolbarStyle == .showChat)
                    .id(ChatThread(context))
                    .inspectorColumnWidth(min: 260, ideal: ChatInspector.width, max: 440)
            }
            .focusedSceneValue(
                \.chatInspector,
                available ? ChatInspectorFocus(isPresented: isPresented, toggle: { binding.wrappedValue.toggle() }) : nil
            )
    }
}

/// The chat's toolbar button.
@available(*, deprecated, message: "ma: the agent panel replaces the per-screen chat (.agentPanel, AgentPanelLauncher)")
public struct ChatToolbarItem: ToolbarContent {
    public enum Style: Hashable, Sendable {
        /// Today, Mail, a course: Show Chat (`bubble.left`), only while the chat is hidden (one
        /// inspector toggle at most, DESIGN §6.4).
        case showChat
        /// Search (mockup 07): `bubble.left` + "Tutor" in its own glass, a toggle shown on and off;
        /// the inspector's header then has no Hide Chat (the toggle is the one inspector toggle).
        case tutorToggle
    }

    @Binding private var isPresented: Bool
    private let isAvailable: Bool
    private let style: Style

    public init(isPresented: Binding<Bool>, isAvailable: Bool, style: Style = .showChat) {
        _isPresented = isPresented
        self.isAvailable = isAvailable
        self.style = style
    }

    public var body: some ToolbarContent {
        if isAvailable && style == .tutorToggle {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Toggle("Tutor", systemImage: "bubble.left", isOn: $isPresented)
                    .labelStyle(.titleAndIcon)
                    .help(Text("Tutor"))
            }
        }
        if isAvailable && style == .showChat && !isPresented {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button("Show Chat", systemImage: "bubble.left") { isPresented = true }
                    .help(Text("Show Chat"))
            }
        }
    }
}

/// Which conversations a chat shows: its kind and the tutor's subject. A view showing a chat is
/// rebuilt when this changes (its newest conversation and New Chat state are per thread).
struct ChatThread: Hashable {
    var kind: ConversationKind
    var subject: ChatSubject?

    init(_ context: ChatContext) {
        kind = context.kind
        subject = context.subject
    }
}

/// What a chat column shows: the newest conversation of its thread, or after New Chat an empty
/// one that becomes a conversation with its first message; the composer's text and the message
/// sent but not stored yet.
@MainActor
@Observable
final class ChatThreadState {
    var startsNew = false
    /// The conversation the last message went to.
    var started: AgentConversation.ID?
    var draft = ""
    var pending: PendingMessage?

    func conversationID(newest: AgentConversation.ID?) -> AgentConversation.ID? {
        startsNew ? started : (started ?? newest)
    }

    func newChat() {
        startsNew = true
        started = nil
        pending = nil
    }

    /// The newest conversation of the context's kind and subject: a lecture's (`lecture_id`), a
    /// course's (`course_id`, no lecture), Search's (neither), or the newest mail chat.
    static func newest(_ context: ChatContext) -> FetchOne<AgentConversation?> {
        let kind = context.kind
        switch context.subject {
        case .lecture(let id)?:
            return FetchOne(AgentConversation.where { $0.kind.eq(kind) && $0.lectureID.eq(id) }.order { $0.createdAt.desc() }.limit(1))
        case .course(let id)?:
            return FetchOne(
                AgentConversation.where { $0.kind.eq(kind) && $0.courseID.eq(id) && $0.lectureID.is(nil) }.order { $0.createdAt.desc() }.limit(1)
            )
        case .search?:
            return FetchOne(
                AgentConversation.where { $0.kind.eq(kind) && $0.courseID.is(nil) && $0.lectureID.is(nil) }.order { $0.createdAt.desc() }.limit(1)
            )
        case nil:
            return FetchOne(AgentConversation.where { $0.kind.eq(kind) }.order { $0.createdAt.desc() }.limit(1))
        }
    }
}

/// The inspector: header (as a toolbar item level with the toolbar, only while shown), hairline,
/// the context line, the conversation, the composer.
struct ChatInspector: View {
    static let width: CGFloat = 336
    /// The toolbar's inset from the window's trailing edge.
    static let toolbarTrailingInset: CGFloat = 11

    @Binding var isPresented: Bool
    let context: ChatContext
    let showsHideButton: Bool

    @FetchOne private var newest: AgentConversation?
    @State private var thread = ChatThreadState()
    @State private var columnWidth = ChatInspector.width

    init(isPresented: Binding<Bool>, context: ChatContext, showsHideButton: Bool) {
        _isPresented = isPresented
        self.context = context
        self.showsHideButton = showsHideButton
        _newest = ChatThreadState.newest(context)
    }

    private var conversationID: AgentConversation.ID? {
        thread.conversationID(newest: newest?.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            Hairline()
            ChatColumn(context: context, conversationID: conversationID, thread: thread)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ChatInspectorBackground() }
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

    /// `bubble.left` + "Chat" or "Tutor" (13 semibold), New Chat, ⋯ (Memory…), Hide Chat.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(context.kind == .tutor ? "Tutor" : "Chat")
                .font(.system(size: 13, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Button {
                thread.newChat()
            } label: {
                Label("New Chat", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help(Text("New Chat"))
            .disabled(conversationID == nil)
            ChatMoreMenu()
            if showsHideButton {
                Button {
                    isPresented = false
                } label: {
                    Label("Hide Chat", systemImage: "sidebar.trailing")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(Text("Hide Chat"))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 18)
    }
}

/// The chat without a header, for a screen whose inspector has its own (Review's Tutor tab):
/// the context line, the conversation and the composer of the newest conversation of the
/// context's kind and subject. Absent without `ChatActions.isAvailable`.
@available(*, deprecated, message: "ma: the agent panel replaces the per-screen chat (.agentPanel, AgentPanelLauncher)")
public struct ChatPanel: View {
    private let context: ChatContext
    private let sendContext: (@MainActor () -> ChatContext)?
    private let newChat: Int
    private let composerFocused: Binding<Bool>?

    @Environment(\.chatActions) private var actions

    /// - Parameters:
    ///   - context: which chat (`.lecture(id, page:, time:)` on Review) and its context line.
    ///   - sendContext: the context a message carries, read when it is sent (Review: the slide on
    ///     screen and the playhead at ↩, so the panel does not redraw with the playhead); nil:
    ///     `context`.
    ///   - newChat: bump it to start a new conversation (Review's ⋯ ▸ New Chat).
    ///   - composerFocused: mirrors the composer's focus (Review detaches its plain keys).
    public init(
        context: ChatContext,
        sendContext: (@MainActor () -> ChatContext)? = nil,
        newChat: Int = 0,
        composerFocused: Binding<Bool>? = nil
    ) {
        self.context = context
        self.sendContext = sendContext
        self.newChat = newChat
        self.composerFocused = composerFocused
    }

    public var body: some View {
        if actions.isAvailable {
            ChatPanelContent(context: context, sendContext: sendContext, newChat: newChat, composerFocused: composerFocused)
                .id(ChatThread(context))
        }
    }
}

private struct ChatPanelContent: View {
    let context: ChatContext
    let sendContext: (@MainActor () -> ChatContext)?
    let newChat: Int
    let composerFocused: Binding<Bool>?

    @FetchOne private var newest: AgentConversation?
    @State private var thread = ChatThreadState()

    init(context: ChatContext, sendContext: (@MainActor () -> ChatContext)?, newChat: Int, composerFocused: Binding<Bool>?) {
        self.context = context
        self.sendContext = sendContext
        self.newChat = newChat
        self.composerFocused = composerFocused
        _newest = ChatThreadState.newest(context)
    }

    var body: some View {
        ChatColumn(
            context: context, sendContext: sendContext, conversationID: thread.conversationID(newest: newest?.id), thread: thread,
            composerFocused: composerFocused
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: newChat) { thread.newChat() }
    }
}

/// The context line and the conversation of one thread.
struct ChatColumn: View {
    let context: ChatContext
    var sendContext: (@MainActor () -> ChatContext)?
    let conversationID: AgentConversation.ID?
    @Bindable var thread: ChatThreadState
    var composerFocused: Binding<Bool>?

    var body: some View {
        VStack(spacing: 0) {
            ChatContextLine(context: context)
            ChatPane(
                conversationID: conversationID, context: context, sendContext: sendContext, draft: $thread.draft,
                pending: $thread.pending, composerFocused: composerFocused, started: { id in thread.started = id }
            )
            .id(conversationID)
        }
    }
}

/// The column's background, as Review's and Calendar's inspectors: the system's inspector (a glass
/// column on macOS 26), lifted by white 2.5 % in dark mode. Off-screen renders cannot draw that
/// glass (light: a tinted rainbow; dark: light), so judge the column's colour in the real window.
private struct ChatInspectorBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark {
            Rectangle().fill(.white.opacity(0.025)).ignoresSafeArea()
        }
    }
}

/// The student's words between pressing ↩ and their stored turn showing up.
struct PendingMessage: Equatable {
    var text: String
    /// The stored turns of the conversation when it was sent.
    var afterTurns: Int
}

/// The one quiet line under the header (11.5 pt secondary): on Mail the open message's subject;
/// on Search `link` + "4 selected" while hits are selected. None on Today, a course or Review.
private struct ChatContextLine: View {
    let context: ChatContext

    var body: some View {
        switch context {
        case .mail(let id):
            ChatMailLine(messageID: id)
                .id(id)
        case .search(_, let sources) where !sources.isEmpty:
            ChatLine(systemImage: "link") {
                Text("\(sources.count) selected")
            }
        default:
            EmptyView()
        }
    }
}

private struct ChatMailLine: View {
    @FetchOne private var message: MailMessage?

    init(messageID: MailMessage.ID) {
        _message = FetchOne(MailMessage.find(messageID))
    }

    var body: some View {
        if let message {
            ChatLine(systemImage: "envelope") {
                Text(message.subject.isEmpty ? String(localized: "No Subject") : message.subject)
            }
        }
    }
}

private struct ChatLine<Label: View>: View {
    let systemImage: String
    @ViewBuilder let label: Label

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .accessibilityHidden(true)
            label
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
