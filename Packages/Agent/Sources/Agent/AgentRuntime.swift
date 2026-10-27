import ClaudeKit
import Deadlines
import Foundation
import StudyCore

/// Claude conversations with a fixed tool set per kind (docs/plan-m3.md §3.2).
///
/// - `start` creates the `agent_conversation` row (`running`), appends the student's turn and
///   returns at once; ClaudeKit's `ToolLoop` streams in a task.
/// - Every appended turn is stored verbatim with `ConversationRepository.append` (the Messages API
///   JSON with sorted keys: thinking blocks and signatures included); an assistant turn links the
///   `api_call` row the ledger wrote for its response (by request id).
/// - `send` rebuilds the history from the stored turns byte for byte and appends; nothing is ever
///   edited. The model, effort, system prompt and tools of a conversation never change.
/// - A file a student's turn sends (an image, a PDF, a text file, a document's text) is stored by
///   reference to the bytes sent (`BlockSource.blob`, 2026-10-27); each request carries its base64
///   (or its text) again, the same bytes. A file gone from the BlobStore fails the run with "The
///   file is no longer there."
/// - The end: `finished`; an error, a refusal, truncation or the call limit: `failed` with a
///   readable error. `recoverInterrupted()` fails what a quit left `running` and adds the
///   composer's parse of what such a `deadlines` conversation was told when it wrote nothing.
/// - Requests always state `effort`, never force `tool_choice`, never disable thinking.
public actor AgentRuntime {
    /// Builds the one spec of a conversation kind defined outside this package (M3.5: the mail
    /// chat, assembled in MailIntelligence from its mail tools and the deadline tools).
    public typealias SpecProvider = @Sendable () throws -> ConversationSpec
    /// ma: builds the spec of ONE conversation from its rows (a sub-agent task's `task`
    /// conversation: the tool groups, model and effort of its `agent_task` row, found by
    /// `agent_task.conversation_id`).
    public typealias ConversationSpecProvider = @Sendable (AgentConversation.ID) async throws -> ConversationSpec

    let services: StudyServices
    let client: ClaudeClient
    let memory: DeadlineMemory
    let now: @Sendable () -> Date
    let additionalSpecs: [ConversationKind: SpecProvider]
    let conversationSpecs: [ConversationKind: ConversationSpecProvider]
    private var tasks: [AgentConversation.ID: Task<Void, Never>] = [:]
    /// Conversations whose next message `send` is storing (between its busy check and its run's
    /// launch; the actor is reentrant at every await): a second message meanwhile is busy too.
    private var sending: Set<AgentConversation.ID> = []
    /// Conversations whose last run ended on service trouble (`endedWithServiceTrouble`).
    private var serviceTrouble: Set<AgentConversation.ID> = []
    /// The answer being written, per conversation (M3.5: the chat streams it into place).
    private let live = LiveReplies()

    public init(
        services: StudyServices,
        client: ClaudeClient,
        memory: DeadlineMemory? = nil,
        additionalSpecs: [ConversationKind: SpecProvider] = [:],
        conversationSpecs: [ConversationKind: ConversationSpecProvider] = [:],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.memory = memory ?? DeadlineMemory(services: services, now: now)
        self.additionalSpecs = additionalSpecs
        self.conversationSpecs = conversationSpecs
        self.now = now
    }

    /// Whether the agent can run now (M3.5: Claude Code installed and signed in). The chat's entry
    /// point and the composer's agent path depend on it.
    public func isAvailable() async -> Bool {
        await client.isAvailable()
    }

    var conversations: ConversationRepository { ConversationRepository(store: services.records) }

    /// Why a message could not be handed to the agent.
    public enum RuntimeError: Error, Hashable, CustomStringConvertible {
        case unknownConversation
        case busy
        case emptyText
        case unknownKind(String)
        /// Try again on a conversation whose last turn is a finished answer.
        case nothingToRetry

        public var description: String {
            switch self {
            case .unknownKind(let kind): "no tool set for conversations of kind \(kind)"
            case .unknownConversation: "no such conversation"
            case .busy: "the agent is still working on this conversation"
            case .emptyText: "nothing to send"
            case .nothingToRetry: "the last message was answered"
            }
        }
    }

    /// The one spec of `kind`. M5: `mail_chat` and `tutor` get the memory tools (remember,
    /// update_memory, forget) after their own and the memory rules after their system prompt.
    func spec(for kind: ConversationKind, conversationID: AgentConversation.ID) async throws -> ConversationSpec {
        var spec: ConversationSpec
        switch kind {
        case .deadlines: spec = try DeadlineTools.spec(services: services, memory: memory)
        default:
            if let provider = conversationSpecs[kind] {
                spec = try await provider(conversationID)
            } else if let provider = additionalSpecs[kind] {
                spec = try provider()
            } else {
                throw RuntimeError.unknownKind(kind.rawValue)
            }
        }
        return try withMemory(spec, kind: kind)
    }

    /// M5: `base` with the memory tools after its own and the memory rules after its system
    /// prompt, for the kinds that have the memory.
    func withMemory(_ base: ConversationSpec, kind: ConversationKind) throws -> ConversationSpec {
        guard MemoryTools.kinds.contains(kind) else { return base }
        var spec = base
        // ma: the app agent's memory writes are automatic changes: each logs an `agent_change`
        // row in its transaction ("Remembered", Undo).
        spec.tools = try spec.tools.adding(MemoryTools(services: services, logsChanges: kind == .app).all)
        let system = spec.system
        spec.system = { startedAt, courses in system(startedAt, courses) + "\n\n" + MemoryTools.rules }
        return spec
    }

    /// The `<memory>` block for the next user turn of a conversation of `kind` with `history`:
    /// on the first turn, and whenever the active memories changed since the block the history
    /// last carried; nothing for kinds without the memory.
    func memoryBlock(for kind: ConversationKind, history: [MessageParam]) async throws -> [ContentBlock] {
        guard MemoryTools.kinds.contains(kind) else { return [] }
        let block = try await MemoryBlock.current(services: services)
        guard MemoryBlock.lastRevision(in: history) != block.revision else { return [] }
        return [.text(TextBlock(text: block.text))]
    }

    // MARK: - Entry points

    /// Starts a conversation of `kind` with the student's `text`; returns at once while the agent
    /// works in the background. `context` blocks go before the student's words in the same user
    /// turn (M3.5: the open mail as a `<mail>` envelope, data never instructions), then the clock
    /// (`AgentClock`, in every user turn the runtime writes); the tools' `ToolContext.studentText`
    /// is the student's words only. M5: `lectureID` is a tutor
    /// conversation's lecture (its subject, with the lecture's `courseID`); a `mail_chat` or
    /// `tutor` conversation's first turn starts with the `<memory>` block.
    ///
    /// ma: `turnContext` is stored with the user turn (`agent_turn.context`: an `app` turn's screen,
    /// context line and attachments); `id` gives the new conversation a chosen id (a sub-agent
    /// task's, linked to its `agent_task` row once the conversation row exists); `title` names it
    /// (else the student's first words). The text may be empty when `context` carries blocks
    /// (files only). `spec`, when given, is used instead of the kind's provider: a `task`
    /// conversation's spec comes from its `agent_task` row, which cannot be found by
    /// `conversation_id` before the conversation exists (later `send`s find it that way).
    /// `readUntrustedContent` (md): the context blocks carry untrusted text (a document's), so a
    /// web task this run spawns gets no input summary. `writtenAt`: when the words were written,
    /// when that was earlier than now (an iPhone question, a queued task's goal): the clock says
    /// so, and the tools read relative days in them against it.
    public func start(
        _ kind: ConversationKind, text: String, context: [ContentBlock] = [], courseID: Course.ID? = nil, lectureID: Lecture.ID? = nil,
        turnContext: AgentTurnContext? = nil, id: AgentConversation.ID? = nil, title: String? = nil, spec given: ConversationSpec? = nil,
        readUntrustedContent: Bool = false, writtenAt: Date? = nil
    ) async throws -> AgentConversation.ID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !context.isEmpty else { throw RuntimeError.emptyText }
        let conversationID = id ?? UUID()
        let spec: ConversationSpec
        if let given {
            spec = try withMemory(given, kind: kind)
        } else {
            spec = try await self.spec(for: kind, conversationID: conversationID)
        }
        let memory = try await memoryBlock(for: kind, history: [])
        let startedAt = now()
        let name = (title ?? trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        let conversation = try await conversations.start(AgentConversation(
            id: conversationID, kind: kind, courseID: courseID, lectureID: lectureID, title: String(name.prefix(60)),
            model: spec.model.rawValue, state: .running, createdAt: startedAt, updatedAt: startedAt
        ))
        // The clock goes last before the words (the system prompt keeps the start time only).
        let written = min(writtenAt ?? startedAt, startedAt)
        let turn = Self.userTurn(memory + context + [AgentClock.block(startedAt, writtenAt: written)], text: trimmed)
        try await conversations.append(to: conversation.id, role: .user, message: try Self.encode(turn), context: turnContext)
        launch(
            conversation, spec: spec, history: [turn], studentText: trimmed, writtenAt: written, turnContext: turnContext,
            readUntrusted: readUntrustedContent
        )
        return conversation.id
    }

    /// A user turn: the blocks, then the student's words (none when empty).
    static func userTurn(_ blocks: [ContentBlock], text: String) -> MessageParam {
        if blocks.isEmpty { return .user(text) }
        return .user(text.isEmpty ? blocks : blocks + [.text(TextBlock(text: text))])
    }

    /// Appends the student's next message (after its `context` blocks) to a conversation that is
    /// not running and runs it again.
    ///
    /// ma: the run's trace starts as "read untrusted content" when the conversation has read any
    /// before (a turn whose context carried an open mail, a call of a tool that reads untrusted
    /// content) or the caller says so (`readUntrustedContent`: a mail task's result it carries):
    /// that text stays in the history, so a web task it spawns never gets it. `writtenAt`: as
    /// `start`'s.
    public func send(
        _ text: String, context: [ContentBlock] = [], turnContext: AgentTurnContext? = nil, readUntrustedContent: Bool = false,
        writtenAt: Date? = nil, to id: AgentConversation.ID
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !context.isEmpty else { throw RuntimeError.emptyText }
        guard tasks[id] == nil, !sending.contains(id) else { throw RuntimeError.busy }
        sending.insert(id)
        defer { sending.remove(id) }
        guard let conversation = try await services.records.fetch(AgentConversation.self, id: id) else {
            throw RuntimeError.unknownConversation
        }
        let spec = try await spec(for: conversation.kind, conversationID: id)
        let stored = try await conversations.turns(id)
        var history = try Self.history(stored)
        let readUntrusted = readUntrustedContent || Self.readUntrustedContent(stored, history: history, tools: spec.tools)
        // A run that stopped between a tool call and its result: answer the calls still open
        // first (the API needs a result for each), in the same new user turn.
        var blocks: [ContentBlock] = []
        if let index = history.lastIndex(where: { $0.role == .assistant }) {
            var answered: Set<String> = []
            for case .toolResult(let result) in history[(index + 1)...].flatMap(\.content.blocks) {
                answered.insert(result.toolUseID)
            }
            blocks = history[index].content.blocks.compactMap(\.toolUse).filter { !answered.contains($0.id) }.map { call in
                .toolResult(ToolResultBlock(toolUseID: call.id, content: .text("interrupted"), isError: true))
            }
        }
        // M5: the memory when it changed since the block this conversation last carried.
        blocks += try await memoryBlock(for: conversation.kind, history: history)
        blocks += context
        let sentAt = now()
        let written = min(writtenAt ?? sentAt, sentAt)
        blocks.append(AgentClock.block(sentAt, writtenAt: written))
        let turn = Self.userTurn(blocks, text: trimmed)
        try await conversations.append(to: id, role: .user, message: try Self.encode(turn), context: turnContext)
        history.append(turn)
        try await conversations.setState(id, .running)
        launch(
            conversation, spec: spec, history: history, studentText: trimmed, writtenAt: written, turnContext: turnContext,
            readUntrusted: readUntrusted
        )
    }

    /// ma: whether untrusted content reached the conversation in an earlier turn: a user turn
    /// whose context carried an open mail, or an assistant turn that called a tool reading
    /// untrusted content (mail).
    static func readUntrustedContent(_ stored: [AgentTurn], history: [MessageParam], tools: ToolSet) -> Bool {
        if stored.contains(where: { $0.role == .user && $0.context?.context?.mailMessageID != nil }) { return true }
        let readers = Set(tools.tools.filter(\.readsUntrustedContent).map(\.name))
        guard !readers.isEmpty else { return false }
        return history.contains { turn in
            turn.role == .assistant && turn.content.blocks.contains { block in block.toolUse.map { readers.contains($0.name) } ?? false }
        }
    }

    /// ma: answers a conversation's last message again after its run failed (the panel's Try
    /// again). Calls the failed run left open get "interrupted" results first, then the clock
    /// (always: a Try again after a usage pause comes later). When nothing after the last answer
    /// turn is text, an image or a document (a run that failed after a tool call, an answer that
    /// stopped early), the same user turn carries a `<retry>` block that restates the student's
    /// last words and when they were written: Claude Code takes only those as a prompt, and the
    /// thread never shows the block or the clock. The tools read relative days in the words
    /// against when they were written (their turn's time), not the time of the Try again. A
    /// finished conversation has nothing to retry.
    ///
    /// `readUntrustedContent`: as `send`'s (the caller's own knowledge of untrusted text in the
    /// history: files sent as text, task results), OR'd with what the stored turns show.
    public func retry(_ id: AgentConversation.ID, readUntrustedContent: Bool = false) async throws {
        guard tasks[id] == nil, !sending.contains(id) else { throw RuntimeError.busy }
        sending.insert(id)
        defer { sending.remove(id) }
        guard let conversation = try await services.records.fetch(AgentConversation.self, id: id) else {
            throw RuntimeError.unknownConversation
        }
        guard conversation.state != .finished else { throw RuntimeError.nothingToRetry }
        let spec = try await spec(for: conversation.kind, conversationID: id)
        let stored = try await conversations.turns(id)
        var history = try Self.history(stored)
        guard !history.isEmpty else { throw RuntimeError.nothingToRetry }
        let readUntrusted = readUntrustedContent || Self.readUntrustedContent(stored, history: history, tools: spec.tools)
        let message = try Self.lastStudentMessage(stored)
        var blocks: [ContentBlock] = []
        if let last = history.last, last.role == .assistant {
            blocks = last.content.blocks.compactMap(\.toolUse).map { call in
                .toolResult(ToolResultBlock(toolUseID: call.id, content: .text("interrupted"), isError: true))
            }
        }
        // Always the time now: a Try again after a usage pause may come hours later.
        let prompted = Self.hasPrompt(afterLastAnswer: history)
        let retriedAt = now()
        let written = min(message.writtenAt ?? retriedAt, retriedAt)
        blocks.append(AgentClock.block(retriedAt))
        if !prompted {
            blocks.append(.text(TextBlock(text: Self.retryBlock(words: message.text, writtenAt: written))))
        }
        let turn = MessageParam.user(blocks)
        try await conversations.append(to: id, role: .user, message: try Self.encode(turn), context: nil)
        history.append(turn)
        try await conversations.setState(id, .running)
        launch(
            conversation, spec: spec, history: history, studentText: message.text, writtenAt: written, turnContext: message.context,
            readUntrusted: readUntrusted
        )
    }

    /// The tag of Try again's block (`retryBlock`).
    static let retryTag = "<retry>"

    /// Try again's block when the turns since the last answer have nothing Claude Code can take as
    /// a prompt: the instruction to answer the student's last message again, with its words and
    /// when they were written.
    static func retryBlock(words: String, writtenAt: Date) -> String {
        var lines = [retryTag, "The last answer did not finish. Answer the student's last message again."]
        if !words.isEmpty { lines.append("The student's last message (written \(AgentClock.text(writtenAt))): \(words)") }
        lines.append("</retry>")
        return lines.joined(separator: "\n")
    }

    /// Some user turn after the last assistant turn has text, an image or a document (tool results
    /// alone are not a prompt).
    static func hasPrompt(afterLastAnswer history: [MessageParam]) -> Bool {
        let start = history.lastIndex { $0.role == .assistant }.map { $0 + 1 } ?? history.startIndex
        return history[start...].filter { $0.role == .user }.flatMap(\.content.blocks).contains { block in
            switch block {
            case .text, .image, .document: true
            default: false
            }
        }
    }

    /// The student's words in the conversation's last message (its last text block, after the
    /// context blocks and the clock; empty for files alone), the context stored with it and when
    /// it was stored. Try again's own turns (a clock, a `<retry>` block, results of interrupted
    /// calls) are not messages.
    static func lastStudentMessage(_ stored: [AgentTurn]) throws -> (text: String, context: AgentTurnContext?, writtenAt: Date?) {
        for turn in stored.reversed() where turn.role == .user {
            let message = try MessageParam(json: JSONValue.parse(turn.message))
            let texts = message.content.blocks.compactMap(\.textValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.hasPrefix(retryTag) && !AgentClock.isClock($0) }
            // A turn of tool results only is not a message.
            guard let words = texts.last else { continue }
            return (words.hasPrefix("<") ? "" : words, turn.context, turn.createdAt)
        }
        return ("", nil, nil)
    }

    /// Stops a running conversation (it ends `failed`).
    public func stop(_ id: AgentConversation.ID) async {
        guard let task = tasks[id] else { return }
        task.cancel()
        await task.value
    }

    /// At launch: conversations a quit left `running` end `failed`. A `deadlines` conversation
    /// that wrote nothing gets the composer's parse of the student's last words (relative to when
    /// they were written), as a failed run does. Stored turns too large to sync are counted in
    /// the log (`logTurnsTooLargeToSync`).
    public func recoverInterrupted() async {
        await logTurnsTooLargeToSync()
        let interrupted: [AgentConversation]
        do {
            interrupted = try await conversations.running().filter { tasks[$0.id] == nil }
        } catch {
            AgentModule.log.error("Recovering conversations failed: \(String(describing: error), privacy: .public)")
            return
        }
        for conversation in interrupted {
            do {
                try await conversations.setState(conversation.id, .failed, error: "The app quit while the agent was working.")
                guard conversation.kind == .deadlines, let last = try await lastStudentText(conversation.id) else { continue }
                let courses = try await services.database.read { db in try Course.order(by: \.sortOrder).fetchAll(db) }
                guard let draft = DeadlineParser.parse(last.text, now: last.writtenAt, courses: courses) else { continue }
                await DeadlineComposer.addUnlessWritten(draft, text: last.text, conversationID: conversation.id, services: services, memory: memory)
            } catch {
                AgentModule.log.error("Recovering a conversation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The text of the conversation's last user turn that has some (tool results and the clock
    /// are none), and when it was written.
    private func lastStudentText(_ id: AgentConversation.ID) async throws -> (text: String, writtenAt: Date)? {
        let turns = try await conversations.turns(id).filter { $0.role == .user }
        for turn in turns.reversed() {
            let message = try MessageParam(json: JSONValue.parse(turn.message))
            let text = message.content.blocks.compactMap(\.textValue).filter { !AgentClock.isClock($0) }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return (text, turn.createdAt) }
        }
        return nil
    }

    /// The answer the agent is writing in conversation `id`, about ten times a second: the text of
    /// the API call in flight, shown after `LiveReply.afterTurns` stored turns. Nil when nothing
    /// streams. Never stored: `agent_turn` gets the complete turn when the call ends.
    public nonisolated func liveReplies(_ id: AgentConversation.ID) -> AsyncStream<LiveReply?> {
        live.stream(id)
    }

    /// Whether conversation `id` is running in this process.
    public func isRunning(_ id: AgentConversation.ID) -> Bool {
        tasks[id] != nil
    }

    /// Waits until the conversation's current run ends; the conversation as it ended.
    public func outcome(_ id: AgentConversation.ID) async -> AgentConversation? {
        if let task = tasks[id] { await task.value }
        return try? await services.records.fetch(AgentConversation.self, id: id)
    }

    // MARK: - Running

    private func launch(
        _ conversation: AgentConversation, spec: ConversationSpec, history: [MessageParam], studentText: String, writtenAt: Date,
        turnContext: AgentTurnContext? = nil, readUntrusted: Bool = false
    ) {
        // ma: an open mail in the turn's context is untrusted content this run has read, as is
        // what an earlier turn of the conversation read (`readUntrusted`).
        let trace = RunTrace(readUntrustedContent: readUntrusted || turnContext?.context?.mailMessageID != nil)
        // The last run's unsaved text is not handed to panels opened from now on.
        live.clear(conversation.id)
        let context = ToolContext(
            conversationID: conversation.id, studentText: studentText, now: now(), wordsWrittenAt: writtenAt, trace: trace,
            turnContext: turnContext
        )
        serviceTrouble.remove(conversation.id)
        tasks[conversation.id] = Task {
            await self.run(conversation, spec: spec, history: history, context: context)
            self.finished(conversation.id)
        }
    }

    private func finished(_ id: AgentConversation.ID) {
        tasks[id] = nil
        live.end(id)
    }

    private func run(_ conversation: AgentConversation, spec: ConversationSpec, history: [MessageParam], context: ToolContext) async {
        let id = conversation.id
        let recorder = TurnRecorder(
            conversations: conversations, apiCalls: APICallRepository(store: services.records), conversationID: id,
            purpose: spec.purpose, live: live, storedTurns: history.count
        )
        do {
            let courses = CourseList(tokens: try await CourseTokens.load(services.database))
            // Files stored by reference carry their bytes again, as the first request did, in the
            // turns the backend sends: Claude Code sends only the user turns after the last answer
            // (its session holds the earlier ones, and a replay without it reads only their text),
            // so an answered turn's file is never read, and one gone from this library (blobs do
            // not sync) does not end every later run. The Messages API sends every turn.
            let pending = client.backendKind == .messagesAPI
                ? history.startIndex
                : (history.lastIndex { $0.role == .assistant }.map { $0 + 1 } ?? history.startIndex)
            let messages = try history.indices.map { index in
                index >= pending ? try history[index].sendable(blobs: services.blobs) : history[index]
            }
            let request = MessageRequest(
                model: spec.model, maxTokens: spec.maxTokens, effort: spec.effort, messages: messages,
                system: [SystemBlock(text: spec.system(conversation.createdAt, courses))],
                tools: spec.requestTools, thinking: spec.thinking, cacheControl: .ephemeral
            )
            let loop = ToolLoop(client: client, maxIterations: spec.maxIterations, streaming: true, parallelToolExecution: false)
            // M3.5: a backend that keeps conversations (Claude Code) continues the conversation's
            // own session once an assistant turn exists; the Messages API ignores it.
            let session = ConversationSession(id: id, resumes: history.contains { $0.role == .assistant })
            let result = try await loop.run(
                request, context: CallContext(purpose: spec.purpose, priority: spec.priority, session: session),
                handler: spec.tools.handler(context),
                onEvent: { event in await recorder.handle(event) }
            )
            if let failure = await recorder.failure { throw failure }
            switch result.stop {
            case .endTurn:
                await end(id, .finished)
            case .refusal:
                await end(id, .failed, error: "The model declined to answer.")
            case .truncated:
                await end(id, .failed, error: "The answer was cut off.")
            case .iterationLimit:
                AgentModule.log.notice("Run stopped after \(spec.maxIterations, privacy: .public) calls")
                await end(id, .failed, error: String(localized: "Stopped after too many steps."))
            case .other(let reason):
                // The raw stop reason goes to the log only.
                AgentModule.log.notice("Run stopped early: \(reason?.rawValue ?? "unknown", privacy: .public)")
                await end(id, .failed, error: String(localized: "The answer stopped early."))
            }
        } catch {
            // One readable sentence is stored and shown; the error itself goes to the log only.
            // Only a task's run is tried again by itself (the queue): an answer's says "busy".
            if (error as? ClaudeError)?.isServiceTrouble == true { serviceTrouble.insert(id) }
            let message: String
            if case .missing? = error as? BlobStoreError {
                // A file a stored turn sends by reference is gone (`sendable(blobs:)`): nothing is
                // sent without it.
                message = String(localized: "The file is no longer there.")
            } else {
                message = ReadableError.sentence(
                    for: error, otherwise: String(localized: "The answer could not be saved."), retrying: conversation.kind == .task, now: now()
                )
            }
            AgentModule.log.error(
                "Conversation failed: \(ReadableError.kind(of: error), privacy: .public): \(String(describing: error), privacy: .private)"
            )
            await end(id, .failed, error: message)
        }
        // What the call in flight wrote and no stored turn holds (a stop, a failure, a cut-off
        // answer) stays under the message it answered.
        await recorder.publishUnsaved()
    }

    /// Stores how a run ended. A Stop cancels the run's task, and GRDB's async write throws
    /// `CancellationError` in a cancelled task, so the state is written from a task of its own
    /// (an unstructured task does not inherit the cancellation): the conversation never stays
    /// `running` after a Stop.
    private func end(_ id: AgentConversation.ID, _ state: ConversationState, error: String? = nil) async {
        let conversations = conversations
        let failure = await Task { () -> (any Error)? in
            do {
                _ = try await conversations.setState(id, state, error: error)
                return nil
            } catch let failure {
                return failure
            }
        }.value
        if let failure {
            AgentModule.log.error("Storing how a run ended failed: \(ReadableError.kind(of: failure), privacy: .public)")
        }
    }

    /// Whether the conversation's last run in this process ended on trouble with the service
    /// (signed out, the CLI crashed, the network, an overload, a usage pause), not the request:
    /// the sub-agent queue then waits instead of failing the task.
    public func endedWithServiceTrouble(_ id: AgentConversation.ID) -> Bool {
        serviceTrouble.contains(id)
    }

    // MARK: - Turns

    /// A turn's stored form: the Messages API JSON, sorted keys, every block verbatim (a file the
    /// student's turn sends is a `BlockSource.blob` reference already, made so by its sender).
    static func encode(_ turn: MessageParam) throws -> String {
        try turn.json.serializedString()
    }

    /// The history as stored, decoded without changing a byte of what will be sent again (`run`
    /// gives files stored by reference in the turns it sends their bytes back:
    /// `MessageParam.sendable(blobs:)`).
    static func history(_ turns: [AgentTurn]) throws -> [MessageParam] {
        try turns.map { try MessageParam(json: JSONValue.parse($0.message)) }
    }

    /// iCloud's record size: a stored turn larger than this never syncs.
    static let syncedRecordBytes = 1_000_000

    /// Turns over iCloud's record size, stored before files went by reference (2026-10-27): they
    /// stay as they are, on this device, and are never rewritten. One log line a launch says how
    /// many (the message's length in bytes, read without its text).
    private func logTurnsTooLargeToSync() async {
        do {
            let limit = Self.syncedRecordBytes
            let count = try await services.database.read { db in
                try Int.fetchOne(db, sql: #"SELECT count(*) FROM "agent_turn" WHERE octet_length("message") > ?"#, arguments: [limit]) ?? 0
            }
            guard count > 0 else { return }
            AgentModule.log.notice("\(count, privacy: .public) stored turns are over iCloud's record size and stay on this device")
        } catch {
            AgentModule.log.error("Counting turns too large to sync failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
    }
}

/// Stores the turns a tool loop appends, in order, with the assistant turns' `api_call` links.
actor TurnRecorder {
    let conversations: ConversationRepository
    let apiCalls: APICallRepository
    let conversationID: AgentConversation.ID
    let purpose: String
    let live: LiveReplies
    /// Turns stored so far (the history the run started with, then every appended turn).
    private var storedTurns: Int
    private var requestID: String?
    private var stopReason: String?
    /// The text blocks of the call in flight, and when they were last published.
    private var liveText = ""
    private var lastPublish: ContinuousClock.Instant?
    private let clock = ContinuousClock()
    /// The first storage error; the run ends `failed` with it.
    private(set) var failure: (any Error)?

    /// Live text is published at most this often (about ten times a second).
    static let publishInterval: Duration = .milliseconds(100)

    init(
        conversations: ConversationRepository, apiCalls: APICallRepository, conversationID: AgentConversation.ID, purpose: String,
        live: LiveReplies, storedTurns: Int
    ) {
        self.conversations = conversations
        self.apiCalls = apiCalls
        self.conversationID = conversationID
        self.purpose = purpose
        self.live = live
        self.storedTurns = storedTurns
    }

    /// The run ended: the text of the call in flight, if any, was never stored.
    func publishUnsaved() {
        guard !liveText.isEmpty else { return }
        live.publish(conversationID, LiveReply(afterTurns: storedTurns, text: liveText, unsaved: true))
    }

    private func publishLive(force: Bool) {
        let now = clock.now
        if !force, let lastPublish, now - lastPublish < Self.publishInterval { return }
        lastPublish = now
        live.publish(conversationID, LiveReply(afterTurns: storedTurns, text: liveText))
    }

    func handle(_ event: ToolLoopEvent) async {
        switch event {
        case .stream(_, .messageStart(let message)):
            requestID = message.requestID
            stopReason = nil
            liveText = ""
            lastPublish = nil
        case .stream(_, .contentBlockStart(_, .text)):
            // A second text block of one answer starts a new paragraph.
            if !liveText.isEmpty, !liveText.hasSuffix("\n\n") { liveText += "\n\n" }
        case .stream(_, .contentBlockDelta(_, .text(let delta))):
            liveText += delta
            publishLive(force: false)
        case .stream(_, .contentBlockStop), .stream(_, .messageStop):
            if !liveText.isEmpty { publishLive(force: true) }
        case .stream(_, .messageDelta(let delta, _)):
            if let reason = delta["stop_reason"]?.stringValue { stopReason = reason }
        case .appended(let turn):
            guard failure == nil else { return }
            do {
                if turn.role == .assistant {
                    let callID = try await apiCalls.call(requestID: requestID, purpose: purpose)
                    try await conversations.append(
                        to: conversationID, role: .assistant, message: try AgentRuntime.encode(turn), stopReason: stopReason,
                        apiCallID: callID
                    )
                } else {
                    try await conversations.append(to: conversationID, role: .user, message: try AgentRuntime.encode(turn))
                }
                storedTurns += 1
                if turn.role == .assistant {
                    // Its text is stored now; the next call starts a new live text.
                    liveText = ""
                } else if !liveText.isEmpty {
                    // A tool-result turn stored while the next call streams (a backend may report
                    // it late): the live text now follows one more turn.
                    publishLive(force: true)
                }
            } catch {
                failure = error
            }
        default:
            break
        }
    }
}
