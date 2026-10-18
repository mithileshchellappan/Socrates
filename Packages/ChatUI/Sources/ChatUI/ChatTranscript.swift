import ClaudeKit
import Foundation
import StudyCore

/// The conversation as the chat shows it: the student's messages and the agent's answers. One
/// answer block is all the agent wrote between two messages of the student (its text blocks
/// across the tool loop's calls); thinking, tool calls, tool results and the `<mail>` context
/// blocks are not shown.
struct ChatTranscript: Equatable {
    enum Entry: Identifiable, Equatable {
        case student(id: AgentTurn.ID, text: String)
        case answer(id: AgentTurn.ID, text: String)

        var id: AgentTurn.ID {
            switch self {
            case .student(let id, _), .answer(let id, _): id
            }
        }
    }

    var entries: [Entry] = []
    /// The stored turns it was read from (live text follows exactly this many).
    var turnCount = 0
    /// M5: the web pages the conversation's web tools returned (WebSearch, WebFetch, the `url`
    /// of list_study_items' verified further reading; no other tool's result, so a link in a
    /// mail or a slide is never a source), by `CitationCheck.normalized` key → the https URL as
    /// the result wrote it: a `[[web …]]` marker shows only for one of these and opens that URL.
    var webPages: [String: URL] = [:]
    /// ma: what each of the student's messages carried besides its words (an `app` conversation's
    /// context, its label and glyph, the files), by the message's turn.
    var contexts: [AgentTurn.ID: AgentTurnContext] = [:]
    /// ma: when each of the student's messages was stored.
    var times: [AgentTurn.ID: Date] = [:]

    init() {}

    init(turns: [AgentTurn]) {
        turnCount = turns.count
        var answerID: AgentTurn.ID?
        var answer: [String] = []
        func flush() {
            if let answerID, !answer.isEmpty { entries.append(.answer(id: answerID, text: answer.joined(separator: "\n\n"))) }
            answerID = nil
            answer = []
        }
        /// tool_use id → the tool's bare name (the CLI's `mcp__studyportal__` prefix removed).
        var toolNames: [String: String] = [:]
        for turn in turns {
            guard let message = try? MessageParam(json: JSONValue.parse(turn.message)) else { continue }
            let blocks = message.content.blocks
            for block in blocks {
                switch block {
                case .toolUse(let use):
                    toolNames[use.id] = Self.bareName(use.name)
                case .serverToolUse(let use):
                    toolNames[use.id] = use.name
                case .toolResult(let result):
                    switch toolNames[result.toolUseID] {
                    case Self.webSearch?, Self.webFetch?:
                        webPages.merge(CitationCheck.webPages(in: block.json), uniquingKeysWith: { first, _ in first })
                    case Self.studyItems?:
                        webPages.merge(CitationCheck.webPages(in: block.json, urlFieldsOnly: true), uniquingKeysWith: { first, _ in first })
                    default:
                        break
                    }
                case .other where block.type == "web_search_tool_result" || block.type == "web_fetch_tool_result":
                    // The API's server web tools.
                    webPages.merge(CitationCheck.webPages(in: block.json), uniquingKeysWith: { first, _ in first })
                default:
                    break
                }
            }
            switch turn.role {
            case .user:
                // The student's words are the last text block; context blocks (and the results of
                // calls a stopped run left open) come before them. A turn of tool results only
                // belongs to the answer being written. ma: files may go without words.
                let words = blocks.last(where: { $0.textValue.map { !Self.isContextBlock($0) } ?? false })?.textValue
                let files = turn.context?.attachments ?? []
                guard words != nil || !files.isEmpty else { continue }
                flush()
                entries.append(.student(id: turn.id, text: words ?? ""))
                if let context = turn.context { contexts[turn.id] = context }
                times[turn.id] = turn.createdAt
            default:
                let text = blocks.compactMap(\.textValue)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                guard !text.isEmpty else { continue }
                if answerID == nil { answerID = turn.id }
                answer.append(text)
            }
        }
        flush()
    }

    /// The tools whose results name citable web pages.
    static let webSearch = "WebSearch"
    static let webFetch = "WebFetch"
    static let studyItems = "list_study_items"

    static func bareName(_ name: String) -> String {
        name.hasPrefix(ClaudeCodeConfiguration.toolNamePrefix) ? String(name.dropFirst(ClaudeCodeConfiguration.toolNamePrefix.count)) : name
    }

    /// A block the app put before the student's words (`<context …>`, `<catalog …>`,
    /// `<task_result …>`, `<memory>`, `<mail …>`), never shown as the student's message.
    static func isContextBlock(_ text: String) -> Bool {
        let head = text.prefix(16).trimmingCharacters(in: .whitespacesAndNewlines)
        return ["<context", "<catalog", "<task_result", "<memory", "<mail"].contains { head.hasPrefix($0) }
    }

    /// The student's last message has no answer yet.
    var awaitsAnswer: Bool {
        if case .student = entries.last { return true }
        return false
    }
}
