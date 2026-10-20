import Agent
import ClaudeKit
import Coach
import Courses
import Deadlines
import Documents
import Foundation
import Filing
import GRDB
import MailIntelligence
import Search
import StudyCore
import StudyPass

/// The one app agent (milestone ma, docs/plan-agent.md §5.1): the panel's conversation on every
/// screen, the batched triage of new facts, the sub-agent task queue and the reminders.
///
/// Wiring (the integrator, plan §8.2):
///
///     let specs = AppAgent.specs(services: s, search: engine, drafter: mailPipeline.drafter, memory: memory,
///                                documents: bank)   // md: the app's DocumentBank (Mac; keep_document)
///     let runtime = AgentRuntime(services: s, client: client, memory: memory,
///                                additionalSpecs: [/* mail chat, tutor */].merging(specs.additional) { $1 },
///                                conversationSpecs: specs.perConversation)
///     let agent = AppAgent(services: s, client: client, runtime: runtime, memory: memory,
///                          schedule: CourseSchedule(services: s), studyPass: studyPassPipeline,
///                          coach: coach,   // mc: the CoachEngine (queue runners); also AppAgent.specs(…, coach:)
///                          specs: specs,   // the queue starts `task` conversations with `specs.task`
///                          documents: bank) // md
///     await agent.start()           // startBackgroundWork, after the pipelines
///     await agent.wake()            // new mail, finished transcriptions, study pass units, imports,
///                                   // calendar changes, Claude Code turning available
///     agent.prepareForQuit()        // NSApplication.willTerminate, before the claude processes end
///     await agent.stop()            // then
///     await agent.setBackgroundLimit(memoryLow ? 1 : nil)
public actor AppAgent {
    let services: StudyServices
    let client: ClaudeClient
    let runtime: AgentRuntime
    let memory: DeadlineMemory
    let schedule: CourseSchedule
    let studyPass: StudyPassPipeline?
    /// mc: the study coach (question drafting and old exams run in the task queue; nil on iOS).
    let coach: CoachEngine?
    /// Smart slide filing: slides dropped on the panel are filed where the advisor says (an
    /// automatic change with Undo) instead of being sent whole.
    let filing: FilingService?
    let advisor: (any FilingAdvisor)?
    /// md: the app's document bank (the Mac; nil: none). The panel's `keep_document` reaches it
    /// through `specs(…, documents:)`; the queue's `document` tasks need only the rows.
    let documents: DocumentBank?
    let now: @Sendable () -> Date

    /// The activity log and write path of every automatic change.
    public nonisolated let changeLog: ChangeLog
    let queue: AgentTaskQueue
    let triage: FactTriage
    let reminders: ReminderCenter
    let quit: QuitSignal

    private var triageTask: Task<Void, Never>?
    private var triageAgain = false
    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?
    private var reminderObservation: AnyDatabaseCancellable?
    private var reminderFollower: Task<Void, Never>?
    private var pauseWake: Task<Void, Never>?
    private var started = false
    /// M7: the questions asked on the iPhone (`agent_request`), answered here (Mac only).
    private var pickup: AgentRequestPickup?

    public init(
        services: StudyServices,
        client: ClaudeClient,
        runtime: AgentRuntime,
        memory: DeadlineMemory,
        schedule: CourseSchedule,
        studyPass: StudyPassPipeline?,
        coach: CoachEngine? = nil,
        specs: Specs,
        filing: FilingService? = nil,
        advisor: (any FilingAdvisor)? = nil,
        documents: DocumentBank? = nil,
        wakeProcessing: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.runtime = runtime
        self.memory = memory
        self.schedule = schedule
        self.studyPass = studyPass
        self.coach = coach
        self.filing = filing
        self.advisor = advisor
        self.documents = documents
        self.now = now
        let changeLog = ChangeLog(
            services: services, memory: memory, filing: filing, documents: documents, wakeProcessing: wakeProcessing, now: now
        )
        self.changeLog = changeLog
        let quit = QuitSignal()
        self.quit = quit
        queue = AgentTaskQueue(
            services: services, client: client, runtime: runtime, studyPass: studyPass, coach: coach, taskSpec: specs.task, quit: quit,
            now: now
        )
        triage = FactTriage(services: services, client: client, changeLog: changeLog, quit: quit, now: now)
        reminders = ReminderCenter(services: services, changeLog: changeLog, now: now)
    }

    // MARK: - Specs

    /// The conversation specs for the agent runtime: `.app` (an `AgentRuntime.SpecProvider`) and
    /// `.task` (per conversation, from its `agent_task` row).
    public struct Specs: Sendable {
        public var additional: [ConversationKind: AgentRuntime.SpecProvider]
        public var perConversation: [ConversationKind: AgentRuntime.ConversationSpecProvider]
        /// A sub-agent task's spec from its row (the queue starts its conversation with it: the
        /// row is linked to the conversation only after the conversation row exists).
        public var task: @Sendable (AgentTask) async throws -> ConversationSpec
    }

    /// `search`: the app's engine (with its semantic index; its planner is not used). `drafter`:
    /// the mail pipeline's `ReplyDrafter` (draft_reply; nil: no drafts). `memory`: the app's
    /// deadline memory (its `onChange` syncs the calendar after the agent's writes). `coach` (mc):
    /// the study coach the plan tools replan through. `documents` (md): the app's document bank
    /// (`keep_document`; nil: the panel cannot keep files, the read tools still work).
    /// `wakeProcessing` (mr): the lecture processor's `wake()`, after link_deck_pages / unlink_deck
    /// or their Undo queued alignment.
    public static func specs(
        services: StudyServices, search: SearchEngine, drafter: ReplyDrafter?, memory: DeadlineMemory, coach: CoachEngine? = nil,
        documents: DocumentBank? = nil, wakeProcessing: @escaping @Sendable () async -> Void = {},
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Specs {
        let deps = AppAgentChat.Services(
            services: services, search: search, drafter: drafter, memory: memory, coach: coach, documents: documents,
            wakeProcessing: wakeProcessing, now: now
        )
        return Specs(
            additional: [.app: { try AppAgentChat.spec(deps) }],
            perConversation: [.task: { conversationID in try await AppAgentChat.taskSpec(deps, conversationID: conversationID) }],
            task: { task in try AppAgentChat.taskSpec(deps, task: task) }
        )
    }

    // MARK: - The panel

    /// Sends the student's message (with what they see and the files they attached) to
    /// `conversation` (nil: a new `app` conversation); returns its id at once while the agent
    /// answers in the background. The user turn carries, before the words: the attachments as
    /// image / document blocks, the `<catalog>` and `<context>` blocks when they changed since
    /// the conversation last carried them, and the results of its finished tasks no turn has
    /// carried yet (`<task_result>`, then `reported_at`), and (mc) the reminders shown since the
    /// student last wrote to the newest `app` conversation (`<reminder>`, when this message goes
    /// there or starts a new one). `agent_turn.context` keeps the context,
    /// the thread's context line (when the screen changed) and the attachments.
    public func send(
        _ text: String, context: AgentContext, attachments: [AgentAttachment], to conversation: AgentConversation.ID?
    ) async throws -> AgentConversation.ID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { throw AgentRuntime.RuntimeError.emptyText }
        var history: [AgentTurn] = []
        if let conversation { history = try await ConversationRepository(store: services.records).turns(conversation) }
        let texts = Self.userTexts(history)
        // Slides are filed where the advisor says (a `<filed>` block in the turn); every other
        // file goes as it is (a PDF whole within the document limits, else its first pages as
        // `<attached_file>`; md: Word, RTF and Pages as their text).
        var whole: [AgentAttachment] = []
        var filed: [ContentBlock] = []
        for attachment in attachments {
            if attachment.kind == .pdf, let block = await fileSlides(attachment, words: trimmed, conversation: conversation) {
                filed.append(block)
            } else {
                whole.append(attachment)
            }
        }
        var blocks = try await AttachmentBlocks.contentBlocks(whole, blobs: services.blobs) + filed
        let actions = ActionRegistry.appCount(documents: documents != nil)
        let catalog = try await AgentCatalog.build(services: services, now: now(), actions: actions)
        if AgentCatalog.lastRevision(in: texts) != catalog.revision { blocks.append(.text(catalog.text)) }
        let block = try await AgentContextBlock.build(context, services: services)
        if AgentContextBlock.lastRevision(in: texts) != block.revision { blocks.append(.text(block.text)) }
        blocks += try await reminderBlocks(for: conversation, history: history).map { .text($0) }
        var reported: [AgentTask.ID] = []
        // Whether untrusted text is in this conversation (carried now or by an earlier turn): a
        // mail-, (md) documents- or web-group task's result, or (md) a file sent as its text (Word,
        // RTF, Pages, a long PDF's first pages). A web task it spawns then gets no input summary.
        var untrusted = (history.compactMap(\.context).flatMap(\.attachments) + whole).contains(where: AttachmentBlocks.sentAsText)
        if let conversation {
            let repository = AgentTaskRepository(store: services.records)
            for task in try await repository.unreported(parent: conversation) {
                blocks.append(.text(Self.taskResult(task)))
                reported.append(task.id)
            }
            if try await repository.tasks(parent: conversation).contains(where: Self.carriesUntrustedResult) { untrusted = true }
        }
        // The thread's faint line: only when the screen changed since the last message.
        let previous = history.last { $0.role == .user && $0.context?.context != nil }?.context?.context
        let changed = previous?.settled != context.settled
        let turnContext = AgentTurnContext(
            context: context, label: changed ? block.label : nil, glyph: changed ? block.glyph : nil, attachments: attachments
        )
        let id: AgentConversation.ID
        if let conversation {
            try await runtime.send(trimmed, context: blocks, turnContext: turnContext, readUntrustedContent: untrusted, to: conversation)
            id = conversation
        } else {
            let title = trimmed.isEmpty ? (attachments.first?.fileName ?? "Files") : trimmed
            id = try await runtime.start(
                .app, text: trimmed, context: blocks, courseID: context.courseID, turnContext: turnContext, title: title,
                readUntrustedContent: untrusted
            )
        }
        // The message is with the runtime: nothing may bounce it now (a result carried twice is
        // better than a sent message shown as failed).
        do {
            try await AgentTaskRepository(store: services.records).markReported(reported)
        } catch {
            AppAgentModule.log.error("Marking task results reported failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
        return id
    }

    /// Files a PDF dropped on the panel as slides when the advisor (with the student's words)
    /// says it is a lecture's deck and is sure: through smart import as an automatic change with
    /// Undo. The `<filed>` block for the turn; nil: it is not slides, the advisor is unsure or
    /// unavailable, or filing failed (the PDF then goes whole, within the document limits).
    private func fileSlides(_ attachment: AgentAttachment, words: String, conversation: AgentConversation.ID?) async -> ContentBlock? {
        guard let filing, let advisor else { return nil }
        // A copy under the file's own name: the filing keeps the name the student dropped.
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "StudyPortal-panel-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        var name = (attachment.fileName as NSString).lastPathComponent
        if name.isEmpty || name.hasPrefix(".") { name = "Slides.pdf" }
        if (name as NSString).pathExtension.lowercased() != "pdf" { name += ".pdf" }
        let url = directory.appending(path: name)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: services.blobs.url(for: attachment.blob), to: url)
        } catch {
            AppAgentModule.log.error("Copying a dropped PDF failed: \(ReadableError.kind(of: error), privacy: .public)")
            return nil
        }
        guard let request = await filing.adviceRequest(forDeckAt: url, studentWords: words),
              let raw = await advisor.advise(request), let advice = request.validated(raw),
              advice.isSlides, advice.confidence >= FilingAdvice.applyThreshold,
              let filed = await filing.file(url, following: advice, quote: request.firstLine, conversationID: conversation)
        else { return nil }
        AppAgentModule.log.info("Filed slides from the panel (\(advice.confidence, privacy: .public))")
        return AttachmentBlocks.filed(filed, fileName: attachment.fileName, reason: advice.reason)
    }

    /// Stops the agent's answer in `id` (the conversation ends `failed`, "Stopped.").
    public func stop(_ id: AgentConversation.ID) async {
        await runtime.stop(id)
    }

    /// The answer being written in `id`, about ten times a second (nil when nothing streams).
    public nonisolated func liveReplies(_ id: AgentConversation.ID) -> AsyncStream<LiveReply?> {
        runtime.liveReplies(id)
    }

    /// Cancels a sub-agent task (its process is ended).
    public func cancelTask(_ id: AgentTask.ID) async {
        await queue.cancel(id)
    }

    /// Undo of one change of the activity log (a change row, the panel's Undo).
    public func undo(_ change: AgentChange.ID) async throws {
        try await changeLog.undo(change)
    }

    /// Undo from an item's popover or Mail's found row: session changes through the log, else
    /// the deadline memory.
    public func undo(sourceID: TrackedItemSource.ID) async throws {
        try await changeLog.undo(sourceID: sourceID)
    }

    /// The timetable import's recorder (`TimetableImporter.apply(…, sessionChange:)`).
    public nonisolated var timetableRecorder: TimetableSessionChangeRecorder {
        ChangeLog.timetableRecorder(store: services.records)
    }

    // MARK: - Background work

    /// Starts the task queue (re-queueing what a quit interrupted), follows the triage inbox
    /// (`agent_event`), plans and delivers reminders, and runs a first triage in the background.
    public func start() async {
        guard !started else { return }
        started = true
        await queue.start()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        observation = DatabaseRegionObservation(tracking: SQLRequest<Row>(sql: "SELECT id, state FROM agent_event"))
            .start(
                in: services.database,
                onError: { error in AppAgentModule.log.error("Event observation failed: \(String(describing: error), privacy: .public)") },
                onChange: { _ in continuation.yield() }
            )
        follower = Task { [weak self] in
            for await _ in stream {
                // Producers write several events at once (a mail pass): wait for a quiet moment.
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                await self?.wakeTriage()
            }
        }
        // A reminder set, moved or cancelled anywhere (set_reminder, Undo, an item done): the
        // reminders plan, deliver and set their next timer again.
        let (changes, changed) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        reminderObservation = DatabaseRegionObservation(
            tracking: SQLRequest<Row>(sql: "SELECT id, fire_at, delivered_at, cancelled_at FROM agent_reminder")
        )
        .start(
            in: services.database,
            onError: { error in AppAgentModule.log.error("Reminder observation failed: \(String(describing: error), privacy: .public)") },
            onChange: { _ in changed.yield() }
        )
        let reminders = reminders
        reminderFollower = Task {
            for await _ in changes {
                await reminders.check()
            }
        }
        #if os(macOS)
        // M7: the iPhone's questions, through the panel's own `send` (never on the phone).
        let pickup = AgentRequestPickup(services: services, client: client, runtime: runtime, now: now) { [weak self] text, context, files, id in
            guard let self else { throw CancellationError() }
            return try await self.send(text, context: context, attachments: files, to: id)
        }
        self.pickup = pickup
        await pickup.start()
        #endif
        Task { await self.wake() }
    }

    /// Looks for work: triage of pending events, queued tasks, due reminders. Returns at once
    /// when triage runs already (it runs once more after).
    public func wake() async {
        guard started else { return }
        await queue.wake()
        await pickup?.wake()
        await profileItems()
        await reminders.check()
        await wakeTriage()
    }

    /// mc: the university profile's "Register for exams" items (through the change log, once per
    /// window); their reminders follow from ReminderCenter.
    private func profileItems() async {
        do {
            try await ProfileItemWriter.apply(services: services, changeLog: changeLog, now: now())
        } catch {
            AppAgentModule.log.error("Profile items failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The app is about to quit (synchronous, in `willTerminate` BEFORE the `claude` processes
    /// are ended): a task or triage call that fails because its process ends writes nothing, so
    /// the task stays `running` (re-queued and resumed at the next launch) and the events stay
    /// `pending` (no attempt counted). `stop()` follows.
    public nonisolated func prepareForQuit() {
        quit.set()
    }

    /// The app quits: the queue keeps its running rows (re-queued at the next launch), triage
    /// and reminders stop; their processes end with the app.
    public func stop() async {
        started = false
        quit.set()
        observation?.cancel()
        observation = nil
        follower?.cancel()
        follower = nil
        reminderObservation?.cancel()
        reminderObservation = nil
        reminderFollower?.cancel()
        reminderFollower = nil
        pauseWake?.cancel()
        pauseWake = nil
        triageTask?.cancel()
        await pickup?.stop()
        await queue.stop()
        await reminders.stop()
    }

    /// Records a new fact from a producer outside AppAgent's packages and triages it soon.
    public func record(_ event: AgentEvent) async {
        do {
            try await AgentEventRepository(store: services.records).record(event)
        } catch {
            AppAgentModule.log.error("Recording an event failed: \(String(describing: error), privacy: .public)")
        }
        await wakeTriage()
    }

    /// Background work at once from now on (memory pressure: 1; nil: the default 2): the task
    /// queue and the Claude Code background process slots.
    public func setBackgroundLimit(_ limit: Int?) async {
        await queue.setLimit(limit)
        await client.setBackgroundSlotLimit(limit)
        await queue.wake()
    }

    private func wakeTriage() async {
        guard started else { return }
        if triageTask != nil {
            triageAgain = true
            return
        }
        triageTask = Task(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runTriage()
        }
    }

    private func runTriage() async {
        repeat {
            triageAgain = false
            let report = await triage.run()
            if report.applied > 0 || report.escalated > 0 {
                AppAgentModule.log.info("Triage: \(report.applied) applied, \(report.escalated) escalated, \(report.calls) calls")
            }
            if report.escalated > 0 { await queue.wake() }
            if report.waiting {
                if let until = await client.availability().pausedUntil { schedulePauseWake(at: until) }
                break
            }
        } while triageAgain && started
        triageTask = nil
    }

    private func schedulePauseWake(at date: Date) {
        guard pauseWake == nil else { return }
        let delay = max(1, date.timeIntervalSince(now()) + 5)
        pauseWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.pauseEnded()
        }
    }

    private func pauseEnded() async {
        pauseWake = nil
        await wake()
    }

    // MARK: - Blocks

    /// The text blocks of a conversation's user turns, in order (where the last `<catalog>` and
    /// `<context>` revisions are found).
    static func userTexts(_ turns: [AgentTurn]) -> [String] {
        turns.filter { $0.role == .user }.flatMap { turn -> [String] in
            guard let message = try? MessageParam(json: JSONValue.parse(turn.message)) else { return [] }
            return message.content.blocks.compactMap(\.textValue)
        }
    }

    /// mc: `<reminder fired="Tue 20 Oct, 22:00" item="…">title · body</reminder>` for each
    /// reminder delivered since the student's last message to the newest `app` conversation, when
    /// `conversation` is that one or a new one (nil); at most 5, oldest first.
    func reminderBlocks(for conversation: AgentConversation.ID?, history: [AgentTurn]) async throws -> [String] {
        let date = now()
        let kind = ConversationKind.app
        let newest = try await services.database.read { db in
            try AgentConversation.where { $0.kind.eq(kind) }.order { $0.createdAt.desc() }.fetchOne(db)
        }
        if let conversation, newest?.id != conversation { return [] }
        var turns = history
        if conversation == nil, let newest { turns = try await ConversationRepository(store: services.records).turns(newest.id) }
        // The student's own messages carry a turn context; tool results do not.
        let since = turns.last { $0.role == .user && $0.context != nil }?.createdAt ?? date.addingTimeInterval(-86_400)
        let shown = try await services.database.read { db in
            try AgentReminder.where { $0.deliveredAt.gt(Date?.some(since)) }.order(by: \.fireAt).fetchAll(db)
        }
        return shown.suffix(5).map { reminder in
            var head = "<reminder fired=\"\(AgentText.dayTime(reminder.deliveredAt ?? reminder.fireAt))\""
            if let item = reminder.trackedItemID { head += " item=\"\(item.uuidString.lowercased())\"" }
            return head + ">" + AgentXML.escape(reminder.title + (reminder.body.isEmpty ? "" : " · " + reminder.body)) + "</reminder>"
        }
    }

    /// Whether a finished task's result is untrusted text: it had mail, (md) documents or web pages
    /// to read (a fetched page can steer what a web task answers).
    static func carriesUntrustedResult(_ task: AgentTask) -> Bool {
        let untrusted: [AgentToolGroup] = [.mail, .documents, .web]
        return task.finishedAt != nil && task.tools.contains(where: untrusted.contains) && !(task.result ?? "").isEmpty
    }

    /// `<task_result task="…" title="…" state="succeeded">result</task_result>` (data).
    static func taskResult(_ task: AgentTask) -> String {
        let body = task.result ?? task.error ?? ""
        return "<task_result task=\"\(task.id.uuidString.lowercased())\" title=\"\(AgentXML.escape(task.title))\" state=\"\(task.state.rawValue)\">\n"
            + AgentXML.escape(body) + "\n</task_result>"
    }
}
