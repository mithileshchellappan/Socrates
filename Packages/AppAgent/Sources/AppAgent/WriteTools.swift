import Agent
import ClaudeKit
import Deadlines
import Foundation
import MailIntelligence
import StudyCore

/// The app agent's verified writes (docs/plan-agent.md §4 "Tools of app", "Verified writes"):
/// every one goes through the change log (one transaction with its `agent_change` row, Undo), and
/// every one carries a quote that code checks against its source:
/// - `chat`: an exact span (≥ 3 words) of the student's message being answered;
/// - `mail`: an exact span of that mail (`QuoteVerifier`, outside text that talks to a model);
/// - `lecture`: an exact span of the lecture's transcript, with its first word's time;
/// - `event`: the source of a triage event (an escalation task's).
/// Dates must be in the quote (`DateMentions`). All are `.verifiedWrite`, so they may sit beside
/// the mail tools (`ToolSet` refuses plain `.write`). No send, no delete, no other calendars.
/// Why a write was refused (the model sees the message).
struct Refusal: Error, ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    var message: String
    init(_ message: String) { self.message = message }
    init(stringLiteral value: String) { message = value }
}

struct WriteTools: Sendable {
    let services: StudyServices
    let changeLog: ChangeLog
    /// Whether the student's words are a source (the `app` conversation; a task has none).
    let chatSource: Bool
    /// Whether mail is a source (the conversation has the mail tools).
    let mailSource: Bool

    var applier: FactApplier { FactApplier(services: services) }

    // MARK: Sources

    var sources: [String] {
        var values: [String] = []
        if chatSource { values.append("chat") }
        if mailSource { values.append("mail") }
        values += ["lecture", "event"]
        return values
    }

    var sourceProperties: JSONObject {
        [
            "quote": Schema.string("The exact words of the source that state it (copied character for character; for chat: the student's words in the message you are answering, at least 3 words)."),
            "source": Schema.stringEnum(sources),
            "source_id": Schema.optionalString("mail: the mail's id; lecture: the lecture's key or id; event: the event's id; null for chat."),
        ]
    }

    /// The checked quote of a write, or why not.
    func verified(_ call: ToolUseBlock, context: ToolContext) async throws -> Result<VerifiedQuote, Refusal> {
        guard let quote = call.text("quote") else { return .failure("quote is empty.") }
        let source = call.text("source") ?? (chatSource ? "chat" : "")
        switch source {
        case "chat" where chatSource:
            guard let checked = try await applier.verify(quote, line: nil, material: .chat(context.conversationID, words: context.studentText, date: context.now)) else {
                return .failure("For source chat, quote must be at least 3 words of the student's message you are answering, copied exactly.")
            }
            return .success(checked)
        case "mail" where mailSource:
            guard let id = call.id("source_id") else { return .failure("source_id must be the mail's id.") }
            guard let checked = try await applier.verify(quote, line: nil, material: .mail(id, writtenAt: context.now)) else {
                return .failure("The quote is not in that mail (or lies in text that talks to a model). Copy the mail's words exactly.")
            }
            return .success(checked)
        case "lecture":
            guard let reference = call.text("source_id"), let lectureID = try await lectureID(reference) else {
                return .failure("source_id must be the lecture's key or id.")
            }
            guard let found = try await LectureQuote.locate(quote, lectureID: lectureID, services: services) else {
                return .failure("The quote is not in that lecture's transcript. Copy its words exactly (read_transcript_span).")
            }
            return .success(found)
        case "event":
            guard let id = call.id("source_id"), let event = try await services.records.fetch(AgentEvent.self, id: id) else {
                return .failure("source_id must be the event's id.")
            }
            return try await verifyEvent(quote, event: event)
        default:
            return .failure("source must be one of \(sources.joined(separator: ", ")).")
        }
    }

    func verifyEvent(_ quote: String, event: AgentEvent) async throws -> Result<VerifiedQuote, Refusal> {
        switch event.kind {
        case .mail:
            guard let id = event.mailMessageID, let checked = try await applier.verify(quote, line: nil, material: .mail(id, writtenAt: event.createdAt)) else {
                return .failure("The quote is not in the event's mail.")
            }
            return .success(checked)
        case .transcript, .studyPass:
            guard let lectureID = event.lectureID, let found = try await LectureQuote.locate(quote, lectureID: lectureID, services: services) else {
                return .failure("The quote is not in the lecture's transcript.")
            }
            return .success(found)
        default:
            let kind: SourceRef.Kind = event.kind == .timetable ? .timetable : .calendar
            guard let detail = event.detail,
                  let checked = try await applier.verify(quote, line: nil, material: .text(detail, kind: kind, reference: event.sourceKey, date: event.createdAt))
            else { return .failure("The quote is not in the event.") }
            return .success(checked)
        }
    }

    func lectureID(_ reference: String) async throws -> Lecture.ID? {
        if let id = UUID(uuidString: reference) { return id }
        let key = reference.lowercased().prefix(8)
        guard key.count == 8, key.allSatisfy(\.isHexDigit) else { return nil }
        return try await services.database.read { db in
            let ids = try String.fetchAll(db, sql: #"SELECT "id" FROM "lecture" WHERE "id" LIKE ? LIMIT 2"#, arguments: [String(key) + "%"])
            return ids.count == 1 ? UUID(uuidString: ids[0]) : nil
        }
    }

    /// Applies an action after its quote passed: through the applier's checks, then the log.
    func apply(_ action: FactAction, verified: VerifiedQuote, context: ToolContext, taskID: AgentTask.ID?, explicitSession: Bool) async throws -> ToolOutput {
        let request: ChangeLog.Request
        switch try await applier.request(action, verified: verified, explicitSession: explicitSession) {
        case .success(let value): request = value
        case .failure(let refusal): return .error(refusal.description)
        }
        // The panel's own changes are made in its conversation (the activity log names it).
        let origin = ChangeLog.Origin(
            source: verified.source, sourceDate: verified.reference, model: ClaudeModel.opus55.rawValue, taskID: taskID,
            conversationID: context.conversationID, trusted: verified.trusted
        )
        let outcome = try await changeLog.apply(request, quote: verified.quote, confidence: 1, origin: origin)
        switch outcome {
        case .applied(let change):
            return .json(["applied": true, "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary)])
        case .unchanged(let text):
            return .json(["applied": false, "note": .string(text)])
        case .conflict(let text), .refused(let text):
            return .error(text)
        }
    }

    func handle(_ call: ToolUseBlock, context: ToolContext, explicitSession: Bool = false, build: (ToolUseBlock, String) -> FactAction?) async throws -> ToolOutput {
        let checked: VerifiedQuote
        switch try await verified(call, context: context) {
        case .success(let value): checked = value
        case .failure(let refusal): return .error(refusal.message)
        }
        guard let action = build(call, checked.quote) else { return .error("Missing fields.") }
        let taskID = try await AgentTaskRepository(store: services.records).taskID(conversation: context.conversationID)
        return try await apply(action, verified: checked, context: context, taskID: taskID, explicitSession: explicitSession)
    }

    // MARK: Items

    var addItem: AgentTool {
        AgentTool(
            tool: .custom(
                name: "add_item",
                description: """
                    Adds a deadline, exercise, exam, event, task (something to do, with or without a date) or announcement \
                    the student asked for or a source states. Look with query_items first; never add an item twice. A date \
                    is kept only when the quote states it.
                    """,
                inputSchema: Schema.object(sourceProperties.merging([
                    "kind": Schema.stringEnum(["deadline", "exercise", "exam", "event", "task", "announcement"]),
                    "title": Schema.string("Short title, at most 8 words."),
                    "course": Schema.optionalString("Course token."),
                    "due": Schema.optionalString("YYYY-MM-DDTHH:MM or YYYY-MM-DD; null for tasks and announcements without a date."),
                    "all_day": ["type": "boolean"],
                    "details": Schema.optionalString("At most 12 words on why it matters."),
                    "relevance": Schema.nullable(Schema.stringEnum(["exam_admission", "bonus"])),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(
                    kind: AgentChangeKind.itemAdd.rawValue, course: call.text("course"), itemKind: call.text("kind"), title: call.text("title"),
                    details: call.text("details"), due: call.text("due"), allDay: call.flag("all_day"), relevance: call.text("relevance"),
                    quote: quote, confidence: 1
                )
            }
        }
    }

    var moveItem: AgentTool {
        AgentTool(
            tool: .custom(
                name: "move_item",
                description: "Moves an item to another date the quote states (Undo puts it back).",
                inputSchema: Schema.object(sourceProperties.merging([
                    "item": Schema.string("The item's id (query_items)."),
                    "due": Schema.string("YYYY-MM-DDTHH:MM or YYYY-MM-DD."),
                    "all_day": ["type": "boolean"],
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(kind: AgentChangeKind.itemMove.rawValue, item: call.text("item"), due: call.text("due"), allDay: call.flag("all_day"), quote: quote, confidence: 1)
            }
        }
    }

    var completeItem: AgentTool {
        AgentTool(
            tool: .custom(
                name: "complete_item",
                description: "Marks an item as done (Undo reopens it).",
                inputSchema: Schema.object(sourceProperties.merging(["item": Schema.string("The item's id (query_items).")]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(kind: AgentChangeKind.itemDone.rawValue, item: call.text("item"), quote: quote, confidence: 1)
            }
        }
    }

    var updateItem: AgentTool {
        AgentTool(
            tool: .custom(
                name: "update_item",
                description: "Changes an item's title, details or room (null leaves a field; Undo puts it back).",
                inputSchema: Schema.object(sourceProperties.merging([
                    "item": Schema.string("The item's id (query_items)."),
                    "title": Schema.optionalString("New title, at most 8 words."),
                    "details": Schema.optionalString("New details, at most 12 words."),
                    "room": Schema.optionalString("New room (events and exams)."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(
                    kind: AgentChangeKind.itemUpdate.rawValue, item: call.text("item"), title: call.text("title"), details: call.text("details"),
                    room: call.text("room"), quote: quote, confidence: 1
                )
            }
        }
    }

    // MARK: Sessions

    var changeSession: AgentTool {
        AgentTool(
            tool: .custom(
                name: "change_session",
                description: """
                    Changes one class session on its own (Undo puts it back): another room, another time or day, \
                    cancelled, or taking place after all (restore). Find it with query_sessions.
                    """,
                inputSchema: Schema.object(sourceProperties.merging([
                    "session": Schema.string("The session's id (query_sessions)."),
                    "change": Schema.stringEnum(["room", "time", "cancel", "restore"]),
                    "room": Schema.optionalString("The new room (room)."),
                    "starts_at": Schema.optionalString("The new start, YYYY-MM-DDTHH:MM (time)."),
                    "ends_at": Schema.optionalString("The new end, YYYY-MM-DDTHH:MM (time; null keeps the length)."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            let kind: AgentChangeKind? = switch call.text("change") {
            case "room": .sessionRoom
            case "time": .sessionTime
            case "cancel": .sessionCancel
            case "restore": .sessionRestore
            default: nil
            }
            guard let kind else { return .error("change must be room, time, cancel or restore.") }
            // The student naming the session (chat) is enough to find it; other sources must state its day.
            let explicit = call.text("source") == "chat" && chatSource
            return try await handle(call, context: context, explicitSession: explicit) { call, quote in
                FactAction(
                    kind: kind.rawValue, session: call.text("session"), startsAt: call.text("starts_at"), endsAt: call.text("ends_at"),
                    room: call.text("room"), quote: quote, confidence: 1
                )
            }
        }
    }

    var addSession: AgentTool {
        AgentTool(
            tool: .custom(
                name: "add_session",
                description: "Adds a one-off session a source announces (a block lecture, a make-up date). Undo cancels it.",
                inputSchema: Schema.object(sourceProperties.merging([
                    "course": Schema.string("Course token."),
                    "kind": Schema.stringEnum(["lecture", "exercise", "tutorial", "seminar"]),
                    "starts_at": Schema.string("YYYY-MM-DDTHH:MM."),
                    "ends_at": Schema.optionalString("YYYY-MM-DDTHH:MM; null for 90 minutes."),
                    "room": Schema.optionalString("Room."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(
                    kind: AgentChangeKind.sessionExtra.rawValue, course: call.text("course"), sessionKind: call.text("kind"),
                    startsAt: call.text("starts_at"), endsAt: call.text("ends_at"), room: call.text("room"), quote: quote, confidence: 1
                )
            }
        }
    }

    // MARK: Course facts, reminders

    var setCourseFact: AgentTool {
        AgentTool(
            tool: .custom(
                name: "set_course_fact",
                description: "Records a rule of a course (exam admission, exam form, bonus, exercises, attendance, other) or its lecturers, as the source states it.",
                inputSchema: Schema.object(sourceProperties.merging([
                    "course": Schema.string("Course token."),
                    "fact": Schema.stringEnum(["lecturers", "exam_admission", "exam_form", "bonus", "exercise", "attendance", "other"]),
                    "text": Schema.string("The rule in at most 20 words; for lecturers the names separated by \";\"."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(kind: AgentChangeKind.courseFact.rawValue, course: call.text("course"), fact: call.text("fact"), text: call.text("text"), quote: quote, confidence: 1)
            }
        }
    }

    var setReminder: AgentTool {
        AgentTool(
            tool: .custom(
                name: "set_reminder",
                description: "Schedules a notification on the student's Mac (an exam-admission quiz closing, a registration window). Undo cancels it.",
                inputSchema: Schema.object(sourceProperties.merging([
                    "item": Schema.optionalString("The item it is about (query_items)."),
                    "title": Schema.string("The notification's title: the item as Today names it."),
                    "body": Schema.string("e.g. \"Wed 21 Oct, 23:59 · Data Centers\"."),
                    "at": Schema.string("When, YYYY-MM-DDTHH:MM."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            try await handle(call, context: context) { call, quote in
                FactAction(
                    kind: AgentChangeKind.reminder.rawValue, item: call.text("item"), title: call.text("title"), due: call.text("at"),
                    text: call.text("body"), quote: quote, confidence: 1
                )
            }
        }
    }

    // MARK: Notes and Undo (the student's words only)

    var appendNote: AgentTool {
        AgentTool(
            tool: .custom(
                name: "append_note",
                description: """
                    Appends text to one of the student's notes, or starts a new note of a course or lecture, ONLY when the \
                    student's message asks you to (quote: their words asking for it). Never edits or removes what is there.
                    """,
                inputSchema: Schema.object([
                    "note": Schema.optionalString("The note's id; null for a new note."),
                    "course": Schema.optionalString("Course token, for a new note."),
                    "lecture": Schema.optionalString("Lecture key or id, for a new note of a lecture."),
                    "text": Schema.string("The text to append: plain paragraphs; lines starting with \"- \" become bullets."),
                    "quote": Schema.string("The student's words in the message you are answering that ask for it (at least 3 words)."),
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            guard chatSource else { return .error("Only the student can ask for notes.") }
            guard let quote = call.text("quote"),
                  let checked = try await applier.verify(quote, line: nil, material: .chat(context.conversationID, words: context.studentText, date: context.now))
            else { return .error("quote must be the student's words asking for the note (at least 3 words), copied exactly.") }
            guard let text = call.text("text") else { return .error("text is empty.") }
            let blocks: [NoteBlock] = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.map { line in
                line.hasPrefix("- ") ? NoteBlock(type: .bullet, text: String(line.dropFirst(2))) : .paragraph(line)
            }
            let courses = try await CourseList.load(services.database)
            var lectureID: Lecture.ID?
            if let reference = call.text("lecture") { lectureID = try await self.lectureID(reference) }
            let request = ChangeLog.Request.noteAppend(
                noteID: call.id("note"), courseID: courses.course(call.text("course"))?.id, lectureID: lectureID, blocks: blocks
            )
            let origin = ChangeLog.Origin(
                source: checked.source, sourceDate: context.now, model: ClaudeModel.opus55.rawValue, conversationID: context.conversationID
            )
            let outcome = try await changeLog.apply(request, quote: checked.quote, origin: origin)
            switch outcome {
            case .applied(let change): return .json(["applied": true, "cite": .string(change.citation.marker), "note": ToolJSON.id(change.targetID)])
            default: return .error(outcome.message)
            }
        }
    }

    var undoChange: AgentTool {
        AgentTool(
            tool: .custom(
                name: "undo_change",
                description: "Undoes one change of the activity log when the student asks for it (quote: their words asking).",
                inputSchema: Schema.object([
                    "change": Schema.string("The change's key: the 8 hex of its [[change 1a2b3c4d]] marker (list_changes)."),
                    "quote": Schema.string("The student's words in the message you are answering that ask for it (at least 3 words)."),
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            guard chatSource else { return .error("Only the student can undo changes.") }
            guard let quote = call.text("quote"),
                  try await applier.verify(quote, line: nil, material: .chat(context.conversationID, words: context.studentText, date: context.now)) != nil
            else { return .error("quote must be the student's words asking for it (at least 3 words), copied exactly.") }
            let key = (call.text("change") ?? "").replacingOccurrences(of: "[[change ", with: "").replacingOccurrences(of: "]]", with: "")
            guard let change = try await AgentChangeRepository(store: services.records).change(key: key) else {
                return .error("No change has that key. Use list_changes.")
            }
            guard change.undoneAt == nil else { return .json(["undone": true, "note": "It was undone already."]) }
            let undone = try await changeLog.undo(change.id)
            return .json(["undone": .bool(undone), "title": .string(change.title), "summary": .string(change.summary)])
        }
    }
}

extension AgentTaskRepository {
    /// The task whose own conversation this is (nil for the app agent's).
    func taskID(conversation: AgentConversation.ID) async throws -> AgentTask.ID? {
        try await store.database.read { db in
            try AgentTask.where { $0.conversationID.eq(AgentConversation.ID?.some(conversation)) }.select(\.id).fetchOne(db)
        }
    }
}

/// A quote in a lecture's transcript: the exact span of its lines (any recording of the lecture),
/// with the moment its first word is said.
enum LectureQuote {
    static func locate(_ quote: String, lectureID: Lecture.ID, services: StudyServices) async throws -> VerifiedQuote? {
        let cleaned = TranscriptQuote.cleaned(quote)
        guard cleaned.count >= 8 else { return nil }
        let rows = try await services.database.read { db in
            (
                lecture: try Lecture.find(lectureID).fetchOne(db),
                recordings: try Recording.where { $0.lectureID.eq(Lecture.ID?.some(lectureID)) }.order(by: \.startedAt).fetchAll(db),
                segments: try TranscriptSegment.where { $0.lectureID.eq(Lecture.ID?.some(lectureID)) }.order(by: \.startTime).fetchAll(db)
            )
        }
        guard let lecture = rows.lecture else { return nil }
        let byRecording = Dictionary(grouping: rows.segments, by: \.recordingID)
        for recording in rows.recordings {
            let lines = TranscriptCues.lines(byRecording[recording.id] ?? [])
            guard !lines.isEmpty else { continue }
            var text = ""
            var starts: [(index: Int, offset: String.Index)] = []
            for (index, line) in lines.enumerated() {
                if !text.isEmpty { text += " " }
                starts.append((index, text.endIndex))
                text += line.text
            }
            guard let span = NormalizedText(text).originalSpan(of: cleaned), span.count <= 400,
                  let first = starts.last(where: { $0.offset <= span.startIndex })
            else { continue }
            let offset = text.distance(from: first.offset, to: span.startIndex)
            let line = lines[first.index]
            let time = TranscriptQuote.time(at: offset, in: line.text, words: line.words) ?? line.start
            return VerifiedQuote(
                quote: String(span), source: .transcript(lectureID: lectureID, recordingID: recording.id, time: time),
                reference: lecture.heldAt ?? recording.startedAt, trusted: true
            )
        }
        return nil
    }
}
