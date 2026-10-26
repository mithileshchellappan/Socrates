import ClaudeKit
import Foundation
import StudyCore

/// The conversation as the chat shows it: the student's messages and the agent's answers. One
/// answer block is all the agent wrote between two messages of the student (its text blocks
/// across the tool loop's calls, `answerText`); thinking, tool calls, tool results and the
/// `<mail>` context blocks are not shown.
struct ChatTranscript: Equatable {
    enum Entry: Identifiable, Equatable {
        case student(id: AgentTurn.ID, text: String)
        /// The texts of the assistant turns after a message, in order (shown by `answerText`).
        case answer(id: AgentTurn.ID, parts: [AnswerPart])

        var id: AgentTurn.ID {
            switch self {
            case .student(let id, _), .answer(let id, _): id
            }
        }
    }

    var entries: [Entry] = []
    /// The stored turns it was read from (live text follows exactly this many).
    var turnCount = 0
    /// Where each of the student's messages is among the stored turns (its index): text written
    /// after `n` stored turns answers the last message before index `n`.
    var positions: [AgentTurn.ID: Int] = [:]
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

    /// - Parameter cache: the turns parsed before (a thread keeps one across observations, so
    ///   each new turn is parsed once; turns are append-only).
    init(turns: [AgentTurn], cache: ChatTurnCache = ChatTurnCache()) {
        turnCount = turns.count
        var answerID: AgentTurn.ID?
        var answer: [AnswerPart] = []
        func flush() {
            if let answerID, !answer.isEmpty { entries.append(.answer(id: answerID, parts: answer)) }
            answerID = nil
            answer = []
        }
        for (index, turn) in turns.enumerated() {
            guard let digest = cache.digest(turn) else { continue }
            webPages.merge(digest.webPages, uniquingKeysWith: { first, _ in first })
            switch turn.role {
            case .user:
                // A turn of tool results only belongs to the answer being written. ma: files may go
                // without words.
                let files = turn.context?.attachments ?? []
                guard digest.words != nil || !files.isEmpty else { continue }
                flush()
                entries.append(.student(id: turn.id, text: digest.words ?? ""))
                positions[turn.id] = index
                if let context = turn.context { contexts[turn.id] = context }
                times[turn.id] = turn.createdAt
            default:
                guard !digest.text.isEmpty else { continue }
                if answerID == nil { answerID = turn.id }
                answer.append(AnswerPart(text: digest.text, hasToolUse: digest.hasToolUse))
            }
        }
        flush()
    }

    /// One assistant turn's text in an answer.
    struct AnswerPart: Equatable, Sendable {
        var text: String
        var hasToolUse: Bool
    }

    /// An answer as the thread shows it: its stored parts without the narration before tool calls
    /// ("Let me check your calendar."), then `following` (text written after them that no stored
    /// turn holds: a stopped run's, the live text). A tool-use turn's text is narration when it is
    /// one line under 160 characters without a marker and the text after it (later parts and
    /// `following`) is longer: a change marker or a short fact before a `remember` call stays,
    /// and the rule reads the same while the answer streams and once it is stored (the text above
    /// never jumps when the final turn lands). Nil: nothing to show.
    static func answerText(_ parts: [AnswerPart], following: [String] = []) -> String? {
        let extra = following.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        // The length of the text after each part.
        var after = Array(repeating: 0, count: parts.count)
        var total = extra.reduce(0) { $0 + $1.count }
        for index in parts.indices.reversed() {
            after[index] = total
            total += parts[index].text.count
        }
        var kept: [String] = []
        for index in parts.indices {
            let part = parts[index]
            let isNarration = part.hasToolUse && !part.text.contains("\n") && part.text.count < 160 && !part.text.contains("[[")
                && after[index] > part.text.count
            if !isNarration { kept.append(part.text) }
        }
        kept += extra
        return kept.isEmpty ? nil : kept.joined(separator: "\n\n")
    }

    /// The tools whose results name citable web pages.
    static let webSearch = "WebSearch"
    static let webFetch = "WebFetch"
    static let studyItems = "list_study_items"

    static func bareName(_ name: String) -> String {
        name.hasPrefix(ClaudeCodeConfiguration.toolNamePrefix) ? String(name.dropFirst(ClaudeCodeConfiguration.toolNamePrefix.count)) : name
    }

    /// A block the app put before the student's words (`<context …>`, `<catalog …>`,
    /// `<task_result …>`, `<memory>`, `<mail …>`, `<filed …>` for slides filed from the message,
    /// `<attached_file …>` for a long PDF's first pages, mc's `<reminder …>`, the runtime's clock
    /// `<now>`), or Try again's `<retry>` turn: never shown as the student's message (a message of
    /// files alone shows only its tiles; a turn of tool results, the clock and `<retry>` belongs to
    /// the answer).
    static func isContextBlock(_ text: String) -> Bool {
        let head = text.prefix(16).trimmingCharacters(in: .whitespacesAndNewlines)
        return [
            "<context", "<catalog", "<task_result", "<memory", "<mail", "<filed", "<reminder", "<attached_file", "<retry",
            ClaudeCodeConfiguration.clockTag,
        ]
        .contains { head.hasPrefix($0) }
    }

    /// The student's last message has no answer yet.
    var awaitsAnswer: Bool {
        if case .student = entries.last { return true }
        return false
    }
}

/// What the chat shows of one stored turn, read once.
struct ChatTurnDigest: Equatable, Sendable {
    /// A user turn's words: its last text block that is not a context block (context blocks and
    /// the results of calls a stopped run left open come before them).
    var words: String?
    /// Another turn's text blocks, trimmed and joined.
    var text: String
    /// The web pages its web tools' results name (`ChatTranscript.webPages`).
    var webPages: [String: URL]
    /// An assistant turn that calls tools (its text, if any, came before the calls).
    var hasToolUse = false
}

/// Turns parsed before, by id: a thread keeps one, so a new turn (a background task's loop, the
/// next answer) parses only itself instead of every turn again on the main thread (a turn with
/// a 20 MB attachment takes about 13 ms). Stored turns never change (append-only), so a digest
/// stays right; only small digests are kept, never the messages.
final class ChatTurnCache {
    private var digests: [AgentTurn.ID: ChatTurnDigest?] = [:]
    /// tool_use id → the tool's bare name (the CLI's `mcp__studyportal__` prefix removed), from
    /// the turns read so far (a result follows its call's turn).
    private var toolNames: [String: String] = [:]

    init() {}

    /// The turn's digest; nil for one that cannot be read. Read the turns in order.
    func digest(_ turn: AgentTurn) -> ChatTurnDigest? {
        if let known = digests[turn.id] { return known }
        let digest = read(turn)
        digests[turn.id] = digest
        return digest
    }

    private func read(_ turn: AgentTurn) -> ChatTurnDigest? {
        guard let message = try? MessageParam(json: JSONValue.parse(turn.message)) else { return nil }
        let blocks = message.content.blocks
        var webPages: [String: URL] = [:]
        for block in blocks {
            switch block {
            case .toolUse(let use):
                toolNames[use.id] = ChatTranscript.bareName(use.name)
            case .serverToolUse(let use):
                toolNames[use.id] = use.name
            case .toolResult(let result):
                switch toolNames[result.toolUseID] {
                case ChatTranscript.webSearch?, ChatTranscript.webFetch?:
                    webPages.merge(CitationCheck.webPages(in: block.json), uniquingKeysWith: { first, _ in first })
                case ChatTranscript.studyItems?:
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
            let words = blocks.last(where: { $0.textValue.map { !ChatTranscript.isContextBlock($0) } ?? false })?.textValue
            return ChatTurnDigest(words: words, text: "", webPages: webPages)
        default:
            let text = blocks.compactMap(\.textValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            let hasToolUse = blocks.contains { block in
                if case .toolUse = block { return true }
                if case .serverToolUse = block { return true }
                return false
            }
            return ChatTurnDigest(words: nil, text: text, webPages: webPages, hasToolUse: hasToolUse)
        }
    }
}
