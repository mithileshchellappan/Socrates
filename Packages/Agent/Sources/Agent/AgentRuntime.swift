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
///   readable error. `recoverInterrupted()` fails what a quit left `running`.
/// - Requests always state `effort`, never force `tool_choice`, never disable thinking.
public actor AgentRuntime {
    let services: StudyServices
    let client: ClaudeClient
    let memory: DeadlineMemory
    let now: @Sendable () -> Date
    private var tasks: [AgentConversation.ID: Task<Void, Never>] = [:]

    public init(
        services: StudyServices,
        client: ClaudeClient,
        memory: DeadlineMemory? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.memory = memory ?? DeadlineMemory(services: services, now: now)
        self.now = now
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

    /// The one spec of `kind`.
    func spec(for kind: ConversationKind) throws -> ConversationSpec {
        switch kind {
        case .deadlines: return try DeadlineTools.spec(services: services, memory: memory)
        default: throw RuntimeError.unknownKind(kind.rawValue)
        }
    }

    // MARK: - Entry points

    /// Starts a conversation of `kind` with the student's `text`; returns at once while the agent
    /// works in the background.
    public func start(_ kind: ConversationKind, text: String, courseID: Course.ID? = nil) async throws -> AgentConversation.ID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeError.emptyText }
        let spec = try spec(for: kind)
        let startedAt = now()
        let conversation = try await conversations.start(AgentConversation(
            kind: kind, courseID: courseID, title: String(trimmed.prefix(60)), model: spec.model.rawValue, state: .running,
            createdAt: startedAt, updatedAt: startedAt
        ))
        let turn = MessageParam.user(trimmed)
        try await conversations.append(to: conversation.id, role: .user, message: try Self.encode(turn))
        launch(conversation, spec: spec, history: [turn], studentText: trimmed)
        return conversation.id
    }

    /// Appends the student's next message to a conversation that is not running and runs it again.
    public func send(_ text: String, to id: AgentConversation.ID) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw RuntimeError.emptyText }
        guard tasks[id] == nil else { throw RuntimeError.busy }
        guard let conversation = try await services.records.fetch(AgentConversation.self, id: id) else {
            throw RuntimeError.unknownConversation
        }
        let spec = try spec(for: conversation.kind)
        var history = try await Self.history(conversations.turns(id))
        // A run that stopped between a tool call and its result: answer the calls first (the API
        // needs a result for each), in the same new user turn.
        var blocks: [ContentBlock] = []
        if let last = history.last, last.role == .assistant {
            blocks = last.content.blocks.compactMap(\.toolUse).map { call in
                .toolResult(ToolResultBlock(toolUseID: call.id, content: .text("interrupted"), isError: true))
            }
        }
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

    /// At launch: conversations a quit left `running` end `failed`.
    public func recoverInterrupted() async {
        do {
            for conversation in try await conversations.running() where tasks[conversation.id] == nil {
                try await conversations.setState(conversation.id, .failed, error: "The app quit while the agent was working.")
            }
        } catch {
            AgentModule.log.error("Recovering conversations failed: \(String(describing: error), privacy: .public)")
        }
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
    }

    private func run(_ conversation: AgentConversation, spec: ConversationSpec, history: [MessageParam], context: ToolContext) async {
        let id = conversation.id
        let recorder = TurnRecorder(
            conversations: conversations, apiCalls: APICallRepository(store: services.records), conversationID: id,
            purpose: spec.purpose
        )
        do {
            let courses = CourseList(tokens: try await CourseTokens.load(services.database))
            let request = MessageRequest(
                model: spec.model, maxTokens: spec.maxTokens, effort: spec.effort, messages: history,
                system: [SystemBlock(text: spec.system(conversation.createdAt, courses))],
                tools: spec.tools.definitions, thinking: spec.thinking, cacheControl: .ephemeral
            )
            let loop = ToolLoop(client: client, maxIterations: spec.maxIterations, streaming: true, parallelToolExecution: false)
            let result = try await loop.run(
                request, context: CallContext(purpose: spec.purpose), handler: spec.tools.handler(context),
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
    private var requestID: String?
    private var stopReason: String?
    /// The first storage error; the run ends `failed` with it.
    private(set) var failure: (any Error)?

    init(conversations: ConversationRepository, apiCalls: APICallRepository, conversationID: AgentConversation.ID, purpose: String) {
        self.conversations = conversations
        self.apiCalls = apiCalls
        self.conversationID = conversationID
        self.purpose = purpose
    }

    func handle(_ event: ToolLoopEvent) async {
        switch event {
        case .stream(_, .messageStart(let message)):
            requestID = message.requestID
            stopReason = nil
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
            } catch {
                failure = error
            }
        default:
            break
        }
    }
}
