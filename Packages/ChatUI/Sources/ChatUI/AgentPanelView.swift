import StudyCore
import StudyUI
import SwiftUI

/// The chat's one component, in every size (mockup "the agent panel: one component, two sizes"):
/// the title row (the conversation's title as the history menu, ⤢ / ⤡, close), the thread, the
/// task line and the composer. The Mac's Agent pane draws it without the title row (the pane host's
/// header carries the menu, `AgentPaneAccessory`).
struct AgentPanelView: View {
    enum Style: Hashable {
        /// The small chat (the Mac's floating panel, the iPad's overlay).
        case compact
        /// The Mac's Agent pane, the iPad's column.
        case expanded
        /// M7: the iPhone's sheet (`AgentSheet`; its thread only).
        case sheet
    }

    enum Header: Hashable {
        /// None: the Mac's Agent pane (its header is the pane host's).
        case none
        /// In the chat (the small chat; the expanded one in renders).
        case inline
        #if os(iOS)
        /// The iPad's expanded column: its header as toolbar items level with the toolbar.
        case toolbar
        #endif
    }

    let style: Style
    let model: AgentPanelModel
    /// Compact: the chat's greatest height (half the window; infinity in the Mac's floating panel,
    /// which proposes its own); expanded: the thread's (infinity).
    let maxHeight: CGFloat
    let header: Header
    /// Dragging the title row's free part moves the small chat (nil: it does not move).
    let drag: PanelDrag?
    /// The small chat fills the height it is given (the student resized the floating panel): the
    /// thread takes the room left, its rows at the bottom.
    let fillsHeight: Bool

    @Environment(\.agentPanelActions) private var actions
    private let historyQuery: FetchAll<AgentConversation>
    /// The small chat's task line, composer and notice, measured (the thread gets the rest).
    @State private var bottomHeight: CGFloat = 52
    /// mt: the kind of the material the reader shows (the prompt names a book or a paper).
    @State private var materialKind: MaterialKind?
    @Dependency(\.defaultDatabase) private var database

    init(
        style: Style, model: AgentPanelModel, maxHeight: CGFloat, header: Header, drag: PanelDrag? = nil, fillsHeight: Bool = false
    ) {
        self.style = style
        self.model = model
        self.maxHeight = maxHeight
        self.header = header
        self.drag = drag
        self.fillsHeight = fillsHeight
        historyQuery = AgentHistory.query()
    }

    private var history: [AgentConversation] { historyQuery.wrappedValue }

    /// The most recently active conversation: the one the chat opens on.
    private var newest: AgentConversation.ID? { AgentHistory.newest(history) }

    private var conversationID: AgentConversation.ID? { model.conversationID(newest: newest) }

    var body: some View {
        #if os(iOS)
        if header == .toolbar {
            // The header as the toolbar's own items over the column (title, flexible space, ⤡ and
            // Close), laid out by the toolbar: nothing measures the column, so dragging its edge
            // or resizing the window never rebuilds a toolbar item.
            panel
                .toolbar {
                    // Only while shown: SwiftUI keeps a hidden inspector's content (and these) alive.
                    if model.mode == .expanded {
                        ToolbarItem(placement: .automatic) {
                            AgentTitleMenu(model: model, history: history, conversationID: conversationID)
                                .frame(maxWidth: AgentPanelMetrics.titleWidth, alignment: .leading)
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
        } else {
            // No toolbar content from the compact panel: its updates never touch the window's toolbar.
            panel
        }
        #else
        panel
        #endif
    }

    private var panel: some View {
        let conversationID = conversationID
        let context = model.shownContext
        let fills = style == .expanded || fillsHeight
        return VStack(spacing: 0) {
            if header == .inline {
                titleRow
                    .frame(height: style == .compact ? AgentPanelMetrics.compactHeader : AgentPanelMetrics.expandedHeader)
                if style == .expanded { Hairline() }
            }
            #if os(iOS)
            if header == .toolbar { Hairline() }
            #endif
            AgentThreadView(style: style, conversationID: conversationID, model: model, context: context, maxHeight: threadMaxHeight)
                .id(conversationID)
                .frame(maxHeight: fillsHeight ? .infinity : nil, alignment: .bottom)
            VStack(spacing: 0) {
                AgentTaskLineSection(conversationID: conversationID, now: model.now)
                    .padding(.horizontal, style == .compact ? 14 : 16)
                AgentComposer(model: model, style: style, prompt: prompt(context), conversationID: conversationID) {
                    send(to: conversationID)
                }
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
        .frame(maxHeight: fills ? .infinity : nil, alignment: .top)
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

    /// The thread's room: compact, the chat is at most `maxHeight` with its title row, task line,
    /// composer and notice (a tall composer takes from the thread).
    private var threadMaxHeight: CGFloat {
        guard style == .compact else { return maxHeight }
        return max(80, maxHeight - AgentPanelMetrics.compactHeader - bottomHeight)
    }

    // MARK: Header

    private var titleRow: some View {
        AgentPanelHeader(model: model, history: history, conversationID: conversationID, isExpanded: style == .expanded, drag: drag)
            .padding(.leading, style == .compact ? 6 : 8)
            .padding(.trailing, style == .compact ? 6 : 10)
    }

    // MARK: Composer

    /// The prompt names what the next message is about; after a question since the chat appeared,
    /// "Ask a follow-up…".
    private func prompt(_ context: AgentContext) -> Text {
        if model.askedSinceOpen || model.pending != nil { return Text("Ask a follow-up…") }
        return Self.prompt(for: context, materialKind: materialKind)
    }

    /// mt: in a material's reader (a page in view) the prompt names it, "Ask about this book" /
    /// "Ask about this paper", and a passage taken to the chat "Ask about the selection"; the
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
        model.send(to: conversationID, context: model.sendContext(), actions: actions)
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

/// A drag on the small chat's title row: the Mac's floating panel moves its layer
/// (`\.floatingPanelMover`), the iPad's overlay moves by an offset (`PanelMove`). Translations are
/// in window points since the drag began.
struct PanelDrag {
    var changed: @MainActor (CGSize) -> Void
    var ended: @MainActor (CGSize) -> Void
    /// The gesture ended without `ended` (the window lost the pointer).
    var cancelled: @MainActor () -> Void
}

#if os(macOS)
extension PanelDrag {
    /// The floating panel's mover: a cancelled drag leaves the panel where it was dragged to.
    init(_ mover: FloatingPanelMover) {
        self.init(changed: mover.changed, ended: { _ in mover.ended() }, cancelled: mover.ended)
    }
}
#endif

/// The title row: the conversation's title as a menu (recent conversations by day, titles only;
/// New Chat, Memory…), then ⤢ Expand / ⤡ Shrink and Close. The small chat moves by dragging it.
private struct AgentPanelHeader: View {
    let model: AgentPanelModel
    let history: [AgentConversation]
    let conversationID: AgentConversation.ID?
    let isExpanded: Bool
    let drag: PanelDrag?

    /// A drag is in flight (a cancelled one ends where it is).
    @GestureState private var isMoving = false
    /// `ended` has not run for the drag in flight.
    @State private var isDragging = false

    var body: some View {
        HStack(spacing: 2) {
            // At most 200 pt: a long title truncates and leaves the row free to drag the chat by.
            AgentTitleMenu(model: model, history: history, conversationID: conversationID)
                .frame(maxWidth: isExpanded ? nil : AgentPanelMetrics.titleWidth, alignment: .leading)
                .layoutPriority(1)
            Color.clear
                .frame(minWidth: 4, maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                #if os(macOS)
                .pointerStyle(drag == nil ? nil : (isMoving ? .grabActive : .grabIdle))
                #endif
            AgentPanelHeaderButtons(model: model, isExpanded: isExpanded)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        // Window coordinates: the translation does not change as the chat moves under the pointer.
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .updating($isMoving) { _, moving, _ in moving = true }
                .onChanged { value in
                    isDragging = true
                    drag?.changed(value.translation)
                }
                .onEnded { value in
                    isDragging = false
                    drag?.ended(value.translation)
                },
            isEnabled: drag != nil
        )
        .onChange(of: isMoving) { _, moving in
            guard !moving, isDragging else { return }
            isDragging = false
            drag?.cancelled()
        }
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
            // The sheet comes from `.agentPanel` (or the iPhone's sheet): never from a pane or the
            // floating panel, which are other hosting views.
            Button("Memory…") { model.showsMemory = true }
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

/// The title menu's conversations: the 40 most recent `app` conversations, newest first.
enum AgentHistory {
    static let limit = 40

    static func query() -> FetchAll<AgentConversation> {
        FetchAll(AgentConversation.where { $0.kind.eq(ConversationKind.app) }.order { $0.createdAt.desc() }.limit(limit))
    }

    /// The most recently active conversation: the one a chat opens on.
    static func newest(_ history: [AgentConversation]) -> AgentConversation.ID? {
        history.max { $0.updatedAt < $1.updatedAt }?.id
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
