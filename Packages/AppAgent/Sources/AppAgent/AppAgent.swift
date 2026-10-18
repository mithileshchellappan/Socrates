import Agent
import ClaudeKit
import Courses
import Deadlines
import Foundation
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
///     let specs = AppAgent.specs(services: s, search: engine, drafter: mailPipeline.drafter, memory: memory)
///     let runtime = AgentRuntime(services: s, client: client, memory: memory,
///                                additionalSpecs: [/* mail chat, tutor */].merging(specs.additional) { $1 },
///                                conversationSpecs: specs.perConversation)
///     let agent = AppAgent(services: s, client: client, runtime: runtime, memory: memory,
///                          schedule: CourseSchedule(services: s), studyPass: studyPassPipeline)
///     await agent.start()           // startBackgroundWork, after the pipelines
///     await agent.wake()            // new mail, finished transcriptions, study pass units, imports,
///                                   // calendar changes, Claude Code turning available
///     await agent.stop()            // NSApplication.willTerminate
///     await agent.setBackgroundLimit(memoryLow ? 1 : nil)
public actor AppAgent {
    let services: StudyServices
    let client: ClaudeClient
    let runtime: AgentRuntime
    let memory: DeadlineMemory
    let schedule: CourseSchedule
    let studyPass: StudyPassPipeline?
    let now: @Sendable () -> Date

    /// The activity log and write path of every automatic change.
    public nonisolated let changeLog: ChangeLog
    let queue: AgentTaskQueue
    let triage: FactTriage
    let reminders: ReminderCenter

    private var triageTask: Task<Void, Never>?
    private var triageAgain = false
    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?
    private var pauseWake: Task<Void, Never>?
    private var started = false

    public init(
        services: StudyServices,
        client: ClaudeClient,
        runtime: AgentRuntime,
        memory: DeadlineMemory,
        schedule: CourseSchedule,
        studyPass: StudyPassPipeline?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.runtime = runtime
        self.memory = memory
        self.schedule = schedule
        self.studyPass = studyPass
        self.now = now
        let changeLog = ChangeLog(services: services, memory: memory, now: now)
        self.changeLog = changeLog
        queue = AgentTaskQueue(services: services, client: client, runtime: runtime, studyPass: studyPass, now: now)
        triage = FactTriage(services: services, client: client, changeLog: changeLog, now: now)
        reminders = ReminderCenter(services: services, changeLog: changeLog, now: now)
    }

    // MARK: - Specs

    /// The conversation specs for the agent runtime: `.app` (an `AgentRuntime.SpecProvider`) and
    /// `.task` (per conversation, from its `agent_task` row).
    public struct Specs: Sendable {
        public var additional: [ConversationKind: AgentRuntime.SpecProvider]
        public var perConversation: [ConversationKind: AgentRuntime.ConversationSpecProvider]
    }

    /// `search`: the app's engine (with its semantic index; its planner is not used). `drafter`:
    /// the mail pipeline's `ReplyDrafter` (draft_reply; nil: no drafts). `memory`: the app's
    /// deadline memory (its `onChange` syncs the calendar after the agent's writes).
    public static func specs(
        services: StudyServices, search: SearchEngine, drafter: ReplyDrafter?, memory: DeadlineMemory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> Specs {
        let deps = AppAgentChat.Services(services: services, search: search, drafter: drafter, memory: memory, now: now)
        return Specs(
            additional: [.app: { try AppAgentChat.spec(deps) }],
            perConversation: [.task: { conversationID in try await AppAgentChat.taskSpec(deps, conversationID: conversationID) }]
        )
    }

    // MARK: - The panel

    /// Sends the student's message (with what they see and the files they attached) to
    /// `conversation` (nil: a new `app` conversation); returns its id at once while the agent
    /// answers in the background. The user turn carries, before the words: the attachments as
    /// image / document blocks, the `<catalog>` and `<context>` blocks when they changed since
    /// the conversation last carried them, and the results of its finished tasks no turn has
    /// carried yet (`<task_result>`, then `reported_at`). `agent_turn.context` keeps the context,
    /// the thread's context line (when the screen changed) and the attachments.
    public func send(
        _ text: String, context: AgentContext, attachments: [AgentAttachment], to conversation: AgentConversation.ID?
    ) async throws -> AgentConversation.ID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { throw AgentRuntime.RuntimeError.emptyText }
        var history: [AgentTurn] = []
        if let conversation { history = try await ConversationRepository(store: services.records).turns(conversation) }
        let texts = Self.userTexts(history)
        var blocks = try AttachmentBlocks.blocks(attachments, blobs: services.blobs)
        let catalog = try await AgentCatalog.build(services: services, now: now())
        if AgentCatalog.lastRevision(in: texts) != catalog.revision { blocks.append(.text(catalog.text)) }
        let block = try await AgentContextBlock.build(context, services: services)
        if AgentContextBlock.lastRevision(in: texts) != block.revision { blocks.append(.text(block.text)) }
        var reported: [AgentTask.ID] = []
        if let conversation {
            for task in try await AgentTaskRepository(store: services.records).unreported(parent: conversation) {
                blocks.append(.text(Self.taskResult(task)))
                reported.append(task.id)
            }
        }
        // The thread's faint line: only when the screen changed since the last message.
        let previous = history.last { $0.role == .user && $0.context?.context != nil }?.context?.context
        let changed = previous?.settled != context.settled
        let turnContext = AgentTurnContext(
            context: context, label: changed ? block.label : nil, glyph: changed ? block.glyph : nil, attachments: attachments
        )
        let id: AgentConversation.ID
        if let conversation {
            try await runtime.send(trimmed, context: blocks, turnContext: turnContext, to: conversation)
            id = conversation
        } else {
            let title = trimmed.isEmpty ? (attachments.first?.fileName ?? "Files") : trimmed
            id = try await runtime.start(
                .app, text: trimmed, context: blocks, courseID: context.courseID, turnContext: turnContext, title: title
            )
        }
        try await AgentTaskRepository(store: services.records).markReported(reported)
        return id
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
        Task { await self.wake() }
    }

    /// Looks for work: triage of pending events, queued tasks, due reminders. Returns at once
    /// when triage runs already (it runs once more after).
    public func wake() async {
        guard started else { return }
        await queue.wake()
        await reminders.check()
        await wakeTriage()
    }

    /// The app quits: the queue keeps its running rows (re-queued at the next launch), triage
    /// and reminders stop; their processes end with the app.
    public func stop() async {
        started = false
        observation?.cancel()
        observation = nil
        follower?.cancel()
        follower = nil
        pauseWake?.cancel()
        pauseWake = nil
        triageTask?.cancel()
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

    /// `<task_result task="…" title="…" state="succeeded">result</task_result>` (data).
    static func taskResult(_ task: AgentTask) -> String {
        let body = task.result ?? task.error ?? ""
        return "<task_result task=\"\(task.id.uuidString.lowercased())\" title=\"\(AgentXML.escape(task.title))\" state=\"\(task.state.rawValue)\">\n"
            + AgentXML.escape(body) + "\n</task_result>"
    }
}
