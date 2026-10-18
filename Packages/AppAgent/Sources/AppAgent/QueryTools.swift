import Agent
import ClaudeKit
import Deadlines
import Foundation
import Search
import StudyCore

/// The app agent's read tools beyond the lecture tools (Tutor) and the mail tools
/// (MailIntelligence): the notes, items, sessions, the app's calendar rows, the memory, the
/// activity log and the tasks. Trusted library content (effect `.read`); item titles a mail or a
/// lecture wrote come back as `untrusted_title` without details. Every result ≤ 4,000 characters.
struct QueryTools: Sendable {
    let services: StudyServices
    let search: SearchEngine

    var database: any DatabaseWriter { services.database }
    var timeZone: TimeZone { AppAgentModule.timeZone }

    // MARK: Notes

    var searchNotes: AgentTool {
        AgentTool(
            tool: .custom(
                name: "search_notes",
                description: "Searches the student's own notes (words and meaning). Returns note ids, titles and the matching text.",
                inputSchema: Schema.object([
                    "query": Schema.string("Search words (German and English)."),
                    "course": Schema.optionalString("Course token; null for all."),
                ])
            ),
            effect: .read
        ) { call, _ in
            guard let query = call.text("query") else { return .error("query is empty.") }
            let courses = try await CourseList.load(database)
            let courseID = courses.course(call.text("course"))?.id
            let results = try await search.search(SearchQuery(query, scope: .notes, courseID: courseID, limit: 12), semanticWait: .seconds(2))
            let rows: [JSONValue] = results.groups.flatMap(\.hits).compactMap { hit in
                guard let noteID = hit.noteID else { return nil }
                return [
                    "note": .string(noteID.uuidString.lowercased()),
                    "title": ToolJSON.string(hit.title),
                    "course": ToolJSON.string(courses.token(for: hit.courseID)),
                    "cite": ToolJSON.string(hit.lectureID.flatMap { lectureID in
                        hit.page.map { ChatCitation.slide(lectureID, page: $0).marker }
                    }),
                    "text": .string(ToolJSON.clip(hit.text.isEmpty ? String(hit.snippet.characters) : hit.text, 300)),
                ]
            }
            return ToolJSON.fitted(["query": .string(query)], key: "notes", rows: rows)
        }
    }

    var readNote: AgentTool {
        AgentTool(
            tool: .custom(
                name: "read_note",
                description: "Reads one of the student's notes as plain text (its title, anchor and text).",
                inputSchema: Schema.object(["note": Schema.string("The note's id (search_notes, the context).")])
            ),
            effect: .read
        ) { call, _ in
            guard let id = call.id("note"), let note = try await services.records.fetch(Note.self, id: id) else {
                return .error("Unknown note. Use an id from search_notes.")
            }
            let courses = try await CourseList.load(database)
            let blocks = (try? NoteBlock.decode(note.blocksJSON)) ?? []
            var object: JSONObject = [
                "note": .string(note.id.uuidString.lowercased()),
                "title": .string(ChangeLog.noteTitle(blocks)),
                "course": ToolJSON.string(courses.token(for: note.courseID)),
                "updated": ToolJSON.string(AgentText.iso(note.updatedAt)),
                "text": .string(String(NoteBlock.plainText(of: blocks).prefix(3_000))),
            ]
            if let lectureID = note.lectureID {
                object["lecture"] = .string(ChatCitation.key(lectureID))
                if let page = note.pageNumber { object["cite"] = .string(ChatCitation.slide(lectureID, page: page).marker) }
            }
            return ToolJSON.object(object)
        }
    }

    // MARK: Items

    var queryItems: AgentTool {
        AgentTool(
            tool: .custom(
                name: "query_items",
                description: "The student's deadlines, exercises, exams, events, tasks and announcements, filtered. Returns ids for the write tools.",
                inputSchema: Schema.object([
                    "query": Schema.optionalString("Words of the title; null for all."),
                    "course": Schema.optionalString("Course token; null for all."),
                    "kind": Schema.nullable(Schema.stringEnum(["deadline", "exercise", "exam", "event", "task", "announcement"])),
                    "from": Schema.optionalString("Due on or after this day, YYYY-MM-DD."),
                    "to": Schema.optionalString("Due on or before this day, YYYY-MM-DD."),
                    "include_closed": ["type": "boolean", "description": "Also done and dismissed items."],
                ])
            ),
            effect: .read
        ) { call, _ in
            let courses = try await CourseList.load(database)
            let courseID = courses.course(call.text("course"))?.id
            if call.text("course") != nil, courseID == nil { return .error("Unknown course token.") }
            let from = call.text("from").flatMap(CalendarDay.init(rawValue:))?.start(in: timeZone)
            let until = call.text("to").flatMap(CalendarDay.init(rawValue:))?.adding(days: 1).start(in: timeZone)
            let kind = call.text("kind").map(TrackedItemKind.init(rawValue:))
            let includeClosed = call.flag("include_closed") ?? false
            let words = Set(TextFolding.words(call.text("query") ?? ""))
            let items = try await database.read { db in try TrackedItem.order(by: \.dueAt).fetchAll(db) }.filter { item in
                if item.kind.isSessionProposal || item.kind.isSessionChange { return false }
                if !includeClosed, item.status != .open { return false }
                if let courseID, item.courseID != courseID { return false }
                if let kind, item.kind != kind { return false }
                if let from, (item.dueAt ?? .distantPast) < from { return false }
                if let until, (item.dueAt ?? .distantFuture) >= until { return false }
                if !words.isEmpty, words.isDisjoint(with: TextFolding.words(item.title + " " + item.details)) { return false }
                return true
            }
            let listed = Array(items.prefix(40))
            let untrusted = try await AgentToolSupport.untrustedItems(listed.map(\.id), services: services)
            return ToolJSON.fitted([:], key: "items", rows: listed.map { Self.itemJSON($0, courses: courses, untrusted: untrusted.contains($0.id)) })
        }
    }

    static func itemJSON(_ item: TrackedItem, courses: CourseList, untrusted: Bool) -> JSONValue {
        var object: JSONObject = [
            "id": .string(item.id.uuidString.lowercased()),
            "kind": .string(item.kind.rawValue),
            (untrusted ? "untrusted_title" : "title"): .string(item.title),
            "course": ToolJSON.string(courses.token(for: item.courseID)),
            "due": ToolJSON.string(AgentText.iso(item.dueAt, allDay: item.isAllDay)),
            "status": .string(item.status.rawValue),
            "in_calendar": .bool(item.inCalendar),
            "by": .string(item.createdBy.rawValue),
        ]
        if let relevance = item.relevance { object["relevance"] = .string(relevance.rawValue) }
        if let session = item.lectureSessionID { object["session"] = .string(session.uuidString.lowercased()) }
        if !untrusted, !item.details.isEmpty { object["details"] = .string(item.details) }
        return .object(object)
    }

    // MARK: Sessions

    var querySessions: AgentTool {
        AgentTool(
            tool: .custom(
                name: "query_sessions",
                description: "The class sessions (lectures, exercises, tutorials, seminars) between two days, with ids, rooms, cancellations and the changes applied to them.",
                inputSchema: Schema.object([
                    "from": Schema.string("First day, YYYY-MM-DD."),
                    "to": Schema.string("Last day, YYYY-MM-DD (at most 62 days after from)."),
                    "course": Schema.optionalString("Course token; null for all."),
                ])
            ),
            effect: .read
        ) { call, context in
            let courses = try await CourseList.load(database)
            let today = CalendarDay(context.now, in: timeZone)
            let first = call.text("from").flatMap(CalendarDay.init(rawValue:)) ?? today
            let last = call.text("to").flatMap(CalendarDay.init(rawValue:)) ?? first.adding(days: 7)
            guard first.days(to: last) <= 62 else { return .error("At most 62 days at a time.") }
            let courseID = courses.course(call.text("course"))?.id
            if call.text("course") != nil, courseID == nil { return .error("Unknown course token.") }
            let from = first.start(in: timeZone)
            let until = last.adding(days: 1).start(in: timeZone)
            let rows = try await database.read { db in
                (
                    sessions: try LectureSession.where { $0.startsAt.gte(from) && $0.startsAt.lt(until) }.order(by: \.startsAt).fetchAll(db),
                    changes: try AgentChange
                        .where { $0.targetTable.eq(AgentChangeTarget.session) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) }
                        .fetchAll(db)
                )
            }
            let changes = Dictionary(grouping: rows.changes.compactMap { change in change.targetID.map { ($0, change) } }, by: \.0)
            let listed = rows.sessions.filter { courseID == nil || $0.courseID == courseID }.prefix(80)
            return ToolJSON.fitted([:], key: "sessions", rows: listed.map { session in
                var object: JSONObject = [
                    "id": .string(session.id.uuidString.lowercased()),
                    "course": ToolJSON.string(courses.token(for: session.courseID)),
                    "kind": .string(session.kind.rawValue),
                    "starts": ToolJSON.string(AgentText.iso(session.startsAt)),
                    "ends": ToolJSON.string(AgentText.iso(session.endsAt)),
                    "room": .string(session.room),
                    "cancelled": .bool(session.isCancelled),
                ]
                if let number = session.number { object["number"] = .int(number) }
                if let applied = changes[session.id]?.map(\.1), !applied.isEmpty {
                    object["changes"] = .array(applied.map { .string("\($0.summary) \($0.citation.marker)") })
                }
                return .object(object)
            })
        }
    }

    var queryCalendar: AgentTool {
        AgentTool(
            tool: .custom(
                name: "query_calendar",
                description: "What the app's own \"Study Portal\" calendar shows between two days: the sessions of courses shown in the calendar, the items in the calendar, and the agent's reminders. Other calendars are not read.",
                inputSchema: Schema.object([
                    "from": Schema.string("First day, YYYY-MM-DD."),
                    "to": Schema.string("Last day, YYYY-MM-DD (at most 62 days after from)."),
                ])
            ),
            effect: .read
        ) { call, context in
            let courses = try await CourseList.load(database)
            let today = CalendarDay(context.now, in: timeZone)
            let first = call.text("from").flatMap(CalendarDay.init(rawValue:)) ?? today
            let last = call.text("to").flatMap(CalendarDay.init(rawValue:)) ?? first.adding(days: 7)
            guard first.days(to: last) <= 62 else { return .error("At most 62 days at a time.") }
            let from = first.start(in: timeZone)
            let until = last.adding(days: 1).start(in: timeZone)
            let rows = try await database.read { db in
                (
                    shown: Set(try Course.where { $0.showsInCalendar }.fetchAll(db).map(\.id)),
                    sessions: try LectureSession.where { $0.startsAt.gte(from) && $0.startsAt.lt(until) && !$0.isCancelled }.order(by: \.startsAt).fetchAll(db),
                    items: try TrackedItem.where { $0.inCalendar && $0.dueAt.gte(Date?.some(from)) && $0.dueAt.lt(Date?.some(until)) }.fetchAll(db),
                    reminders: try AgentReminder.where { $0.fireAt.gte(from) && $0.fireAt.lt(until) && $0.cancelledAt.is(nil) }.fetchAll(db)
                )
            }
            var entries: [(Date, JSONValue)] = []
            for session in rows.sessions where rows.shown.contains(session.courseID) {
                entries.append((session.startsAt, [
                    "session": .string(session.id.uuidString.lowercased()), "course": ToolJSON.string(courses.token(for: session.courseID)),
                    "kind": .string(session.kind.rawValue), "starts": ToolJSON.string(AgentText.iso(session.startsAt)),
                    "ends": ToolJSON.string(AgentText.iso(session.endsAt)), "room": .string(session.room),
                ]))
            }
            let untrusted = try await AgentToolSupport.untrustedItems(rows.items.map(\.id), services: services)
            for item in rows.items where item.status == .open {
                entries.append((item.dueAt ?? from, Self.itemJSON(item, courses: courses, untrusted: untrusted.contains(item.id))))
            }
            for reminder in rows.reminders {
                entries.append((reminder.fireAt, [
                    "reminder": .string(reminder.id.uuidString.lowercased()), "title": .string(reminder.title),
                    "at": ToolJSON.string(AgentText.iso(reminder.fireAt)), "delivered": .bool(reminder.deliveredAt != nil),
                ]))
            }
            return ToolJSON.fitted([:], key: "entries", rows: entries.sorted { $0.0 < $1.0 }.map(\.1))
        }
    }

    // MARK: Memory, log, tasks

    var queryMemory: AgentTool {
        AgentTool(
            tool: .custom(
                name: "query_memory",
                description: "What the agent keeps about the student (their facts, preferences, course notes), with ids.",
                inputSchema: Schema.object([:])
            ),
            effect: .read
        ) { _, _ in
            let courses = try await CourseList.load(database)
            let memories = try await AgentMemoryRepository(store: services.records).active()
            return ToolJSON.fitted([:], key: "memories", rows: memories.map { memory in
                [
                    "id": .string(ChatCitation.key(memory.id)), "kind": .string(memory.kind.rawValue),
                    "course": ToolJSON.string(courses.token(for: memory.courseID)), "text": .string(memory.text),
                ]
            })
        }
    }

    var listChanges: AgentTool {
        AgentTool(
            tool: .custom(
                name: "list_changes",
                description: """
                    The changes the agent made to the student's data on its own (the activity log), newest first, each \
                    with its cite marker [[change 1a2b3c4d]]. Use it for "what did you change?"; put each row's marker \
                    in the answer.
                    """,
                inputSchema: Schema.object([
                    "since": Schema.optionalString("Changes on or after this day, YYYY-MM-DD; null for the last 7 days."),
                    "limit": Schema.nullable(["type": "integer", "description": "At most this many, 1 to 40 (default 20)."]),
                ])
            ),
            effect: .read
        ) { call, context in
            let since = call.text("since").flatMap(CalendarDay.init(rawValue:))?.start(in: timeZone) ?? context.now.addingTimeInterval(-7 * 86_400)
            let limit = min(max(call.integer("limit") ?? 20, 1), 40)
            let changes = try await AgentChangeRepository(store: services.records).recent(since: since, limit: limit)
            return ToolJSON.fitted([:], key: "changes", rows: changes.map { change in
                var object: JSONObject = [
                    "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary),
                    "source": .string(change.sourceKind.rawValue), "at": ToolJSON.string(AgentText.iso(change.appliedAt)),
                    "by": .string(change.model.isEmpty ? "code" : change.model),
                ]
                if change.undoneAt != nil { object["undone"] = .bool(true) }
                if change.supersededBy != nil { object["superseded"] = .bool(true) }
                return .object(object)
            })
        }
    }

    var checkTasks: AgentTool {
        AgentTool(
            tool: .custom(
                name: "check_tasks",
                description: "The sub-agent tasks: those queued or running, and the ones this conversation spawned with their results.",
                inputSchema: Schema.object([:])
            ),
            effect: .read
        ) { _, context in
            let repository = AgentTaskRepository(store: services.records)
            let open = try await repository.open()
            let own = try await repository.tasks(parent: context.conversationID).filter { !$0.state.isOpen }
            let rows: [JSONValue] = (open + own.suffix(6)).map { task in
                var object: JSONObject = [
                    "task": .string(task.id.uuidString.lowercased()), "title": .string(task.title), "state": .string(task.state.rawValue),
                    "kind": .string(task.kind.rawValue),
                ]
                if let result = task.result { object["result"] = .string(ToolJSON.clip(result, 1_200)) }
                if let error = task.error { object["error"] = .string(error) }
                if let until = task.pausedUntil { object["paused_until"] = ToolJSON.string(AgentText.iso(until)) }
                return .object(object)
            }
            return ToolJSON.fitted([:], key: "tasks", rows: rows)
        }
    }
}
