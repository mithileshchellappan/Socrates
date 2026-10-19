import Agent
import ClaudeKit
import Coach
import Foundation
import GRDB
import StudyCore
import StudyPass
import Synchronization

/// Set synchronously when the app quits (`AppAgent.prepareForQuit`, before the `claude`
/// processes are ended): a run that fails because its process was ended then writes nothing, so
/// a task stays `running` (re-queued at the next launch) and a triage batch stays `pending`.
final class QuitSignal: Sendable {
    private let flag = Mutex(false)

    var isSet: Bool { flag.withLock { $0 } }

    func set() { flag.withLock { $0 = true } }
}

/// The sub-agent task queue (docs/plan-agent.md §4 "Tasks"): FIFO (the student's and the panel's
/// before triage's: `AgentTaskRepository.claim`), at most `limit` running (2; 1 under memory
/// pressure), each a tool loop in its own `task` conversation at `.background` priority with the
/// tool groups it was given. It follows `agent_task` (a spawn or a cancel anywhere starts or stops
/// work), so the tools only write rows.
///
/// - A `study_pass` task runs in code: `StudyPassPipeline.rerun(lectureID:)`, no model.
/// - mc: a `question_draft` task runs in code: `QuestionDrafter.run(lectureID:)` (Haiku batches,
///   resumable by its `study_unit` rows); a `practice_exam` task holding an old exam
///   (`OldExamReader.Input`) runs in code: `OldExamReader.read(task:)`. Both need Claude Code (not
///   claimed without it); a usage pause or no Claude Code → `paused` (queued again later).
/// - Result ≤ 4,000 characters into `result` (the task's last answer); the panel shows it at once;
///   the parent's next user turn carries it as `<task_result>` (`AppAgent.send`).
/// - A usage limit → `paused` until the reset (it queues again then); cancel → its process is
///   ended, `cancelled`; a quit leaves `running` rows, re-queued at the next launch
///   (`requeueInterrupted`, failed after 3 interruptions), and the conversation resumes.
actor AgentTaskQueue {
    let services: StudyServices
    let client: ClaudeClient
    let runtime: AgentRuntime
    let studyPass: StudyPassPipeline?
    let coach: CoachEngine?
    /// A task's spec from its row (`AppAgentChat.taskSpec(_:task:)`): its conversation starts
    /// with it, before the row is linked to the conversation.
    let taskSpec: @Sendable (AgentTask) async throws -> ConversationSpec
    let quit: QuitSignal
    let now: @Sendable () -> Date

    /// Tasks running at once (`AgentTask.defaultParallel`; the app lowers it under memory pressure).
    private(set) var limit = AgentTask.defaultParallel
    /// Running tasks and their conversations (nil: a task run in code).
    private var running: [AgentTask.ID: (conversation: AgentConversation.ID?, work: Task<Void, Never>)] = [:]
    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?
    private var pauseWake: Task<Void, Never>?
    private var stopping = false
    /// When the queue started: tasks without a parent that finish from then on join the newest
    /// `app` conversation (`settleFinished`).
    private var startedAt = Date.distantFuture

    init(
        services: StudyServices, client: ClaudeClient, runtime: AgentRuntime, studyPass: StudyPassPipeline?, coach: CoachEngine?,
        taskSpec: @escaping @Sendable (AgentTask) async throws -> ConversationSpec, quit: QuitSignal, now: @escaping @Sendable () -> Date
    ) {
        self.services = services
        self.client = client
        self.runtime = runtime
        self.studyPass = studyPass
        self.coach = coach
        self.taskSpec = taskSpec
        self.quit = quit
        self.now = now
    }

    var tasks: AgentTaskRepository { AgentTaskRepository(store: services.records) }

    // MARK: - Entry points

    /// At launch: tasks a quit left running queue again; then follows `agent_task`.
    func start() async {
        guard observation == nil else { return }
        stopping = false
        startedAt = now()
        do {
            try await tasks.requeueInterrupted()
        } catch {
            AppAgentModule.log.error("Re-queueing tasks failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        observation = DatabaseRegionObservation(tracking: SQLRequest<Row>(sql: "SELECT id, state FROM agent_task"))
            .start(
                in: services.database,
                onError: { error in AppAgentModule.log.error("Task observation failed: \(String(describing: error), privacy: .public)") },
                onChange: { _ in continuation.yield() }
            )
        follower = Task { [weak self] in
            for await _ in stream {
                await self?.wake()
            }
        }
        continuation.yield()
    }

    /// Starts queued tasks while slots are free, stops running ones whose row was cancelled.
    func wake() async {
        guard !stopping, !quit.isSet else { return }
        await stopCancelled()
        await settleFinished()
        let free = limit - running.count
        guard free > 0 else { return }
        let availability = await client.availability()
        if let until = availability.pausedUntil {
            schedulePauseWake(at: until)
            return
        }
        // Without Claude Code, model tasks are not claimed at all (they stay queued, no write, so
        // the observation does not wake the queue again); a study pass task needs no model.
        // `AppModel.refreshClaudeAvailability` wakes the agent when Claude Code turns ready.
        let kinds: [AgentTaskKind]? = availability.isReady ? nil : [.studyPass]
        let claimed: [AgentTask]
        do {
            claimed = try await tasks.claim(slots: limit, now: now(), kinds: kinds).filter { running[$0.id] == nil }
        } catch {
            AppAgentModule.log.error("Claiming tasks failed: \(String(describing: error), privacy: .public)")
            return
        }
        for task in claimed { run(task) }
    }

    /// Fewer (or the default number of) tasks at once from now on; running ones are not stopped.
    func setLimit(_ value: Int?) {
        limit = max(1, value ?? AgentTask.defaultParallel)
    }

    /// Cancels a task: a running one's process is ended first.
    func cancel(_ id: AgentTask.ID) async {
        if let entry = running[id], let conversation = entry.conversation {
            try? await tasks.cancel(id)
            await runtime.stop(conversation)
        } else {
            try? await tasks.cancel(id)
            // A task run in code stops between its calls.
            running[id]?.work.cancel()
        }
    }

    /// The app quits: running tasks stay `running` (re-queued at the next launch); their
    /// processes end with the app.
    func stop() async {
        stopping = true
        observation?.cancel()
        observation = nil
        follower?.cancel()
        follower = nil
        pauseWake?.cancel()
        pauseWake = nil
        for (_, entry) in running {
            if let conversation = entry.conversation {
                await runtime.stop(conversation)
            } else {
                // Drafting and old exams stop between calls; their rows stay `running` (re-queued).
                entry.work.cancel()
            }
        }
    }

    // MARK: - Running

    /// Tasks that run in code, not as a conversation: a study pass, (mc) question drafting, an
    /// old exam to read.
    static func runsInCode(_ task: AgentTask) -> Bool {
        task.kind == .studyPass || task.kind == .questionDraft || (task.kind == .practiceExam && OldExamReader.input(of: task) != nil)
    }

    private func run(_ task: AgentTask) {
        let inCode = Self.runsInCode(task)
        let work = Task(priority: .background) { [weak self] in
            guard let self else { return }
            if task.kind == .studyPass {
                await self.runStudyPass(task)
            } else if task.kind == .questionDraft {
                await self.runDrafting(task)
            } else if inCode {
                await self.runOldExam(task)
            } else {
                await self.runConversation(task)
            }
            await self.finished(task.id)
        }
        running[task.id] = (inCode ? nil : task.conversationID ?? UUID(), work)
    }

    private func finished(_ id: AgentTask.ID) async {
        running[id] = nil
        await wake()
    }

    private func runStudyPass(_ task: AgentTask) async {
        guard let lectureID = task.lectureID, let studyPass else {
            try? await tasks.finish(task.id, .failed, error: "The study pass does not run on this device.")
            return
        }
        do {
            let units = try await studyPass.rerun(lectureID: lectureID)
            try await tasks.finish(task.id, .succeeded, result: "The study pass runs again (\(units) parts); its notes update as they are done.")
        } catch {
            try? await tasks.finish(task.id, .failed, error: "The study pass could not be started.")
        }
    }

    // MARK: The study coach's tasks (mc)

    private func runDrafting(_ task: AgentTask) async {
        guard let lectureID = task.lectureID, let drafter = coach?.drafter else {
            try? await tasks.finish(task.id, .failed, error: "The study coach does not run on this device.")
            return
        }
        switch await drafter.run(lectureID: lectureID) {
        case .done(let questions, let readings):
            guard await stillOpen(task) else { return }
            let text = readings > 0 ? "\(questions) questions and \(readings) readings drafted." : "\(questions) questions drafted."
            try? await tasks.finish(task.id, .succeeded, result: text)
        case .waiting(let until):
            await wait(task, until: until)
        case .failed(let message):
            guard await stillOpen(task) else { return }
            try? await tasks.finish(task.id, .failed, error: message)
        }
    }

    private func runOldExam(_ task: AgentTask) async {
        guard let oldExams = coach?.oldExams else {
            try? await tasks.finish(task.id, .failed, error: "The study coach does not run on this device.")
            return
        }
        switch await oldExams.read(task: task) {
        case .done(let questions, let title):
            guard await stillOpen(task) else { return }
            try? await tasks.finish(task.id, .succeeded, result: "\(questions) questions of \(title) are ready for practice exams.")
        case .waiting(let until):
            await wait(task, until: until)
        case .failed(let message):
            guard await stillOpen(task) else { return }
            try? await tasks.finish(task.id, .failed, error: message)
        }
    }

    /// False when the app quits: the row stays `running`, re-queued at the next launch, so nothing
    /// more is written. (A cancel meanwhile is kept by the repository: `finish` and `pause` only
    /// change an open row.)
    private func stillOpen(_ task: AgentTask) async -> Bool {
        !(stopping || quit.isSet)
    }

    /// A task that waits for Claude Code (a usage pause, signed out, the CLI or the network in
    /// trouble): paused until the reset (or a quarter of an hour), then queued again.
    private func wait(_ task: AgentTask, until: Date?) async {
        guard await stillOpen(task) else { return }
        let date = until ?? now().addingTimeInterval(15 * 60)
        try? await tasks.pause(task.id, until: date)
        schedulePauseWake(at: date)
    }

    /// Whether a task that stopped should wait for the service instead of failing: the error (or
    /// the run's) was service trouble, or Claude Code is not ready or paused now. The pause's end
    /// when there is one.
    private func waitsForService(error: (any Error)?, conversation: AgentConversation.ID?) async -> (waits: Bool, until: Date?) {
        let availability = await client.availability()
        if let until = availability.pausedUntil { return (true, until) }
        if !availability.isReady { return (true, nil) }
        if let error = error as? ClaudeError, error.isServiceTrouble { return (true, nil) }
        if let conversation, await runtime.endedWithServiceTrouble(conversation) { return (true, nil) }
        return (false, nil)
    }

    private func runConversation(_ task: AgentTask) async {
        guard let conversation = running[task.id]?.conversation else { return }
        do {
            if task.conversationID == nil {
                // The conversation row must exist before the task points at it (agent_task's
                // conversation_id is a foreign key), so its spec comes from the row as claimed:
                // start writes the conversation, then the link follows (later sends find the
                // spec by the link).
                let spec = try await taskSpec(task)
                _ = try await runtime.start(
                    .task, text: Self.prompt(task), courseID: task.courseID, lectureID: task.lectureID, id: conversation, title: task.title,
                    spec: spec
                )
                try await tasks.setConversation(task.id, conversation)
            } else {
                // Interrupted by a quit or paused: the conversation goes on where it stopped.
                try await runtime.send("Continue the task where you stopped, then give its result.", to: conversation)
            }
        } catch {
            if stopping || quit.isSet { return }
            AppAgentModule.log.error(
                "A task could not start: \(ReadableError.kind(of: error), privacy: .public): \(String(describing: error), privacy: .private)"
            )
            let service = await waitsForService(error: error, conversation: nil)
            if service.waits {
                await wait(task, until: service.until)
            } else {
                try? await tasks.finish(task.id, .failed, error: Self.readable(error))
            }
            return
        }
        // A cancel while start or send was in flight found no run to stop yet.
        if await isCancelled(task.id) { await runtime.stop(conversation) }
        let ended = await runtime.outcome(conversation)
        // The app quits (its process was ended): the row stays `running` for `requeueInterrupted`.
        if stopping || quit.isSet { return }
        if ended?.state == .finished {
            let result = (try? await lastAnswer(conversation)) ?? ""
            try? await tasks.finish(task.id, .succeeded, result: result.isEmpty ? "Done." : result)
            return
        }
        if await isCancelled(task.id) { return }
        let service = await waitsForService(error: nil, conversation: conversation)
        if service.waits {
            await wait(task, until: service.until)
            return
        }
        try? await tasks.finish(task.id, .failed, error: ended?.error ?? "The task stopped.")
    }

    private func isCancelled(_ id: AgentTask.ID) async -> Bool {
        (try? await services.records.fetch(AgentTask.self, id: id))?.state == .cancelled
    }

    // MARK: - Finished tasks

    /// Tasks nobody would hear of otherwise. One without a parent conversation (a triage
    /// escalation; not the coach's drafting or a study pass) that finished since the queue
    /// started joins the newest `app` conversation: its
    /// thread shows it and the next message there carries it. An escalation that failed or was
    /// cancelled gives its fact back to triage (`pending`, one more attempt; `failed` after
    /// `AgentTask.maximumAttempts`), so the fact is not lost.
    private func settleFinished() async {
        let since = startedAt
        let stamp = services.records.currentDate
        do {
            try await services.database.write { db in
                let app = ConversationKind.app
                let newest = try AgentConversation.where { $0.kind.eq(app) }.order { $0.createdAt.desc() }.fetchOne(db)
                if let newest {
                    let parent = AgentConversation.ID?.some(newest.id)
                    // The coach's own bookkeeping (drafting, a study pass) is no news for the thread.
                    let quiet: [AgentTaskKind] = [.questionDraft, .studyPass]
                    try AgentTask
                        .where {
                            $0.parentConversationID.is(nil) && $0.reportedAt.is(nil) && $0.finishedAt.gte(Date?.some(since))
                                && !$0.kind.in(quiet)
                        }
                        .update {
                            $0.parentConversationID = parent
                            $0.updatedAt = stamp
                        }
                        .execute(db)
                }
                let ended = try Row.fetchAll(db, sql: """
                    SELECT e.id AS event, e.attempts AS attempts FROM agent_task t
                    JOIN agent_event e ON e.id = t.event_id AND e.task_id = t.id
                    WHERE t.kind = ? AND t.state IN (?, ?) AND e.state = ?
                    """, arguments: [
                        AgentTaskKind.escalation.rawValue, AgentTaskState.failed.rawValue, AgentTaskState.cancelled.rawValue,
                        AgentEventState.escalated.rawValue,
                    ])
                for row in ended {
                    guard let eventID = UUID(uuidString: row["event"] as String) else { continue }
                    let attempts = (row["attempts"] as Int) + 1
                    let state: AgentEventState = attempts >= AgentTask.maximumAttempts ? .failed : .pending
                    let error: String? = state == .failed ? "The careful decision did not finish." : nil
                    try AgentEvent.find(eventID).update {
                        $0.state = state
                        $0.attempts = attempts
                        $0.error = error
                        $0.updatedAt = stamp
                    }
                    .execute(db)
                }
            }
        } catch {
            AppAgentModule.log.error("Settling finished tasks failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
    }

    /// The task's first message: its goal, then what it was handed (data).
    static func prompt(_ task: AgentTask) -> String {
        var text = "<task kind=\"\(task.kind.rawValue)\" title=\"\(AgentXML.escape(task.title))\">\n\(AgentXML.escape(task.goal))\n</task>"
        if !task.inputSummary.isEmpty {
            text += "\n<input>\n\(AgentXML.escape(task.inputSummary))\n</input>"
        }
        return text
    }

    /// The text of the conversation's last answer, at most `AgentTask.resultLimit` characters.
    func lastAnswer(_ conversation: AgentConversation.ID) async throws -> String {
        let turns = try await ConversationRepository(store: services.records).turns(conversation)
        for turn in turns.reversed() where turn.role == .assistant {
            let message = try MessageParam(json: JSONValue.parse(turn.message))
            let text = message.content.blocks.compactMap(\.textValue).joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return String(text.prefix(AgentTask.resultLimit)) }
        }
        return ""
    }

    private func stopCancelled() async {
        guard !running.isEmpty else { return }
        let ids = Array(running.keys)
        let cancelled = (try? await services.database.read { db in
            try AgentTask.where { $0.id.in(ids) && $0.state.eq(AgentTaskState.cancelled) }.select(\.id).fetchAll(db)
        }) ?? []
        for id in cancelled {
            if let conversation = running[id]?.conversation { await runtime.stop(conversation) }
        }
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

    /// What `agent_task.error` says (the panel shows it, the parent's next turn carries it): one
    /// readable sentence, never SQLite, CLI or Swift text (that goes to the log).
    static func readable(_ error: any Error) -> String {
        if error is ToolSetError { return "The task's tools cannot be used together." }
        return ReadableError.sentence(for: error)
    }
}
