import StudyCore
import StudyUI
import SwiftUI

/// One exchange of the panel's thread: the student's message (words and files, with the context
/// it was sent in) and the agent's answer to it.
struct PanelExchange: Identifiable, Equatable {
    var id: AgentTurn.ID
    var text: String
    var context: AgentTurnContext?
    var sentAt: Date
    var answer: String?
}

/// What the thread shows, in order: exchanges and finished sub-agent tasks' results.
enum PanelThreadItem: Identifiable, Equatable {
    /// `showsContextLine`: the faint line with the screen's glyph and label goes before it.
    case exchange(PanelExchange, showsContextLine: Bool, isLast: Bool)
    case task(AgentTask)

    var id: String {
        switch self {
        case .exchange(let exchange, _, _): "e" + exchange.id.uuidString
        case .task(let task): "t" + task.id.uuidString
        }
    }
}

enum PanelThread {
    /// The exchanges of a transcript (the student's message with the answer after it).
    static func exchanges(_ transcript: ChatTranscript) -> [PanelExchange] {
        var exchanges: [PanelExchange] = []
        for entry in transcript.entries {
            switch entry {
            case .student(let id, let text):
                exchanges.append(PanelExchange(
                    id: id, text: text, context: transcript.contexts[id], sentAt: transcript.times[id] ?? .distantPast
                ))
            case .answer(_, let text):
                guard !exchanges.isEmpty else { continue }
                let last = exchanges.count - 1
                exchanges[last].answer = exchanges[last].answer.map { $0 + "\n\n" + text } ?? text
            }
        }
        return exchanges
    }

    /// The items a panel shows: compact, the window's exchanges (since it opened and at least the
    /// latest, the last one, or a render's range); expanded, all. A context line goes before an exchange whose context
    /// label differs from the one before it; before the first when the conversation moved between
    /// screens or was asked elsewhere than the screen on display.
    static func items(
        exchanges: [PanelExchange], tasks: [AgentTask], window: AgentPanelModel.ThreadWindow?, current: AgentContext
    ) -> [PanelThreadItem] {
        let labels = exchanges.map { $0.context?.label }
        func showsLine(_ index: Int) -> Bool {
            guard let label = labels[index], !label.isEmpty else { return false }
            if index > 0 { return labels[index - 1] != label }
            let moved = labels.contains { $0 != nil && $0 != label }
            let elsewhere = exchanges[index].context?.context.map { !sameScreen($0, current) } ?? false
            return moved || elsewhere
        }
        // Each finished task goes after the last exchange sent before it finished.
        var tasksAfter: [Int: [AgentTask]] = [:]
        for task in tasks {
            let finished = task.finishedAt ?? task.updatedAt
            let index = exchanges.lastIndex { $0.sentAt <= finished } ?? (exchanges.isEmpty ? -1 : 0)
            tasksAfter[index, default: []].append(task)
        }
        let shown: Range<Int>
        var since: Date?
        switch window {
        case nil:
            shown = 0..<exchanges.count
        case .exchanges(let range)?:
            shown = range.clamped(to: 0..<exchanges.count)
        case .last?:
            shown = max(0, exchanges.count - 1)..<exchanges.count
        case .since(let date)?:
            since = date
            // Those sent since it opened, and at least the latest (its answer stays in sight).
            let first = exchanges.firstIndex { $0.sentAt >= date } ?? exchanges.count
            shown = min(first, max(0, exchanges.count - 1))..<exchanges.count
        }
        var items: [PanelThreadItem] = []
        if window == nil || shown.lowerBound == 0 {
            for task in tasksAfter[-1] ?? [] where since.map({ (task.finishedAt ?? .distantPast) >= $0 }) ?? true {
                items.append(.task(task))
            }
        }
        for index in shown {
            // The compact panel's first exchange has its line only when it was asked elsewhere
            // (mockup §1: none on the lecture it was asked on).
            let line = window != nil && index == shown.lowerBound
                ? (exchanges[index].context?.label?.isEmpty == false && exchanges[index].context?.context.map { !sameScreen($0, current) } == true)
                : showsLine(index)
            items.append(.exchange(exchanges[index], showsContextLine: line, isLast: index == exchanges.count - 1))
            for task in tasksAfter[index] ?? [] {
                items.append(.task(task))
            }
        }
        if let since, shown.isEmpty {
            // Results that came in since the panel opened, after exchanges it does not show.
            for task in tasks where (task.finishedAt ?? .distantPast) >= since {
                items.append(.task(task))
            }
        }
        return items
    }

    /// The same place in the app: the screen and what it is about (the playhead and the
    /// calendar's week aside).
    static func sameScreen(_ lhs: AgentContext, _ rhs: AgentContext) -> Bool {
        lhs.screen == rhs.screen && lhs.courseID == rhs.courseID && lhs.lectureID == rhs.lectureID
            && lhs.mailMessageID == rhs.mailMessageID && lhs.noteID == rhs.noteID
    }
}

/// The thread of one conversation (or of an empty new one): context lines, the student's messages
/// with their files, the answers with checked chips and change rows, finished task results, the
/// answer being written (a skeleton line until its first words), the state line. Reports the
/// conversation's state to the panel (the composer's Stop, a pending message's place).
struct AgentThreadView: View {
    let style: AgentPanelView.Style
    let conversationID: AgentConversation.ID?
    let model: AgentPanelModel
    let context: AgentContext
    let maxHeight: CGFloat

    @Environment(\.agentPanelActions) private var actions
    @Environment(\.openDestination) private var openDestination
    @Dependency(\.defaultDatabase) private var database
    private let conversationQuery: FetchOne<AgentConversation?>
    private let turnsQuery: FetchAll<AgentTurn>
    private let tasksQuery: FetchAll<AgentTask>
    @State private var transcript = ChatTranscript()
    /// The turns parsed so far: a new turn parses only itself.
    @State private var turnCache = ChatTurnCache()
    @State private var rows = CitationRows()
    /// The answer streaming in (about 10 times a second): read only by the views that draw it
    /// (`LiveAnswerText`), so this body (the exchanges, the items) is not worked out again for it.
    @State private var live = LiveReplyBox()
    /// The compact thread's rows' height, for its faded top edge only (its own height is laid out
    /// with the rows, `UpToHeight`). Reported from the first layout on, so a thread that is too
    /// tall when it appears has the edge too.
    @State private var contentHeight: CGFloat = 0

    init(style: AgentPanelView.Style, conversationID: AgentConversation.ID?, model: AgentPanelModel, context: AgentContext, maxHeight: CGFloat) {
        self.style = style
        self.conversationID = conversationID
        self.model = model
        self.context = context
        self.maxHeight = maxHeight
        // A new chat reads nothing (an id no row has).
        let id = conversationID ?? UUID()
        conversationQuery = FetchOne(AgentConversation.find(id))
        turnsQuery = FetchAll(AgentTurn.where { $0.conversationID.eq(id) }.order(by: \.sequence))
        // Finished tasks: results, and the ones that failed or were cancelled (one line each).
        let finished = [AgentTaskState.succeeded, .failed, .cancelled]
        tasksQuery = FetchAll(
            AgentTask.where { $0.parentConversationID.eq(id) && $0.state.in(finished) }.order { $0.finishedAt.asc() }
        )
    }

    private var conversation: AgentConversation? { conversationQuery.wrappedValue }
    private var isRunning: Bool { conversation?.state == .running }

    /// Whether the live text may show at all: while the run lasts, and after it finished until
    /// its stored turn lands (the answer never blinks out in between); a stopped or failed run's
    /// text goes. `LiveAnswerText` also checks it follows exactly the stored turns.
    private var showsLive: Bool {
        isRunning || conversation?.state == .finished
    }

    /// The run answers the last stored message. While a sent message is not stored yet, the run
    /// (if its state came in first) is that message's: its answer goes after the pending bubble.
    /// Between the message's stored turn and its run's state (two observations, either first), the
    /// hand-over still going on (`isSending`) keeps the skeleton in place.
    private var answersLast: Bool {
        pending == nil && (isRunning || (model.isSending && transcript.awaitsAnswer))
    }

    private var pending: PendingPanelMessage? {
        guard let pending = model.pending, pending.conversationID == conversationID else { return nil }
        return pending
    }

    private var check: CitationCheck { CitationCheck(rows: rows, webPages: transcript.webPages) }

    var body: some View {
        let exchanges = PanelThread.exchanges(transcript)
        let items = PanelThread.items(
            exchanges: exchanges,
            tasks: tasksQuery.wrappedValue.filter { $0.state != .succeeded || ($0.result ?? "").isEmpty == false },
            window: style == .compact ? model.shown : nil, current: context
        )
        // ONE answer being written: the last exchange's (in `exchangeView`), or after the pending
        // bubble, or here alone for a run with no exchange to answer. (Before, the last exchange
        // and the thread's end both drew it: two skeletons for one message, the answer twice.)
        let working = isRunning && pending == nil && exchanges.isEmpty
        let state = stateLine
        let isEmpty = items.isEmpty && pending == nil && !working && state == nil
        observing(Group {
            if isEmpty {
                // Always a view: the observers below must run while nothing shows (a new chat's
                // compact panel is only its title row and composer).
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: style == .expanded ? .infinity : 0)
            } else {
                scroll(items: items, working: working, state: state)
            }
        })
    }

    /// The thread's observers: the stored turns, the conversation's state, the live reply, the
    /// citation rows.
    private func observing(_ content: some View) -> some View {
        content
            .onChange(of: turnsQuery.wrappedValue, initial: true) { _, turns in
                transcript = ChatTranscript(turns: turns, cache: turnCache)
                model.turnCount = turns.count
                if let sent = pending, transcript.turnCount > sent.afterTurns { model.pending = nil }
                pinPickedWindow()
            }
            .onChange(of: model.shown, initial: true) {
                pinPickedWindow()
            }
            .onChange(of: conversation?.state, initial: true) { _, state in
                model.isRunning = state == .running
            }
            .task(id: conversationID) {
                guard let conversationID else { return }
                if live.sawMarker { live.sawMarker = false }
                for await reply in actions.liveReply(conversationID) {
                    live.reply = reply
                    // Set once (each set re-renders the thread): the citation rows are read for it.
                    if !live.sawMarker, reply?.text.contains("[[") == true { live.sawMarker = true }
                }
            }
            .task(id: citesLectures) {
                // The rows lecture markers are checked against, once an answer has one.
                guard citesLectures >= 0 else { return }
                do {
                    rows = try await CitationRows.load(database)
                } catch {
                    ChatUILog.ui.error("Reading citation rows failed: \(String(describing: error), privacy: .public)")
                }
            }
            .environment(\.openURL, OpenURLAction { url in open(url) })
    }

    /// Compact: as tall as the thread up to `maxHeight` (sized in the same layout pass as its
    /// rows, so it grows and shrinks with them without a frame's lag), then it scrolls under a
    /// faded top edge. Expanded: the whole column, anchored to the bottom.
    @ViewBuilder
    private func scroll(items: [PanelThreadItem], working: Bool, state: AnyView?) -> some View {
        if style == .compact {
            let overflows = contentHeight > maxHeight + 0.5
            UpToHeight(maxHeight: maxHeight) {
                ScrollView {
                    threadContent(items: items, working: working, state: state)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded() } action: { contentHeight = $0 }
                }
                .defaultScrollAnchor(.bottom)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
                .scrollIndicators(.automatic)
            }
            .mask {
                VStack(spacing: 0) {
                    if overflows {
                        LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 40)
                    }
                    Rectangle()
                }
            }
        } else {
            ScrollView {
                threadContent(items: items, working: working, state: state)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
        }
    }

    private func threadContent(items: [PanelThreadItem], working: Bool, state: AnyView?) -> some View {
        let isCompact = style == .compact
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(items) { item in
                switch item {
                case .exchange(let exchange, let showsLine, let isLast):
                    exchangeView(exchange, showsLine: showsLine, isLast: isLast)
                case .task(let task):
                    if task.state == .succeeded {
                        TaskResultBlock(task: task, rows: rows, now: model.now)
                    } else {
                        TaskUnfinishedLine(task: task)
                    }
                }
            }
            if let pending {
                PanelStudentMessage(text: pending.text, attachments: pending.attachments, maxWidth: bubbleWidth)
            }
            if pending != nil || working {
                // After a pending message nothing streams yet (its run is not this one's).
                LiveAnswerText(
                    live: pending == nil ? liveSource : nil, stored: nil, running: true, check: check,
                    openLecture: context.lectureID, now: model.now
                )
            }
            if let state {
                state
            }
        }
        .padding(.horizontal, isCompact ? 14 : 16)
        .padding(.top, isCompact ? 2 : 14)
        .padding(.bottom, isCompact ? 12 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubbleWidth: CGFloat { style == .compact ? 250 : 264 }

    @ViewBuilder
    private func exchangeView(_ exchange: PanelExchange, showsLine: Bool, isLast: Bool) -> some View {
        let running = isLast && answersLast
        VStack(alignment: .leading, spacing: 12) {
            if showsLine, let label = exchange.context?.label {
                FaintLine(glyph: exchange.context?.glyph ?? "bubble.left", label: label)
            }
            PanelStudentMessage(text: exchange.text, attachments: exchange.context?.attachments ?? [], maxWidth: bubbleWidth)
            // The live text follows exactly the stored turns, so it is the last exchange's.
            LiveAnswerText(
                live: isLast && pending == nil ? liveSource : nil, stored: exchange.answer, running: running, check: check,
                openLecture: exchange.context?.context?.lectureID ?? context.lectureID, now: model.now
            )
        }
    }

    /// The live reply as the last answer reads it.
    private var liveSource: LiveSource {
        LiveSource(box: live, afterTurns: transcript.turnCount, isShown: showsLive)
    }

    /// A conversation picked in the title menu opens on its last exchange; from then on the
    /// compact panel shows that one and every follow-up (`.since` its time).
    private func pinPickedWindow() {
        guard model.shown == .last, let last = PanelThread.exchanges(transcript).last else { return }
        model.shown = .since(last.sentAt)
    }

    static func joined(_ text: String?, _ live: String?) -> String? {
        guard let live else { return text }
        guard let text, !text.isEmpty else { return live }
        return text + "\n\n" + live
    }

    /// Some answer (or the one being written) has a marker: the rows are read (again when the
    /// conversation grows).
    private var citesLectures: Int {
        let hasMarker = transcript.entries.contains { entry in
            if case .answer(_, let text) = entry { return text.contains("[[") }
            return false
        } || live.sawMarker || tasksQuery.wrappedValue.contains { ($0.result ?? "").contains("[[") }
        return hasMarker ? transcript.turnCount : -1
    }

    /// A chip: the lecture at its slide or playing from its moment; a web page in the browser.
    private func open(_ url: URL) -> OpenURLAction.Result {
        if let destination = AnswerText.destination(link: url) {
            openDestination(destination)
            return .handled
        }
        guard url.scheme?.lowercased() == "https" else { return .discarded }
        return .systemAction(url)
    }

    /// Why the last message has no answer: a usage pause ("Paused until 17:20"), or "Not answered"
    /// with the reason on hover. A run the student stopped needs no line.
    private var stateLine: AnyView? {
        // Not while a new message is handed over (the last run's state until the new one's lands).
        guard let conversation, conversation.state == .failed, pending == nil, !model.isSending else { return nil }
        let error = conversation.error ?? ""
        guard error != "Stopped." else { return nil }
        if let until = actions.pausedUntil, until > Date() {
            let time = Text(DayText.time(until, timeZone: .current)).font(.mono(12))
            return AnyView(
                Text("Paused until \(time)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            )
        }
        return AnyView(
            Label("Not answered", systemImage: "exclamationmark.triangle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .help(Text(verbatim: error))
        )
    }
}

/// The faint line before an exchange asked on another screen (11 pt tertiary: the screen's glyph
/// and label, then a hairline), or before a task's result (`checklist` + its title).
struct FaintLine: View {
    let glyph: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: glyph)
                .font(.system(size: 10.5))
                .accessibilityHidden(true)
            Text(verbatim: label)
                .lineLimit(1)
                .layoutPriority(1)
            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
                .padding(.leading, 4)
        }
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
        .accessibilityElement(children: .combine)
    }
}

/// The student's message: the files as small tiles above the bubble (in the student's order),
/// then the words on Fill 2, radius 14/14/4/14, trailing.
struct PanelStudentMessage: View {
    let text: String
    let attachments: [AgentAttachment]
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !attachments.isEmpty {
                TileFlow(spacing: 6, alignment: .trailing) {
                    ForEach(attachments) { attachment in
                        SentAttachmentTile(attachment: attachment)
                    }
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .lineSpacing(2)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 11)
                    .background(
                        Fill2(),
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14,
                            style: .continuous
                        )
                    )
            }
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A finished sub-agent task: a faint `checklist` line with its title, then its result as an
/// answer (web chips checked against the task's own tool results).
private struct TaskResultBlock: View {
    let task: AgentTask
    let rows: CitationRows
    let now: Date

    private let turnsQuery: FetchAll<AgentTurn>
    @State private var webPages: [String: URL] = [:]
    @State private var turnCache = ChatTurnCache()

    init(task: AgentTask, rows: CitationRows, now: Date) {
        self.task = task
        self.rows = rows
        self.now = now
        let id = task.conversationID ?? UUID()
        turnsQuery = FetchAll(AgentTurn.where { $0.conversationID.eq(id) }.order(by: \.sequence))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FaintLine(glyph: "checklist", label: task.title)
            PanelAnswer(
                text: task.result ?? "", isWorking: false, isStreaming: false, check: CitationCheck(rows: rows, webPages: webPages),
                openLecture: task.lectureID, now: now
            )
        }
        .onChange(of: turnsQuery.wrappedValue.count, initial: true) {
            let turns = turnsQuery.wrappedValue
            webPages = turns.isEmpty ? [:] : ChatTranscript(turns: turns, cache: turnCache).webPages
        }
    }
}

/// A sub-agent task that failed or was cancelled: one quiet line, "Research QEMU didn't finish:
/// the usage limit was reached." (the whole reason on hover).
private struct TaskUnfinishedLine: View {
    let task: AgentTask

    var body: some View {
        let reason = (task.error ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = reason.isEmpty ? String(localized: "\(task.title) didn’t finish.") : String(localized: "\(task.title) didn’t finish: \(reason)")
        Text(verbatim: line)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(Text(verbatim: line))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The answer streaming in, held apart from the thread's state: setting it re-renders only the
/// views that read `reply` (`LiveAnswerText`).
@MainActor
@Observable
final class LiveReplyBox {
    var reply: ChatLiveReply?
    /// Some live text had a marker: the thread reads its citation rows.
    var sawMarker = false
}

/// The live reply as one answer may show it: after exactly `afterTurns` stored turns, while
/// `isShown` (the run lasts, or finished until its stored turn lands).
struct LiveSource {
    let box: LiveReplyBox
    let afterTurns: Int
    let isShown: Bool

    @MainActor
    var text: String? {
        guard isShown, let reply = box.reply, reply.afterTurns == afterTurns, !reply.text.isEmpty else { return nil }
        return reply.text
    }
}

/// An answer that may end in the live text (the only view reading it, so streaming at 10 Hz
/// re-renders this answer alone): the stored text, then what streams in; a skeleton while the run
/// answers and nothing came yet.
private struct LiveAnswerText: View {
    /// Nil: no live text goes here.
    let live: LiveSource?
    let stored: String?
    /// The run answers this exchange.
    let running: Bool
    let check: CitationCheck
    let openLecture: Lecture.ID?
    let now: Date

    var body: some View {
        let streamed = live?.text
        let answer = AgentThreadView.joined(stored, streamed)
        if let answer, !answer.isEmpty {
            PanelAnswer(
                text: answer, isWorking: running && streamed == nil, isStreaming: running || streamed != nil, check: check,
                openLecture: openLecture, now: now
            )
        } else if running {
            PanelAnswer(text: "", isWorking: false, isStreaming: true, check: check, openLecture: nil, now: now)
        }
    }
}

// MARK: - Answers

/// An answer in the panel: grey 13 pt text with ONE sparkle at its start, inline Markdown, checked
/// chips (slides, moments, web pages), and the activity log's change rows where it cites them
/// (`[[change …]]`, one row each, a list per run of markers). `isWorking`: a skeleton line follows.
struct PanelAnswer: View {
    let text: String
    let isWorking: Bool
    /// Still being written: a marker not closed yet is left out, and nothing is logged.
    let isStreaming: Bool
    let check: CitationCheck
    let openLecture: Lecture.ID?
    let now: Date

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let blocks = PanelAnswerBlock.split(isStreaming ? AnswerText.withoutOpenMarker(text) : text)
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    AIMark()
                    skeleton
                }
            }
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                switch block {
                case .text(let paragraph):
                    let answer = AnswerText(
                        paragraph, check: paragraph.contains("[[") ? check : nil, logs: !isStreaming, openLecture: openLecture
                    )
                    answerText(answer, sparkle: index == 0)
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                case .changes(let keys):
                    AgentChangeList(keys: keys, showsSparkle: index == 0, now: now)
                        .id(keys)
                }
            }
            if isWorking, !blocks.isEmpty {
                skeleton
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func answerText(_ answer: AnswerText, sparkle: Bool) -> some View {
        if answer.hasChips {
            answer.text(sparkle: sparkle)
                .textRenderer(AnswerChipRenderer(colorScheme: colorScheme))
        } else {
            answer.text(sparkle: sparkle)
                .textSelection(.enabled)
        }
    }

    /// The line's final size, redacted, no shimmer.
    private var skeleton: some View {
        Text(verbatim: "The answer is being written for you now")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .redacted(reason: .placeholder)
            .accessibilityHidden(true)
    }
}

/// An answer cut into its text and its runs of change markers.
enum PanelAnswerBlock: Hashable {
    case text(String)
    /// Change keys in order: one list.
    case changes([String])

    static func split(_ text: String) -> [PanelAnswerBlock] {
        guard text.contains("[[change ") else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [.text(trimmed)]
        }
        var blocks: [PanelAnswerBlock] = []
        var buffer = ""
        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.text(trimmed)) }
            buffer = ""
        }
        for piece in ChatCitation.pieces(of: text) {
            switch piece {
            case .text(let words):
                buffer += words
            case .citation(.change(let key)):
                flush()
                if case .changes(let keys)? = blocks.last {
                    if !keys.contains(key) { blocks[blocks.count - 1] = .changes(keys + [key]) }
                } else {
                    blocks.append(.changes([key]))
                }
            case .citation(let citation):
                buffer += citation.marker
            }
        }
        flush()
        return blocks
    }
}

// MARK: - Tiles layout

/// Tiles in rows that wrap (the composer's files, a sent message's files).
struct TileFlow: Layout {
    var spacing: CGFloat = 6
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews: subviews) {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

// MARK: - Compact height

/// Its content's ideal height up to `maxHeight` (a scroll view: as tall as its rows, then it
/// scrolls), worked out in the same layout pass as the rows.
struct UpToHeight: Layout {
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let ideal = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(max(ideal.height, 1), maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
