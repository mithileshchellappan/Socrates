import ClaudeKit
import Deadlines
import Foundation
import StudyCore
import Synchronization

/// What a tool does outside the conversation.
public enum ToolEffect: String, Sendable, Hashable {
    /// Reads the library; changes nothing.
    case read
    /// Writes a staged proposal the student confirms (Confirm / Edit / Discard).
    case stage
    /// Changes the library on its own (deadlines through the memory, with Undo).
    case write
    /// M3.5: changes the library on its own only with what code verified against words that are
    /// not the model's: the quote is the student's words of the turn or an exact span of a mail,
    /// the date is found in that quote (`DateMentions`), a mail quote is `trusted` only when the
    /// mail passes the injection guard. Allowed beside tools that read untrusted content (the
    /// mail chat's add_item; added 2026-10-17).
    case verifiedWrite
    /// M3.5: writes a reply draft (`mail_draft`) and nothing else; only the student sends it.
    /// Allowed beside tools that read untrusted content.
    case draft
    /// ma: queues or cancels a sub-agent task (`agent_task`), which runs in its own conversation
    /// with a tool set fixed at spawn (never web beside mail). Allowed beside tools that read
    /// untrusted content: what it hands over is checked where it runs (AppAgent's task queue).
    case delegate
}

/// ma: what one run of a conversation has read so far (shared by its tool calls): whether
/// untrusted content (mail) reached it, through the turn's context or a tool. A sub-agent task
/// with web tools spawned by such a run gets no input summary (the web agent never sees mail).
public final class RunTrace: Sendable {
    private let readUntrusted: Mutex<Bool>

    public init(readUntrustedContent: Bool = false) {
        readUntrusted = Mutex(readUntrustedContent)
    }

    /// Mail (or another untrusted source) reached this run.
    public var hasReadUntrustedContent: Bool { readUntrusted.withLock { $0 } }

    public func noteUntrustedRead() {
        readUntrusted.withLock { $0 = true }
    }
}

/// What a tool call runs with: the conversation, the student's words of the current turn (the
/// quote of everything the agent writes) and when they were said.
public struct ToolContext: Sendable {
    public var conversationID: AgentConversation.ID
    public var studentText: String
    /// The time now: what has happened yet, what lies ahead.
    public var now: Date
    /// When the student wrote `studentText`: relative days in it ("today", "yesterday", a
    /// weekday) are read against this. `now` for a message answered at once; earlier on Try
    /// again, for a question asked on the iPhone and for a sub-agent task that waited.
    public var wordsWrittenAt: Date
    /// ma: the run's trace (mail read so far).
    public var trace: RunTrace
    /// ma: what the student's turn carried besides the words (an `app` conversation's screen).
    public var turnContext: AgentTurnContext?

    public init(
        conversationID: AgentConversation.ID, studentText: String, now: Date, wordsWrittenAt: Date? = nil, trace: RunTrace = RunTrace(),
        turnContext: AgentTurnContext? = nil
    ) {
        self.conversationID = conversationID
        self.studentText = studentText
        self.now = now
        self.wordsWrittenAt = wordsWrittenAt ?? now
        self.trace = trace
        self.turnContext = turnContext
    }
}

/// A ClaudeKit tool with what it may do and the code that runs it.
public struct AgentTool: Sendable {
    public typealias Handler = @Sendable (ToolUseBlock, ToolContext) async throws -> ToolOutput

    public var tool: Tool
    public var effect: ToolEffect
    /// It reads mail, web pages or files: content that may carry instructions.
    public var readsUntrustedContent: Bool
    public var handler: Handler

    public init(tool: Tool, effect: ToolEffect, readsUntrustedContent: Bool = false, handler: @escaping Handler) {
        self.tool = tool
        self.effect = effect
        self.readsUntrustedContent = readsUntrustedContent
        self.handler = handler
    }

    public var name: String { tool.name }
}

/// Why a tool set is refused.
public enum ToolSetError: Error, Hashable, CustomStringConvertible {
    /// A conversation that reads untrusted content may only stage proposals, never write (PRD trust rule).
    case untrustedContentWithWriteTool(reader: String, writer: String)
    case duplicateName(String)
    /// M5: the web tools (Claude Code's WebSearch / WebFetch) never sit beside a tool that reads
    /// untrusted content (mail) or a `.write` tool (PRD: the web agent never sees mail).
    case webToolsBeside(String)
    /// M5: only `.webSearch` / `.webFetch` are web tools.
    case notAWebTool(String)

    public var description: String {
        switch self {
        case .untrustedContentWithWriteTool(let reader, let writer):
            "\(reader) reads untrusted content, so \(writer) may not write in the same conversation"
        case .duplicateName(let name): "two tools are called \(name)"
        case .webToolsBeside(let name): "\(name) reads untrusted content or writes, so the web tools may not be in the same conversation"
        case .notAWebTool(let name): "\(name) is not a web tool"
        }
    }
}

/// The fixed tools of one conversation kind. Checked when built: a set with a tool that reads
/// untrusted content (mail, web, files) and any `.write` tool is refused (`.verifiedWrite`,
/// `.draft`, `.stage` and `.read` may sit beside it). M5: `webTools` (`.webSearch` / `.webFetch`,
/// run by Claude Code itself, or by the API as server tools) are refused beside any tool that
/// reads untrusted content and beside any `.write` tool.
public struct ToolSet: Sendable {
    public let kind: ConversationKind
    public let tools: [AgentTool]
    /// M5: Claude Code's WebSearch / WebFetch, sent after the custom tools.
    public let webTools: [Tool]

    public init(kind: ConversationKind, tools: [AgentTool], webTools: [Tool] = []) throws {
        if let reader = tools.first(where: \.readsUntrustedContent), let writer = tools.first(where: { $0.effect == .write }) {
            throw ToolSetError.untrustedContentWithWriteTool(reader: reader.name, writer: writer.name)
        }
        for web in webTools {
            switch web {
            case .webSearch, .webFetch: break
            default: throw ToolSetError.notAWebTool(web.name)
            }
        }
        if !webTools.isEmpty, let tool = tools.first(where: { $0.readsUntrustedContent || $0.effect == .write }) {
            throw ToolSetError.webToolsBeside(tool.name)
        }
        // ma: a sub-agent task with the web tools never writes the student's data, not even
        // verified (a web page is never the source of a change).
        if kind == .task, !webTools.isEmpty, let tool = tools.first(where: { $0.effect == .verifiedWrite }) {
            throw ToolSetError.webToolsBeside(tool.name)
        }
        var names: Set<String> = []
        for name in tools.map(\.name) + webTools.map(\.name) where !names.insert(name).inserted {
            throw ToolSetError.duplicateName(name)
        }
        self.kind = kind
        self.tools = tools
        self.webTools = webTools
    }

    /// The custom tools' definitions sent with every request of the conversation, in a fixed
    /// order (the web tools follow them: `ConversationSpec.requestTools`).
    public var definitions: [Tool] { tools.map(\.tool) }

    /// The same set with `more` custom tools after these (checked again).
    public func adding(_ more: [AgentTool]) throws -> ToolSet {
        try ToolSet(kind: kind, tools: tools + more, webTools: webTools)
    }

    public func tool(named name: String) -> AgentTool? { tools.first { $0.name == name } }

    /// The tool loop's handler for one run. An unknown tool is an error result.
    func handler(_ context: ToolContext) -> ToolHandler {
        let tools = tools
        return { call in
            guard let tool = tools.first(where: { $0.name == call.name }) else { return .error("unknown tool \(call.name)") }
            // ma: the run has read mail from now on (a sub-agent it spawns gets no web with it).
            if tool.readsUntrustedContent { context.trace.noteUntrustedRead() }
            return try await tool.handler(call, context)
        }
    }
}

/// How one conversation kind runs: model, effort, limits, system prompt and tools. Never changes
/// within a conversation.
public struct ConversationSpec: Sendable {
    public var kind: ConversationKind
    public var model: ClaudeModel
    public var effort: Effort
    public var maxTokens: Int
    /// API calls per run (`ToolLoop.maxIterations`).
    public var maxIterations: Int
    public var thinking: ThinkingConfig?
    public var tools: ToolSet
    /// The system prompt of a conversation started at `startedAt` with these courses (the same
    /// on every iteration and every later message).
    public var system: @Sendable (_ startedAt: Date, _ courses: CourseList) -> String
    /// ma: who waits for its calls (a sub-agent task: `.background`, so the panel never waits
    /// behind it; ClaudeKit's process slots).
    public var priority: CallPriority = .interactive

    /// M3.5: specs of kinds built outside this package (`AgentRuntime.SpecProvider`, the mail chat).
    public init(
        kind: ConversationKind,
        model: ClaudeModel,
        effort: Effort,
        maxTokens: Int,
        maxIterations: Int,
        thinking: ThinkingConfig?,
        tools: ToolSet,
        system: @escaping @Sendable (_ startedAt: Date, _ courses: CourseList) -> String
    ) {
        self.kind = kind
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.maxIterations = maxIterations
        self.thinking = thinking
        self.tools = tools
        self.system = system
    }

    public var purpose: String { AgentModule.purpose(of: kind) }

    /// M5: the web tools of this kind (`ToolSet.webTools`; the tutor's `.webSearch`, `.webFetch`).
    public var webTools: [Tool] { tools.webTools }

    /// What a request of this kind sends as `tools`: the custom tools, then the web tools.
    public var requestTools: [Tool] { tools.definitions + tools.webTools }
}

/// The courses a system prompt names.
public struct CourseList: Sendable {
    let tokens: CourseTokens

    /// M5: the courses in sidebar order with their tokens (the Tutor package's tools and context
    /// blocks name courses as the deadline tools do).
    public static func load(_ database: any DatabaseReader) async throws -> CourseList {
        CourseList(tokens: try await CourseTokens.load(database))
    }

    /// The courses in sidebar order.
    public var courses: [Course] { tokens.entries.map(\.course) }

    /// "DC" for the course with `courseID`.
    public func token(for courseID: Course.ID?) -> String? { tokens.token(for: courseID) }

    /// The course a token, name, short name or id names.
    public func course(_ reference: String?) -> Course? { tokens.course(reference) }

    /// Whether `text` (the student's words) names the course with `courseID`: its name, short
    /// name or token, as the deadline parser finds a course in a message.
    public func names(_ courseID: Course.ID, in text: String) -> Bool {
        guard let course = courses.first(where: { $0.id == courseID }) else { return false }
        return DeadlineParser.course(in: text, courses: [course]) != nil
    }

    /// "Fri 16 Oct 2026, 15:02" in the university's time zone: how a system prompt states when the conversation
    /// started (M3.5: the mail chat's prompt is built in MailIntelligence).
    public static func spokenDate(_ date: Date) -> String { AgentDates.spoken(date) }

    /// One line per course: "DC: Data Centers; lecturers: …" (the tokens the tools accept).
    public var promptLines: String { tokens.promptLines }
}

/// Readable JSON tool inputs.
extension ToolUseBlock {
    func string(_ key: String) -> String? {
        guard let value = input[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    func bool(_ key: String) -> Bool? { input[key]?.boolValue }
}
