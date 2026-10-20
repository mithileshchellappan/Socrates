import Agent
import ClaudeKit
import Deadlines
import Foundation
import StudyCore

/// mr (docs/plan-actions.md §4 "The action registry"): one of the app agent's writes, registered
/// once with what `find_actions` matches and shows and the handler that runs it. The handler is the
/// direct tool's own (`AgentTool.handler`, unchanged): `run_action` builds the same call the direct
/// tool would get (its parameters plus `quote`, `source`, `source_id`), so the quote checks, the
/// change log row and its Undo are the tool's.
///
/// Adding an action is one registration in `ActionRegistry.app` (an `AgentTool` + summary,
/// keywords, sources, `studentOnly`, `undo`).
public struct AgentAction: Sendable {
    /// How the action's change is undone.
    public enum Undo: String, Sendable, Hashable {
        /// Its `agent_change` row's Undo (`ChangeLog.undo`: undo_change, the panel's change row).
        case changeLog = "change_log"
        /// The `agent_task` it queued is cancelled (cancel_task).
        case cancelTask = "cancel_task"
    }

    /// snake_case, the direct tool's name ("change_session").
    public let name: String
    /// One line, at most 100 characters.
    public let summary: String
    /// English and German words a request might use ("room", "Raum", "slides", "Folien").
    public let keywords: [String]
    /// The tool's input schema without `quote`, `source` and `source_id` (`run_action` adds them),
    /// with the tool's description as the schema's `description`.
    public let parameters: JSONValue
    /// What its quote may be: `chat`, `mail`, `lecture`, `event`.
    public let sources: [String]
    /// Only the student's own words ask for it (`source: chat` at any time).
    public let studentOnly: Bool
    public let undo: Undo
    public let handler: AgentTool.Handler

    /// Folded once for `ActionRegistry.find`.
    let nameParts: [String]
    let foldedKeywords: [String]
    let summaryWords: Set<String>

    init(_ tool: AgentTool, summary: String, keywords: [String], sources: [String], studentOnly: Bool, undo: Undo = .changeLog) {
        name = tool.name
        self.summary = summary
        self.keywords = keywords
        parameters = Self.parameters(of: tool.tool)
        self.sources = sources
        self.studentOnly = studentOnly
        self.undo = undo
        handler = tool.handler
        nameParts = tool.name.split(separator: "_").map(String.init)
        foldedKeywords = keywords.map { TextFolding.fold($0) }
        summaryWords = Set(TextFolding.words(summary))
    }

    /// The sources `run_action` takes now: `sources`, only `chat` once the run has read untrusted
    /// content (mail, a document, a web task's result), as `ActionRegistry.run` checks; find_actions
    /// lists these, so the model never tries a mail quote it would refuse.
    public func sources(readUntrusted: Bool) -> [String] {
        readUntrusted ? sources.filter { $0 == "chat" } : sources
    }

    /// The keys `run_action` takes at its top level (they win over the same keys in `params`).
    static let sourceKeys: Set<String> = ["quote", "source", "source_id"]

    /// The tool's input schema without the source keys, its description as the schema's own.
    static func parameters(of tool: Tool) -> JSONValue {
        guard case .custom(let custom) = tool, var schema = custom.inputSchema.objectValue else { return Schema.object([:]) }
        if var properties = schema["properties"]?.objectValue {
            for key in sourceKeys { properties[key] = nil }
            schema["properties"] = .object(properties)
        }
        if let required = schema["required"]?.arrayValue {
            let kept: [JSONValue] = required.filter { value in !sourceKeys.contains(value.stringValue ?? "") }
            schema["required"] = .array(kept)
        }
        let description = custom.description.split(whereSeparator: \.isNewline).joined(separator: " ")
        schema["description"] = .string(description)
        return .object(schema)
    }

    /// `find`'s score of the query's words: 3 per word equal to a part of the name, 2 per word
    /// that hits a keyword (equal, or a shared prefix of at least 5 letters), 1 per word of the
    /// summary.
    func score(_ words: [String]) -> Int {
        var score = 0
        for word in words {
            if nameParts.contains(word) { score += 3 }
            if foldedKeywords.contains(where: { Self.hits(word, $0) }) { score += 2 }
            if summaryWords.contains(word) { score += 1 }
        }
        return score
    }

    static func hits(_ word: String, _ keyword: String) -> Bool {
        if word == keyword { return true }
        var shared = 0
        for (left, right) in zip(word, keyword) {
            guard left == right else { break }
            shared += 1
            if shared >= 5 { return true }
        }
        return false
    }
}

/// Why a registry was refused.
public enum ActionRegistryError: Error, Hashable, CustomStringConvertible {
    case notSnakeCase(String)
    case duplicateName(String)

    public var description: String {
        switch self {
        case .notSnakeCase(let name): "the action name \(name) is not snake_case"
        case .duplicateName(let name): "two actions are called \(name)"
        }
    }
}

/// mr: the app agent's registered writes (`find_actions` / `run_action`). Deterministic, no model:
/// `find` is a keyword match, `run` calls the action's handler (callable without a model too:
/// menus later).
public struct ActionRegistry: Sendable {
    /// In registration order (ties of `find` go to the earlier).
    public let actions: [AgentAction]
    private let positions: [String: Int]

    public init(_ actions: [AgentAction]) throws {
        var positions: [String: Int] = [:]
        for (offset, action) in actions.enumerated() {
            guard Self.isSnakeCase(action.name) else { throw ActionRegistryError.notSnakeCase(action.name) }
            guard positions.updateValue(offset, forKey: action.name) == nil else { throw ActionRegistryError.duplicateName(action.name) }
        }
        self.actions = actions
        self.positions = positions
    }

    public var count: Int { actions.count }

    public func action(named name: String) -> AgentAction? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return positions[key].map { actions[$0] }
    }

    /// The best `limit` (1…8) actions for `query` with a score above 0, best first, ties in
    /// registry order. Empty: nothing matched.
    public func find(_ query: String, limit: Int = 4) -> [AgentAction] {
        let words = Self.queryWords(query)
        guard !words.isEmpty else { return [] }
        var scored: [(score: Int, position: Int)] = []
        for (position, action) in actions.enumerated() {
            let score = action.score(words)
            if score > 0 { scored.append((score, position)) }
        }
        scored.sort { lhs, rhs in lhs.score != rhs.score ? lhs.score > rhs.score : lhs.position < rhs.position }
        let count = min(max(limit, 1), 8)
        return scored.prefix(count).map { actions[$0.position] }
    }

    /// Runs `name` with `params` as its direct tool would run: the handler gets
    /// `params + quote + source + source_id` (the top-level values win) and the same context, and
    /// its output is returned as it is. Refused: an unknown name, `params` not an object, a source
    /// the action does not take, any source but chat once the run has read untrusted content
    /// (mail, a document, a web task's result), and any source but chat for a student-only action.
    public func run(
        name: String, params: JSONValue?, quote: String?, source: String?, sourceID: String?, context: ToolContext,
        callID: String = "run_action"
    ) async throws -> ToolOutput {
        guard let action = action(named: name) else {
            return .error("No action is called \(name). Use find_actions with a few words to find it.")
        }
        var input: JSONObject
        switch params {
        case .object(let object)?: input = object
        case .null?, nil: input = [:]
        default: return .error("params must be an object of \(action.name)'s parameters (find_actions shows them).")
        }
        let source = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if context.trace.hasReadUntrustedContent, source != "chat" {
            return .error(
                "This conversation read mail, a document or a web result, so run_action takes only source chat: quote = the student's own words asking for it (at least 3 words, a date in them when the action needs one). If their message lacks them, ask the student to say what to change."
            )
        }
        if action.studentOnly, source != "chat" {
            return .error("\(action.name) runs only when the student asks: source chat, quote = their words asking for it (at least 3 words).")
        }
        guard action.sources.contains(source) else {
            return .error("source must be \(action.sources.joined(separator: " or ")) for \(action.name).")
        }
        let quoteValue: JSONValue = quote.map(JSONValue.string) ?? .null
        let sourceIDValue: JSONValue = sourceID.map(JSONValue.string) ?? .null
        input["quote"] = quoteValue
        input["source"] = .string(source)
        input["source_id"] = sourceIDValue
        let call = ToolUseBlock(id: callID, name: action.name, input: .object(input))
        return try await action.handler(call, context)
    }

    // MARK: - Matching

    /// Function words a query's words never match on.
    static let stopwords: Set<String> = [
        "a", "an", "the", "of", "for", "on", "in", "at", "to", "by", "and", "or", "is", "are", "it", "its", "this", "that", "with",
        "from", "as", "be", "my", "me", "please", "der", "die", "das", "des", "dem", "den", "ein", "eine", "einen", "zur", "zum", "im",
        "am", "fur", "und", "oder", "von", "mit", "ist", "mein", "meine", "ich", "bitte",
    ]

    /// The query folded (`TextFolding`) and split into words, function words and repeats left out.
    static func queryWords(_ query: String) -> [String] {
        var seen: Set<String> = []
        var words: [String] = []
        for word in TextFolding.words(query) where word.count >= 2 && !stopwords.contains(word) {
            if seen.insert(word).inserted { words.append(word) }
        }
        return words
    }

    static func isSnakeCase(_ name: String) -> Bool {
        guard let first = name.first, first.isASCII, first.isLowercase, !name.hasSuffix("_"), !name.contains("__") else { return false }
        return name.allSatisfy { character in
            character == "_" || (character.isASCII && (character.isLowercase || character.isNumber))
        }
    }
}

extension ActionRegistry {
    /// The `app` conversation's actions (docs/plan-actions.md §4 "Registered"): 22, 21 without the
    /// document bank (`keep_document`). Their tools are the instances `AppAgentChat.spec` builds
    /// for its direct writes (the student's words and mail are sources).
    public static func app(_ deps: AppAgentChat.Services) throws -> ActionRegistry {
        let writes = WriteTools(services: deps.services, changeLog: deps.changeLog, chatSource: true, mailSource: true)
        let plan = PlanTools(services: deps.services, changeLog: deps.changeLog, coach: deps.coach, writes: writes)
        let delegate = DelegateTools(services: deps.services)
        let documents = deps.documentTools
        let any = writes.sources
        let chat = ["chat"]
        var actions: [AgentAction] = [
            AgentAction(
                writes.addItem, summary: "Adds a deadline, exercise, exam, event, task or announcement.",
                keywords: [
                    "add", "new", "deadline", "Abgabe", "Frist", "exercise", "Übung", "Übungsblatt", "sheet", "homework", "assignment",
                    "exam", "Klausur", "Prüfung", "task", "todo", "Aufgabe", "event", "Termin", "announcement", "Ankündigung",
                ],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.moveItem, summary: "Moves an item (a deadline, an exam, a task) to another date.",
                keywords: [
                    "move", "postpone", "postponed", "reschedule", "extend", "extension", "verschieben", "verschoben", "Verlängerung",
                    "deadline", "Frist", "due", "date", "Datum", "later", "earlier", "später",
                ],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.completeItem, summary: "Marks an item as done.",
                keywords: ["done", "finished", "complete", "completed", "submitted", "erledigt", "fertig", "abgegeben", "tick"],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.updateItem, summary: "Changes an item's title, details or room.",
                keywords: ["rename", "title", "Titel", "details", "room", "Raum", "update", "change", "ändern", "edit", "item"],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.setReminder, summary: "Schedules a notification on the student's Mac at a time.",
                keywords: ["remind", "reminder", "notification", "notify", "alert", "Erinnerung", "erinnern", "Benachrichtigung"],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.appendNote, summary: "Appends text to one of the student's notes, or starts a new note.",
                keywords: ["note", "notes", "Notiz", "Notizen", "write", "append", "aufschreiben", "Mitschrift", "jot"],
                sources: chat, studentOnly: false
            ),
            AgentAction(
                writes.undoChange, summary: "Undoes one change of the activity log.",
                keywords: ["undo", "revert", "rückgängig", "zurück", "wrong", "falsch", "mistake", "Fehler"],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                writes.changeSession, summary: "Changes one class session: another room, time or day, cancelled, or restored.",
                keywords: [
                    "session", "Sitzung", "class", "lecture", "Vorlesung", "room", "Raum", "moved", "verlegt", "cancel", "cancelled",
                    "entfällt", "ausfallen", "fällt", "time", "Uhrzeit", "restore", "Termin",
                ],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.addSession, summary: "Adds a one-off session (a block lecture, a make-up date).",
                keywords: [
                    "extra", "additional", "zusätzlich", "block", "Blockveranstaltung", "makeup", "Nachholtermin", "Ersatztermin",
                    "session", "Sitzung", "Termin",
                ],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.setCourseFact, summary: "Records a course rule (exam admission, exam form, bonus, attendance…) or its lecturers.",
                keywords: [
                    "rule", "Regel", "admission", "Zulassung", "Klausurzulassung", "Prüfungsform", "bonus", "attendance",
                    "Anwesenheit", "Anwesenheitspflicht", "lecturer", "lecturers", "Dozent", "professor", "fact",
                ],
                sources: any, studentOnly: false
            ),
            AgentAction(
                writes.removeCourse, summary: "Removes a course with its lectures, slides, sessions and items.",
                keywords: ["remove", "delete", "drop", "löschen", "entfernen", "course", "Kurs", "Veranstaltung", "Modul"],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                writes.addCourse, summary: "Creates a new course (then its weekly classes with add_weekly_slot).",
                keywords: ["course", "Kurs", "new", "neu", "create", "anlegen", "Veranstaltung", "Modul", "module", "enrol"],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                writes.addWeeklySlot, summary: "Adds a course's weekly class (lecture, exercise, tutorial, seminar) to the timetable.",
                keywords: [
                    "weekly", "wöchentlich", "class", "timetable", "Stundenplan", "slot", "tutorial", "Tutorium", "exercise", "Übung",
                    "seminar", "lecture", "Vorlesung", "add",
                ],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                writes.changeWeeklySlot, summary: "Changes a weekly class: its day, time, room, kind, rhythm or period.",
                keywords: [
                    "weekly", "wöchentlich", "timetable", "Stundenplan", "slot", "moves", "verlegt", "room", "Raum", "time", "Zeit",
                    "weekday", "Wochentag", "change", "ändern", "class",
                ],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                writes.removeWeeklySlot, summary: "Removes a weekly class and its future sessions.",
                keywords: ["weekly", "wöchentlich", "timetable", "Stundenplan", "slot", "remove", "entfernen", "löschen", "drop", "class"],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                plan.planAdjust, summary: "Changes the study plan: skip, daily cap, exam sitting, seminar hours, attend, move a block.",
                keywords: [
                    "plan", "Lernplan", "study", "lernen", "skip", "überspringen", "cap", "limit", "minutes", "sitting", "Klausurtermin",
                    "seminar", "attend", "besuchen", "block", "schedule",
                ],
                sources: chat, studentOnly: false
            ),
            AgentAction(
                plan.markAwayDays, summary: "Marks days the student is away (travelling, at home): lighter study on them.",
                keywords: ["away", "travel", "travelling", "trip", "holiday", "home", "weg", "reisen", "Reise", "unterwegs", "Urlaub", "abwesend"],
                sources: chat, studentOnly: false
            ),
            AgentAction(
                plan.setCourseCredits, summary: "Records a course's credits (ECTS / LP) and/or its self-study hours.",
                keywords: [
                    "credits", "ECTS", "LP", "Leistungspunkte", "Kreditpunkte", "workload", "Arbeitsaufwand", "selfstudy", "Selbststudium",
                    "hours", "Stunden",
                ],
                sources: any, studentOnly: false
            ),
        ]
        if documents.bank != nil {
            actions.append(AgentAction(
                documents.keepDocument, summary: "Keeps a file attached to the message in the student's Documents.",
                keywords: ["keep", "save", "store", "speichern", "behalten", "ablegen", "document", "Dokument", "file", "Datei"],
                sources: chat, studentOnly: true
            ))
        }
        actions += [
            AgentAction(
                delegate.rerunStudyPass, summary: "Runs a lecture's study pass again in the background.",
                keywords: ["study", "pass", "again", "rerun", "redo", "regenerate", "nochmal", "erneut", "summary", "Zusammenfassung"],
                sources: chat, studentOnly: true, undo: .cancelTask
            ),
            AgentAction(
                writes.linkDeckPages, summary: "Links pages of a course's slide deck to a lecture (one PDF shared by several lectures).",
                keywords: [
                    "slides", "Folien", "Foliensatz", "deck", "pdf", "pages", "Seiten", "link", "assign", "zuordnen", "range",
                    "continue", "continued", "Fortsetzung", "same", "gleichen",
                ],
                sources: chat, studentOnly: true
            ),
            AgentAction(
                writes.unlinkDeck, summary: "Removes a slide deck from a lecture (the deck stays for its other lectures).",
                keywords: ["slides", "Folien", "deck", "pdf", "unlink", "remove", "entfernen", "wrong", "falsch", "detach"],
                sources: chat, studentOnly: true
            ),
        ]
        return try ActionRegistry(actions)
    }

    /// How many actions `app` registers (the catalog's "actions" line).
    static func appCount(documents: Bool) -> Int { documents ? 22 : 21 }
}
