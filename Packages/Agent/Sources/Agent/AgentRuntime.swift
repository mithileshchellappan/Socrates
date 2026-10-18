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
/// - The end: `finished`; an error, a refusal, truncation or the call limit: `failed` with a
///   readable error. `recoverInterrupted()` fails what a quit left `running` and adds the
///   composer's parse of what such a `deadlines` conversation was told when it wrote nothing.
/// - Requests always state `effort`, never force `tool_choice`, never disable thinking.
public actor AgentRuntime {
    /// Builds the one spec of a conversation kind defined outside this package (M3.5: the mail
    /// chat, assembled in MailIntelligence from its mail tools and the deadline tools).
    public typealias SpecProvider = @Sendable () throws -> ConversationSpec

    let services: StudyServices
    let client: ClaudeClient
    let memory: DeadlineMemory
    let now: @Sendable () -> Date
    let additionalSpecs: [ConversationKind: SpecProvider]
    private var tasks: [AgentConversation.ID: Task<Void, Never>] = [:]
    /// The answer being written, per conversation (M3.5: the chat streams it into place).
    private let live = LiveReplies()

    public init(
        services: StudyServices,
        client: ClaudeClient,
        memory: DeadlineMemory? = nil,
        additionalSpecs: [ConversationKind: SpecProvider] = [:],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.memory = memory ?? DeadlineMemory(services: services, now: now)
        self.additionalSpecs = additionalSpecs
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

        public var description: String {
            switch self {
            case .unknownKind(let kind): "no tool set for conversations of kind \(kind)"
            case .unknownConversation: "no such conversation"
            case .busy: "the agent is still working on this conversation"
            case .emptyText: "nothing to send"
            }
        }
    }

    /// The one spec of `kind`. M5: `mail_chat` and `tutor` get the memory tools (remember,
    /// update_memory, forget) after their own and the memory rules after their system prompt.
    func spec(for kind: ConversationKind) throws -> ConversationSpec {
        var spec: ConversationSpec
        switch kind {
        case .deadlines: spec = try DeadlineTools.spec(services: services, memory: memory)
        default:
            guard let provider = additionalSpecs[kind] else { throw RuntimeError.unknownKind(kind.rawValue) }
            spec = try provider()
        }
        guard MemoryTools.kinds.contains(kind) else { return spec }
        spec.tools = try spec.tools.adding(MemoryTools(services: services).all)
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
    /// turn (M3.5: the open mail as a `<mail>` envelope, data never instructions); the tools'
    /// `ToolContext.studentText` is the student's words only. M5: `lectureID` is a tutor
    /// conversation's lecture (its subject, with the lecture's `courseID`); a `mail_chat` or
    /// `tutor` conversation's first turn starts with the `<memory>` block.
    public func start(
        _ kind: ConversationKind, text: String, context: [ContentBlock] = [], courseID: Course.ID? = nil, lectureID: Lecture.ID? = nil
    ) async throws -> AgentConversation.ID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeError.emptyText }
        let spec = try spec(for: kind)
        let memory = try await memoryBlock(for: kind, history: [])
        let startedAt = now()
        let conversation = try await conversations.start(AgentConversation(
            kind: kind, courseID: courseID, lectureID: lectureID, title: String(trimmed.prefix(60)), model: spec.model.rawValue,
            state: .running, createdAt: startedAt, updatedAt: startedAt
        ))
        let blocks = memory + context
        let turn: MessageParam = blocks.isEmpty ? .user(trimmed) : .user(blocks + [.text(TextBlock(text: trimmed))])
        try await conversations.append(to: conversation.id, role: .user, message: try Self.encode(turn))
        launch(conversation, spec: spec, history: [turn], studentText: trimmed)
        return conversation.id
    }

    /// Appends the student's next message (after its `context` blocks) to a conversation that is
    /// not running and runs it again.
    public func send(_ text: String, context: [ContentBlock] = [], to id: AgentConversation.ID) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeError.emptyText }
        guard tasks[id] == nil else { throw RuntimeError.busy }
        guard let conversation = try await services.records.fetch(AgentConversation.self, id: id) else {
            throw RuntimeError.unknownConversation
        }
        let spec = try spec(for: conversation.kind)
        var history = try await Self.history(conversations.turns(id))
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
        let turn: MessageParam = blocks.isEmpty ? .user(trimmed) : .user(blocks + [.text(TextBlock(text: trimmed))])
        try await conversations.append(to: id, role: .user, message: try Self.encode(turn))
        history.append(turn)
        try await conversations.setState(id, .running)
        launch(conversation, spec: spec, history: history, studentText: trimmed)
    }

    /// Stops a running conversation (it ends `failed`).
    public func stop(_ id: AgentConversation.ID) async {
        guard let task = tasks[id] else { return }
        task.cancel()
        await task.value
    }

    /// At launch: conversations a quit left `running` end `failed`. A `deadlines` conversation
    /// that wrote nothing gets the composer's parse of the student's last words (relative to when
    /// it started), as a failed run does.
    public func recoverInterrupted() async {
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
                guard conversation.kind == .deadlines, let text = try await lastStudentText(conversation.id) else { continue }
                let courses = try await services.database.read { db in try Course.order(by: \.sortOrder).fetchAll(db) }
                guard let draft = DeadlineParser.parse(text, now: conversation.createdAt, courses: courses) else { continue }
                await DeadlineComposer.addUnlessWritten(draft, text: text, conversationID: conversation.id, services: services, memory: memory)
            } catch {
                AgentModule.log.error("Recovering a conversation failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The text of the conversation's last user turn that has some (tool results have none).
    private func lastStudentText(_ id: AgentConversation.ID) async throws -> String? {
        let turns = try await conversations.turns(id).filter { $0.role == .user }
        for turn in turns.reversed() {
            let message = try MessageParam(json: JSONValue.parse(turn.message))
            let text = message.content.blocks.compactMap(\.textValue).joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
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

    private func launch(_ conversation: AgentConversation, spec: ConversationSpec, history: [MessageParam], studentText: String) {
        let context = ToolContext(conversationID: conversation.id, studentText: studentText, now: now())
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
            let request = MessageRequest(
                model: spec.model, maxTokens: spec.maxTokens, effort: spec.effort, messages: history,
                system: [SystemBlock(text: spec.system(conversation.createdAt, courses))],
                tools: spec.requestTools, thinking: spec.thinking, cacheControl: .ephemeral
            )
            let loop = ToolLoop(client: client, maxIterations: spec.maxIterations, streaming: true, parallelToolExecution: false)
            // M3.5: a backend that keeps conversations (Claude Code) continues the conversation's
            // own session once an assistant turn exists; the Messages API ignores it.
            let session = ConversationSession(id: id, resumes: history.contains { $0.role == .assistant })
            let result = try await loop.run(
                request, context: CallContext(purpose: spec.purpose, session: session), handler: spec.tools.handler(context),
                onEvent: { event in await recorder.handle(event) }
            )
            if let failure = await recorder.failure { throw failure }
            switch result.stop {
            case .endTurn:
                try await conversations.setState(id, .finished)
            case .refusal:
                try await conversations.setState(id, .failed, error: "The model declined to answer.")
            case .truncated:
                try await conversations.setState(id, .failed, error: "The answer was cut off.")
            case .iterationLimit:
                try await conversations.setState(id, .failed, error: "Stopped after \(spec.maxIterations) calls.")
            case .other(let reason):
                try await conversations.setState(id, .failed, error: "Stopped: \(reason?.rawValue ?? "unknown").")
            }
        } catch {
            let message: String = switch error {
            case is CancellationError: "Stopped."
            case let error as ClaudeError: error.description
            default: String(describing: error)
            }
            AgentModule.log.error("Conversation failed: \(message, privacy: .public)")
            _ = try? await conversations.setState(id, .failed, error: message)
        }
    }

    // MARK: - Turns

    /// A turn's stored form: the Messages API JSON, sorted keys, every block verbatim.
    static func encode(_ turn: MessageParam) throws -> String {
        try turn.json.serializedString()
    }

    /// The history as stored, decoded without changing a byte of what will be sent again.
    static func history(_ turns: [AgentTurn]) throws -> [MessageParam] {
        try turns.map { try MessageParam(json: JSONValue.parse($0.message)) }
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
