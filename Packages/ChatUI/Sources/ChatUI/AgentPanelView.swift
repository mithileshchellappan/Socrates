import StudyCore
import StudyUI
import SwiftUI

/// The panel's one component, in both sizes (mockup "the agent panel: one component, two sizes"):
/// the title row (the conversation's title as the history menu, ⤢ / ⤡, close), the thread, the
/// task line and the composer.
struct AgentPanelView: View {
    enum Style: Hashable {
        case compact
        case expanded
    }

    enum HeaderPlacement: Hashable {
        /// In the panel (compact; expanded in renders).
        case inline
        /// The expanded column's header as a toolbar item level with the toolbar, while shown.
        case toolbar
    }

    let style: Style
    let model: AgentPanelModel
    /// The context on screen, settled (the prompt, the context lines).
    let context: AgentContext
    /// The context a message carries, read at ↩ (the playhead).
    let sendContext: @MainActor () -> AgentContext
    let maxThreadHeight: CGFloat
    let headerPlacement: HeaderPlacement
    /// The compact panel's drag (nil: not movable).
    let move: PanelMove?
    let moveEnded: ((CGSize) -> Void)?

    @Environment(\.agentPanelActions) private var actions
    private let historyQuery: FetchAll<AgentConversation>
    private let openTasksQuery: FetchAll<AgentTask>
    @State private var columnWidth: CGFloat = CGFloat(AgentPanelMetrics.idealWidth)

    init(
        style: Style,
        model: AgentPanelModel,
        context: AgentContext,
        sendContext: @escaping @MainActor () -> AgentContext,
        maxThreadHeight: CGFloat,
        headerPlacement: HeaderPlacement = .inline,
        move: PanelMove? = nil,
        moveEnded: ((CGSize) -> Void)? = nil
    ) {
        self.style = style
        self.model = model
        self.context = context
        self.sendContext = sendContext
        self.maxThreadHeight = maxThreadHeight
        self.headerPlacement = headerPlacement
        self.move = move
        self.moveEnded = moveEnded
        historyQuery = FetchAll(
            AgentConversation.where { $0.kind.eq(ConversationKind.app) }.order { $0.createdAt.desc() }.limit(AgentPanelView.historyLimit)
        )
        let open = AgentTaskState.open
        openTasksQuery = FetchAll(AgentTask.where { $0.state.in(open) }.order { $0.createdAt.asc() })
    }

    static let historyLimit = 40

    private var history: [AgentConversation] { historyQuery.wrappedValue }

    /// The most recently active conversation: the one the panel opens on.
    private var newest: AgentConversation.ID? {
        history.max { $0.updatedAt < $1.updatedAt }?.id
    }

    private var conversationID: AgentConversation.ID? { model.conversationID(newest: newest) }

    var body: some View {
        if headerPlacement == .toolbar {
            panel
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnWidth = $0 }
                .toolbar {
                    // Only while shown: SwiftUI keeps a hidden inspector's content (and this item) alive.
                    if model.mode == .expanded {
                        ToolbarItem(placement: .automatic) {
                            header
                                .frame(width: max(0, columnWidth - AgentPanelMetrics.toolbarTrailingInset))
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
        } else {
            // No toolbar content from the compact panel: its updates never touch the window's toolbar.
            panel
        }
    }

    private var panel: some View {
        let conversationID = conversationID
        return VStack(spacing: 0) {
            switch headerPlacement {
            case .inline:
                header
                    .frame(height: style == .compact ? AgentPanelMetrics.compactHeader : AgentPanelMetrics.expandedHeader)
                if style == .expanded { Hairline() }
            case .toolbar:
                Hairline()
            }
            AgentThreadView(style: style, conversationID: conversationID, model: model, context: context, maxHeight: maxThreadHeight)
                .id(conversationID)
            if !openTasksQuery.wrappedValue.isEmpty {
                AgentTaskLine(tasks: openTasksQuery.wrappedValue, now: model.now)
                    .padding(.horizontal, style == .compact ? 14 : 16)
                    .padding(.bottom, 6)
            }
            AgentComposer(model: model, prompt: prompt, conversationID: conversationID, send: { send(to: conversationID) })
                .padding(.horizontal, style == .compact ? 8 : 12)
                .padding(.bottom, style == .compact ? 8 : 12)
        }
        .frame(maxHeight: style == .expanded ? .infinity : nil, alignment: .top)
    }

    // MARK: Header

    private var header: some View {
        AgentPanelHeader(
            model: model, history: history, conversationID: conversationID, isExpanded: style == .expanded,
            move: move, moveEnded: moveEnded
        )
        .padding(.leading, style == .compact ? 6 : 8)
        .padding(.trailing, style == .compact ? 6 : 10)
    }

    // MARK: Composer

    /// The prompt names what the next message is about; after a question in this opening of the
    /// panel, "Ask a follow-up…".
    private var prompt: Text {
        if model.askedSinceOpen || model.pending != nil { return Text("Ask a follow-up…") }
        return Self.prompt(for: context)
    }

    static func prompt(for context: AgentContext) -> Text {
        switch context.screen {
        case .today: Text("Ask about today")
        case .calendar: Text("Ask about this week")
        case .mail: context.mailMessageID == nil ? Text("Ask about your mail") : Text("Ask about this mail")
        case .lecture: Text("Ask about this lecture")
        case .course: Text("Ask about this course")
        case .notes: context.noteID == nil ? Text("Ask about your lectures") : Text("Ask about this note")
        case .search: context.selection.isEmpty ? Text("Ask about your lectures") : Text("Ask about the selection")
        default: Text("Ask about your lectures")
        }
    }

    /// ↩ or Send: the words and files go with the context as it is now (the playhead at ↩); the
    /// words show at once as a pending bubble. One message at a time: nothing while one is being
    /// handed over or not stored yet (`pending`), or while the agent answers; never empty.
    private func send(to conversationID: AgentConversation.ID?) {
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = model.attachments
        guard !text.isEmpty || !files.isEmpty, model.canSendNow else { return }
        let actions = actions
        let context = sendContext()
        let model = model
        model.pending = PendingPanelMessage(
            text: text, attachments: files, conversationID: conversationID, afterTurns: conversationID == nil ? 0 : model.turnCount
        )
        model.draft = ""
        model.attachments = []
        model.isSending = true
        model.askedSinceOpen = true
        Task {
            do {
                let id = try await actions.send(text, context, files, conversationID)
                model.selected = id
                model.startsNew = false
                if model.pending?.conversationID == nil { model.pending?.conversationID = id }
            } catch {
                ChatUILog.ui.error("Sending to the agent failed: \(String(describing: error), privacy: .public)")
                if model.draft.isEmpty { model.draft = text }
                if model.attachments.isEmpty { model.attachments = files }
                model.pending = nil
            }
            model.isSending = false
        }
    }
}

/// The title row: the conversation's title as a menu (recent conversations by day, titles only;
/// New Chat, Memory…), then ⤢ Expand / ⤡ Shrink and Close. The compact panel moves by dragging it.
private struct AgentPanelHeader: View {
    let model: AgentPanelModel
    let history: [AgentConversation]
    let conversationID: AgentConversation.ID?
    let isExpanded: Bool
    let move: PanelMove?
    let moveEnded: ((CGSize) -> Void)?

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone
    @State private var showsMemory = false
    /// A drag is in flight (a cancelled one puts the panel back).
    @GestureState private var isMoving = false

    var body: some View {
        HStack(spacing: 2) {
            titleMenu
            Spacer(minLength: 4)
            Button {
                model.toggleExpanded()
            } label: {
                Label(
                    isExpanded ? "Shrink Chat" : "Expand Chat",
                    systemImage: isExpanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
                )
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
            }
            .help(isExpanded ? Text("Shrink Chat") : Text("Expand Chat"))
            Button {
                model.close()
            } label: {
                Label("Hide Chat", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .help(Text("Hide Chat"))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // Window coordinates: the translation does not change as the panel moves under the
        // pointer. It only goes into `PanelMove` (read where the panel is placed, not here).
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($isMoving) { _, moving, _ in moving = true }
                .onChanged { value in move?.translation = value.translation }
                .onEnded { value in moveEnded?(value.translation) },
            isEnabled: move != nil
        )
        .onChange(of: isMoving) { _, moving in
            if !moving, let move, move.translation != .zero { move.translation = .zero }
        }
        .sheet(isPresented: $showsMemory) {
            ChatMemorySheet()
        }
    }

    private var current: AgentConversation? {
        conversationID.flatMap { id in history.first { $0.id == id } }
    }

    private var isNew: Bool { current == nil }

    private var title: String {
        guard let current else { return String(localized: "New Chat") }
        let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "New Chat") : title
    }

    private var titleMenu: some View {
        Menu {
            ForEach(HistoryDay.groups(history, now: model.now, locale: locale, timeZone: timeZone), id: \.title) { group in
                Section(group.title) {
                    ForEach(group.conversations) { conversation in
                        Toggle(isOn: Binding(
                            get: { conversation.id == conversationID },
                            set: { _ in model.pick(conversation.id) }
                        )) {
                            Text(verbatim: Self.menuTitle(conversation))
                        }
                    }
                }
            }
            Divider()
            Button("New Chat") { model.newChat() }
            Button("Memory…") { showsMemory = true }
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: title)
                    .font(.system(size: 13, weight: isNew ? .medium : .semibold))
                    .foregroundStyle(isNew ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    static func menuTitle(_ conversation: AgentConversation) -> String {
        let title = conversation.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "New Chat") : title
    }
}

/// The history menu's days: Today, Yesterday, the weekday within the week, then the day ("Thu 15
/// Oct"); newest first, titles only.
enum HistoryDay {
    struct Group {
        var title: String
        var conversations: [AgentConversation]
    }

    static func groups(_ conversations: [AgentConversation], now: Date, locale: Locale, timeZone: TimeZone) -> [Group] {
        var groups: [Group] = []
        let today = CalendarDay(now, in: timeZone)
        for conversation in conversations.sorted(by: { $0.createdAt > $1.createdAt }) {
            let title = Self.title(CalendarDay(conversation.createdAt, in: timeZone), today: today, date: conversation.createdAt, locale: locale, timeZone: timeZone)
            if groups.last?.title == title {
                groups[groups.count - 1].conversations.append(conversation)
            } else {
                groups.append(Group(title: title, conversations: [conversation]))
            }
        }
        return groups
    }

    static func title(_ day: CalendarDay, today: CalendarDay, date: Date, locale: Locale, timeZone: TimeZone) -> String {
        let age = day.days(to: today)
        switch age {
        case ...0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        case 2...6:
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = locale
            let symbols = calendar.standaloneWeekdaySymbols // Sunday first
            return symbols.count == 7 ? symbols[day.weekday % 7] : DayText.day(date, locale: locale, timeZone: timeZone)
        default: return DayText.day(date, locale: locale, timeZone: timeZone)
        }
    }
}
