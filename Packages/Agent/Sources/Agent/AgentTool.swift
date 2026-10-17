import ClaudeKit
import Foundation
import StudyCore

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
    /// mail chat's add_item).
    case verifiedWrite
    /// M3.5: writes a reply draft (`mail_draft`) and nothing else; only the student sends it.
    /// Allowed beside tools that read untrusted content.
    case draft
}

/// What a tool call runs with: the conversation, the student's words of the current turn (the
/// quote of everything the agent writes) and when they were said.
public struct ToolContext: Sendable {
    public var conversationID: AgentConversation.ID
    public var studentText: String
    public var now: Date

    public init(conversationID: AgentConversation.ID, studentText: String, now: Date) {
        self.conversationID = conversationID
        self.studentText = studentText
        self.now = now
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

    public var description: String {
        switch self {
        case .untrustedContentWithWriteTool(let reader, let writer):
            "\(reader) reads untrusted content, so \(writer) may not write in the same conversation"
        case .duplicateName(let name): "two tools are called \(name)"
        }
    }
}

/// The fixed tools of one conversation kind. Checked when built: a set with a tool that reads
/// untrusted content (mail, web, files) and any `.write` tool is refused (`.verifiedWrite`,
/// `.draft`, `.stage` and `.read` may sit beside it).
public struct ToolSet: Sendable {
    public let kind: ConversationKind
    public let tools: [AgentTool]

    public init(kind: ConversationKind, tools: [AgentTool]) throws {
        if let reader = tools.first(where: \.readsUntrustedContent), let writer = tools.first(where: { $0.effect == .write }) {
            throw ToolSetError.untrustedContentWithWriteTool(reader: reader.name, writer: writer.name)
        }
        var names: Set<String> = []
        for tool in tools where !names.insert(tool.name).inserted {
            throw ToolSetError.duplicateName(tool.name)
        }
        self.kind = kind
        self.tools = tools
    }

    /// The definitions sent with every request of the conversation, in a fixed order.
    public var definitions: [Tool] { tools.map(\.tool) }

    public func tool(named name: String) -> AgentTool? { tools.first { $0.name == name } }

    /// The tool loop's handler for one run. An unknown tool is an error result.
    func handler(_ context: ToolContext) -> ToolHandler {
        let tools = tools
        return { call in
            guard let tool = tools.first(where: { $0.name == call.name }) else { return .error("unknown tool \(call.name)") }
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

    public var purpose: String { AgentModule.purpose(of: kind) }
}

/// The courses a system prompt names.
public struct CourseList: Sendable {
    let tokens: CourseTokens

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
