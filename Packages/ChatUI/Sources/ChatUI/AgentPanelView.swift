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
        /// M7: the iPhone's sheet (`AgentSheet`; its thread only).
        case sheet
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
    /// Compact: the panel's greatest height (half the window); expanded: the thread's (infinity).
    let maxHeight: CGFloat
    let headerPlacement: HeaderPlacement
    /// The compact panel's drag (nil: not movable).
    let move: PanelMove?
    let moveEnded: ((CGSize) -> Void)?

    @Environment(\.agentPanelActions) private var actions
    private let historyQuery: FetchAll<AgentConversation>
    /// Memory… from the expanded header's title menu (a toolbar item).
    @State private var showsMemory = false
    /// The compact panel's task line, composer and notice, measured (the thread gets the rest).
    @State private var bottomHeight: CGFloat = 52
    /// mt: the kind of the material the reader shows (the prompt names a book or a paper).
    @State private var materialKind: MaterialKind?
    @Dependency(\.defaultDatabase) private var database

    init(
        style: Style,
        model: AgentPanelModel,
        context: AgentContext,
        sendContext: @escaping @MainActor () -> AgentContext,
        maxHeight: CGFloat,
        headerPlacement: HeaderPlacement = .inline,
        move: PanelMove? = nil,
        moveEnded: ((CGSize) -> Void)? = nil
    ) {
        self.style = style
        self.model = model
        self.context = context
        self.sendContext = sendContext
        self.maxHeight = maxHeight
        self.headerPlacement = headerPlacement
        self.move = move
        self.moveEnded = moveEnded
        historyQuery = FetchAll(
            AgentConversation.where { $0.kind.eq(ConversationKind.app) }.order { $0.createdAt.desc() }.limit(AgentPanelView.historyLimit)
        )
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
            // The header as the toolbar's own items over the column (title, flexible space, ⤡ and
            // Close), laid out by the toolbar: nothing measures the column, so dragging its edge
            // or resizing the window never rebuilds a toolbar item.
            panel
                .toolbar {
                    // Only while shown: SwiftUI keeps a hidden inspector's content (and these) alive.
                    if model.mode == .expanded {
                        ToolbarItem(placement: .automatic) {
                            AgentTitleMenu(model: model, history: history, conversationID: conversationID, showsMemory: $showsMemory)
                                .frame(maxWidth: AgentPanelMetrics.toolbarTitleWidth, alignment: .leading)
                        }
                        .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.flexible)
                        ToolbarItem(placement: .automatic) {
                            AgentPanelHeaderButtons(model: model, isExpanded: true)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                        }
                        .sharedBackgroundVisibility(.hidden)
                    }
                }
                .sheet(isPresented: $showsMemory) {
                    ChatMemorySheet()
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
            AgentThreadView(style: style, conversationID: conversationID, model: model, context: context, maxHeight: threadMaxHeight)
                .id(conversationID)
            VStack(spacing: 0) {
                AgentTaskLineSection(conversationID: conversationID, now: model.now)
                    .padding(.horizontal, style == .compact ? 14 : 16)
                AgentComposer(model: model, prompt: prompt, conversationID: conversationID, send: { send(to: conversationID) })
                    .padding(.horizontal, style == .compact ? 8 : 12)
                    .padding(.bottom, model.notice == nil ? (style == .compact ? 8 : 12) : 4)
                if let notice = model.notice {
                    // Why the message or a file did not go, until the next edit.
                    Text(verbatim: notice)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, style == .compact ? 14 : 16)
                        .padding(.bottom, style == .compact ? 8 : 12)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { height in
                if style == .compact { bottomHeight = height }
            }
        }
        .frame(maxHeight: style == .expanded ? .infinity : nil, alignment: .top)
        .task(id: context.materialID) {
            guard let id = context.materialID else {
                materialKind = nil
                return
            }
            materialKind = try? await database.read { db in try CourseMaterial.find(id).fetchOne(db)?.kind }
        }
        .onChange(of: newest, initial: true) { _, newest in
            // The conversation on screen stays the one it opened on: a newer one (a question from
            // the phone, a reminder's) never takes the thread over by itself.
            if model.selected == nil, !model.startsNew, let newest { model.selected = newest }
        }
    }

    /// The thread's room: compact, the panel is at most `maxHeight` (half the window) with its
    /// title row, task line, composer and notice (a tall composer takes from the thread).
    private var threadMaxHeight: CGFloat {
        guard style == .compact else { return maxHeight }
        return max(80, maxHeight - AgentPanelMetrics.compactHeader - bottomHeight)
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
        return Self.prompt(for: context, materialKind: materialKind)
    }

    /// mt: in a material's reader (a page in view) the prompt names it, "Ask about this book" /
    /// "Ask about this paper", and a passage taken to the panel "Ask about the selection"; the
    /// shelf stays "Ask about this course".
    static func prompt(for context: AgentContext, materialKind: MaterialKind? = nil) -> Text {
        switch context.screen {
        case .today: Text("Ask about today")
        case .calendar: Text("Ask about this week")
        case .mail: context.mailMessageID == nil ? Text("Ask about your mail") : Text("Ask about this mail")
        case .lecture: Text("Ask about this lecture")
        case .course where context.materialPassage != nil: Text("Ask about the selection")
        case .course where context.materialID != nil && context.materialPage != nil:
            switch materialKind {
            case .book?: Text("Ask about this book")
            case .paper?: Text("Ask about this paper")
            default: Text("Ask about this document")
            }
        case .course: Text("Ask about this course")
        case .notes: context.noteID == nil ? Text("Ask about your lectures") : Text("Ask about this note")
        case .search: context.selection.isEmpty ? Text("Ask about your lectures") : Text("Ask about the selection")
        case .documents: context.documentID == nil ? Text("Ask about your documents") : Text("Ask about this document")
        default: Text("Ask about your lectures")
        }
    }

    /// ↩ or Send: the words and files go with the context as it is now (the playhead at ↩); the
    /// words show at once as a pending bubble. One message at a time: nothing while one is being
    /// handed over or not stored yet (`pending`), or while the agent answers; never empty.
    private func send(to conversationID: AgentConversation.ID?) {
        guard model.canSendNow else { return }
        model.send(to: conversationID, context: sendContext(), actions: actions)
    }
}

extension AgentPanelModel {
    /// Hands the composer's words and files to `actions.send` (the panel's ↩, the sheet's Send):
    /// they show at once as the pending bubble; a failure puts them back in the composer with one
    /// readable line. Callers check when a message may go (`canSendNow`, the sheet's own rule).
    func send(to conversationID: AgentConversation.ID?, context: AgentContext, actions: AgentPanelActions) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        guard !text.isEmpty || !files.isEmpty, !isSending, reading == 0 else { return }
        var message = PendingPanelMessage(
            text: text, attachments: files, conversationID: conversationID, afterTurns: conversationID == nil ? 0 : turnCount
        )
        message.context = context.settled
        let sentID = message.id
        let sentAt = message.sentAt
        let choice = choices
        pending = message
        awaitingRun = AwaitedRun(conversationID: conversationID, sentAt: sentAt)
        let sent = draft
        attachments = []
        notice = nil
        isSending = true
        askedSinceOpen = true
        // The field empties after AppKit has finished the ↩ that sent it: its field editor still
        // holds the text's range inside the key event.
        Task {
            if draft == sent { draft = "" }
        }
        if let contextLine = actions.contextLine {
            // The faint line the stored turn will carry, for the pending bubble meanwhile.
            Task {
                let line = await contextLine(context)
                if pending?.id == sentID { pending?.line = line }
            }
        }
        Task {
            do {
                let id = try await actions.send(text, context, files, conversationID)
                // A New Chat or another conversation picked meanwhile stays the student's choice;
                // the sent conversation is in the title menu.
                if choices == choice {
                    selected = id
                    startsNew = false
                }
                if pending?.id == sentID, pending?.conversationID == nil { pending?.conversationID = id }
                if awaitingRun?.sentAt == sentAt, awaitingRun?.conversationID == nil { awaitingRun?.conversationID = id }
            } catch {
                ChatUILog.ui.error("Sending to the agent failed: \(String(describing: error), privacy: .public)")
                if pending?.id == sentID { pending = nil }
                if awaitingRun?.sentAt == sentAt { awaitingRun = nil }
                // One line says why (a readable sentence only, never an error's own text).
                notice = (error as? AgentSendFailure)?.sentence ?? String(localized: "Not sent")
                await restore(text: text, files: files)
            }
            isSending = false
        }
    }

    /// A message that did not go back into the composer: its words before whatever the student
    /// wrote since (never while a character is being composed there), its files with the current
    /// ones (up to five): nothing they wrote is dropped.
    private func restore(text: String, files: [AgentAttachment]) async {
        var waited = 0
        while FieldEditor.isComposing, waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        if !text.isEmpty {
            let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            draft = current.isEmpty ? text : text + "\n\n" + draft
        }
        let room = AgentAttachment.maximumPerMessage - attachments.count
        let missing = files.filter { file in !attachments.contains { $0.id == file.id } }
        attachments += missing.prefix(max(0, room))
        if missing.count > max(0, room) {
            notice = String(localized: "At most \(AgentAttachment.maximumPerMessage) files go with one message.")
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

    @State private var showsMemory = false
    /// A drag is in flight (a cancelled one puts the panel back).
    @GestureState private var isMoving = false

    var body: some View {
        HStack(spacing: 2) {
            // At most 200 pt: a long title truncates and leaves the row free to drag the panel by.
            titleMenu
                .frame(maxWidth: isExpanded ? nil : 200, alignment: .leading)
                .layoutPriority(1)
            Color.clear
                .frame(minWidth: 4, maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                #if os(macOS)
                .pointerStyle(move == nil ? nil : (isMoving ? .grabActive : .grabIdle))
                #endif
            AgentPanelHeaderButtons(model: model, isExpanded: isExpanded)
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

    private var titleMenu: some View {
        AgentTitleMenu(model: model, history: history, conversationID: conversationID, showsMemory: $showsMemory)
    }
}

/// ⤢ Expand Chat / ⤡ Shrink Chat and Close, 28 pt each (the title row's trailing end; the expanded
/// header's toolbar item).
struct AgentPanelHeaderButtons: View {
    let model: AgentPanelModel
    let isExpanded: Bool

    var body: some View {
        HStack(spacing: 2) {
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
    }
}

/// The conversation's title as the history menu (the panel's title row, the sheet's): recent
/// conversations by day, titles only, the open one checked; then New Chat and Memory…. 13 pt
/// semibold in the panel ("New Chat" medium tertiary for an empty one); 17 in the sheet.
struct AgentTitleMenu: View {
    let model: AgentPanelModel
    let history: [AgentConversation]
    let conversationID: AgentConversation.ID?
    var fontSize: CGFloat = 13
    var chevronSize: CGFloat = 8.5
    @Binding var showsMemory: Bool

    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    private var current: AgentConversation? {
        conversationID.flatMap { id in history.first { $0.id == id } }
    }

    private var isNew: Bool { current == nil }

    private var title: String {
        guard let current else { return String(localized: "New Chat") }
        let title = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "New Chat") : title
    }

    var body: some View {
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
                    .font(.system(size: fontSize, weight: isNew ? .medium : .semibold))
                    .foregroundStyle(isNew ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: chevronSize, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
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
