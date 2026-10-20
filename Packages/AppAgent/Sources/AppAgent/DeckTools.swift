import Agent
import ClaudeKit
import Foundation
import StudyCore

/// mr (docs/plan-actions.md §4): a course's slide deck shared by its lectures, each with its own
/// page range (the PDF is never cut or copied). `link_deck_pages` and `unlink_deck` are registered
/// actions only (`run_action`), student-only (quote: their words asking, verified like
/// remove_course's), each through the change log (`ChangeLog.Request.deckLink` / `.deckUnlink` →
/// `LectureSlides`, one transaction with its `deck_link` / `deck_unlink` row and Undo).
extension WriteTools {
    static let deckDescription =
        "The deck: its key from the catalog (the 8 hex of [deck 1a2b3c4d]), its id, or a lecture (\"DC 2\", its key) meaning that lecture's slides."

    var linkDeckPages: AgentTool {
        AgentTool(
            tool: .custom(
                name: "link_deck_pages",
                description: """
                    Gives a lecture pages of one of its course's slide decks, ONLY when the student asks (quote: their \
                    words asking): the lecture then shows, aligns and cites those pages (deck page numbers: slide 38 stays \
                    S38). Other lectures keep their own ranges of the deck; the lecture's earlier range of it is replaced. \
                    Undo puts it back.
                    """,
                inputSchema: Schema.object([
                    "lecture": Schema.string("The lecture: its key, \"DC 2\" or id."),
                    "deck": Schema.string(Self.deckDescription),
                    "first_page": Schema.nullable(["type": "integer", "description": "First deck page (1-based); null: 1."]),
                    "last_page": Schema.nullable(["type": "integer", "description": "Last deck page; null: the deck's last."]),
                    "quote": quoteProperty,
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await studentAsked(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            guard let reference = call.text("lecture"), let lectureID = try await WriteToolsLookup.lectureID(reference, services: services) else {
                return .error("Unknown lecture. Use list_lectures.")
            }
            guard let deck = try await deckNamed(call.text("deck")) else {
                return .error("Unknown deck. Use a [deck 1a2b3c4d] key from the catalog, or a lecture whose slides it is.")
            }
            let first = call.integer("first_page") ?? 1
            let last = call.integer("last_page") ?? deck.pageCount
            let request = ChangeLog.Request.deckLink(lectureID: lectureID, deckID: deck.id, firstPage: first, lastPage: last)
            return try await deckOutput(applyAsked(request, checked: checked, context: context))
        }
    }

    var unlinkDeck: AgentTool {
        AgentTool(
            tool: .custom(
                name: "unlink_deck",
                description: """
                    Takes a slide deck away from a lecture, ONLY when the student asks (quote: their words asking): the \
                    deck stays in the course and with its other lectures. Undo links it again with its range.
                    """,
                inputSchema: Schema.object([
                    "lecture": Schema.string("The lecture: its key, \"DC 2\" or id."),
                    "deck": Schema.string(Self.deckDescription),
                    "quote": quoteProperty,
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await studentAsked(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            guard let reference = call.text("lecture"), let lectureID = try await WriteToolsLookup.lectureID(reference, services: services) else {
                return .error("Unknown lecture. Use list_lectures.")
            }
            guard let deck = try await deckNamed(call.text("deck")) else {
                return .error("Unknown deck. Use a [deck 1a2b3c4d] key from the catalog, or a lecture whose slides it is.")
            }
            let request = ChangeLog.Request.deckUnlink(lectureID: lectureID, deckID: deck.id)
            return try await deckOutput(applyAsked(request, checked: checked, context: context))
        }
    }

    func deckOutput(_ outcome: ChangeLog.Outcome) -> ToolOutput {
        switch outcome {
        case .applied(let change):
            return .json(["applied": true, "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary)])
        case .unchanged(let text):
            return .json(["applied": false, "note": .string(text)])
        case .conflict(let text), .refused(let text):
            return .error(text)
        }
    }

    /// The deck a reference names: the catalog's `[deck 1a2b3c4d]` key (or its 8 hex), a deck id,
    /// or a lecture reference meaning that lecture's current slides (`LectureSlides.current`).
    func deckNamed(_ reference: String?) async throws -> Deck? {
        guard var text = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if text.hasPrefix("[deck "), text.hasSuffix("]") {
            text = String(text.dropFirst("[deck ".count).dropLast()).trimmingCharacters(in: .whitespaces)
        } else if text.lowercased().hasPrefix("deck ") {
            text = String(text.dropFirst("deck ".count)).trimmingCharacters(in: .whitespaces)
        }
        if let id = UUID(uuidString: text), let deck = try await services.records.fetch(Deck.self, id: id) { return deck }
        let key = text.lowercased()
        if key.count == 8, key.allSatisfy(\.isHexDigit) {
            let ids = try await services.database.read { db in
                try String.fetchAll(db, sql: #"SELECT "id" FROM "deck" WHERE "id" LIKE ? LIMIT 2"#, arguments: [key + "%"])
            }
            if ids.count == 1, let id = UUID(uuidString: ids[0]), let deck = try await services.records.fetch(Deck.self, id: id) { return deck }
        }
        guard let lectureID = try await WriteToolsLookup.lectureID(text, services: services),
              let range = try await LectureSlides.current(lectureID: lectureID, database: services.database)
        else { return nil }
        return try await services.records.fetch(Deck.self, id: range.deckID)
    }
}
