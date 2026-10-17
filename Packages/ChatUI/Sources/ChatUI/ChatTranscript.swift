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
        for turn in turns {
            guard let message = try? MessageParam(json: JSONValue.parse(turn.message)) else { continue }
            let blocks = message.content.blocks
            switch turn.role {
            case .user:
                // The student's words are the last text block; context blocks (and the results of
                // calls a stopped run left open) come before them. A turn of tool results only
                // belongs to the answer being written.
                guard let words = blocks.last(where: { $0.textValue != nil })?.textValue else { continue }
                flush()
                entries.append(.student(id: turn.id, text: words))
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

    /// The student's last message has no answer yet.
    var awaitsAnswer: Bool {
        if case .student = entries.last { return true }
        return false
    }
}
