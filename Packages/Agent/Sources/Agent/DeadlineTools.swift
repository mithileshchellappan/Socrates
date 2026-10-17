import ClaudeKit
import Deadlines
import Foundation
import StudyCore

/// The `deadlines` conversation (what the student tells the agent in Calendar's composer): Haiku
/// 5.5, effort medium, at most 4,000 output tokens and 6 calls per run, adaptive thinking. Its
/// tools read the student's courses, sessions and items, write items through the deadline memory
/// (as `chat` sources quoting the student's words; a date goes into the calendar on its own only
/// when `DateMentions` finds it in those words), and stage session changes as proposals. No
/// delete, mail, web or send tool; nothing in it reads untrusted content.
enum DeadlineTools {
    static let model: ClaudeModel = .haiku55
    static let effort: Effort = .medium
    static let maxTokens = 4_000
    static let maxIterations = 6

    static func spec(services: StudyServices, memory: DeadlineMemory) throws -> ConversationSpec {
        let tools = Tools(services: services, memory: memory)
        return ConversationSpec(
            kind: .deadlines, model: model, effort: effort, maxTokens: maxTokens, maxIterations: maxIterations,
            thinking: .adaptive,
            tools: try ToolSet(kind: .deadlines, tools: [
                tools.listCourses, tools.listSessions, tools.findItems, tools.addItem, tools.updateItem, tools.completeItem,
                tools.proposeSessionChange,
            ]),
            system: { startedAt, courses in system(startedAt: startedAt, courses: courses.tokens) }
        )
    }

    static func system(startedAt: Date, courses: CourseTokens) -> String {
        """
        You keep the deadline and exercise list of a university student at \
        Example University. The student tells you about deadlines, exercise sheets, exams, \
        events and changes to their classes in a few words; you record them with the tools.

        Today is \(AgentDates.spoken(startedAt)) in Exampleton (Europe/Lisbon). Dates you write are Exampleton \
        time: "YYYY-MM-DDTHH:MM", or "YYYY-MM-DD" with all_day true when no time was given.

        The student's courses (token: name; lecturers):
        \(courses.promptLines)

        Rules:
        - Use the tools. Look before you write: prefer updating an existing item (find_items) over adding \
        a second one.
        - Never invent a date or a time the student did not give. Resolve relative dates ("next Tuesday", \
        "nächsten Freitag") against today.
        - Kinds: exercise (sheets, assignments), exam, deadline (anything else to submit, register for or \
        do by a date), event (a dated meeting that is not due work), announcement (no date to act on).
        - A room change or a cancelled class is a proposal the student confirms: find the session with \
        list_sessions and use propose_session_change.
        - Titles are short and English or as the student wrote them ("DC sheet 1", "Seminar registration").
        - Reply with one short line.
        """
    }

    struct Tools {
        let services: StudyServices
        let memory: DeadlineMemory
        let timeZone = AgentDates.timeZone

        var database: any DatabaseWriter { services.database }

        // MARK: Read

        var listCourses: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "list_courses", description: "The student's courses with their tokens and lecturers.",
                    inputSchema: Self.object([:])
                ),
                effect: .read
            ) { _, _ in
                let courses = try await CourseTokens.load(database)
                return .json(.array(courses.entries.map { entry in
                    [
                        "token": .string(entry.token), "name": .string(entry.course.name),
                        "lecturers": .array(entry.course.professors.map(JSONValue.string)),
                    ]
                }))
            }
        }

        var listSessions: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "list_sessions",
                    description: "The class sessions (lectures, exercises, tutorials, seminars) between two days, with their ids. Use it to find the session a room change or cancellation is about.",
                    inputSchema: Self.object([
                        "from": ["type": "string", "description": "First day, YYYY-MM-DD."],
                        "to": ["type": "string", "description": "Last day, YYYY-MM-DD."],
                        "course": Self.nullable(["type": "string", "description": "Course token; null for all courses."]),
                    ])
                ),
                effect: .read
            ) { call, context in
                let courses = try await CourseTokens.load(database)
                let today = CalendarDay(context.now, in: timeZone)
                let first = call.string("from").flatMap(CalendarDay.init(rawValue:)) ?? today
                let last = call.string("to").flatMap(CalendarDay.init(rawValue:)) ?? first.adding(days: 7)
                guard first.days(to: last) <= 62 else { return .error("At most 62 days at a time.") }
                let from = first.start(in: timeZone)
                let until = last.adding(days: 1).start(in: timeZone)
                let courseID = courses.course(call.string("course"))?.id
                if call.string("course") != nil, courseID == nil { return .error("Unknown course. Use a token from list_courses.") }
                let sessions = try await database.read { db in
                    try LectureSession
                        .where { $0.startsAt.gte(from) && $0.startsAt.lt(until) }
                        .order(by: \.startsAt)
                        .fetchAll(db)
                }
                return .json(.array(sessions.filter { courseID == nil || $0.courseID == courseID }.prefix(80).map { session in
                    [
                        "id": .string(session.id.uuidString.lowercased()),
                        "course": courses.token(for: session.courseID).map(JSONValue.string) ?? .null,
                        "kind": .string(session.kind.rawValue),
                        "starts": .string(AgentDates.text(session.startsAt, allDay: false) ?? ""),
                        "ends": .string(AgentDates.text(session.endsAt, allDay: false) ?? ""),
                        "room": .string(session.room),
                        "cancelled": .bool(session.isCancelled),
                    ]
                }))
            }
        }

        var findItems: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "find_items",
                    description: "Searches the student's tracked deadlines, exercises, exams, events and announcements.",
                    inputSchema: Self.object([
                        "query": Self.nullable(["type": "string", "description": "Words of the title; null for all."]),
                        "course": Self.nullable(["type": "string", "description": "Course token; null for all."]),
                        "from": Self.nullable(["type": "string", "description": "Due on or after this day, YYYY-MM-DD."]),
                        "to": Self.nullable(["type": "string", "description": "Due on or before this day, YYYY-MM-DD."]),
                        "include_closed": ["type": "boolean", "description": "Also done and dismissed items."],
                    ])
                ),
                effect: .read
            ) { call, _ in
                let courses = try await CourseTokens.load(database)
                let courseID = courses.course(call.string("course"))?.id
                if call.string("course") != nil, courseID == nil { return .error("Unknown course. Use a token from list_courses.") }
                let from = call.string("from").flatMap(CalendarDay.init(rawValue:))?.start(in: timeZone)
                let until = call.string("to").flatMap(CalendarDay.init(rawValue:))?.adding(days: 1).start(in: timeZone)
                let includeClosed = call.bool("include_closed") ?? false
                let query = Set(TextFolding.words(call.string("query") ?? ""))
                let items = try await database.read { db in try TrackedItem.order(by: \.dueAt).fetchAll(db) }
                let found = items.filter { item in
                    if !includeClosed, item.status != .open { return false }
                    if let courseID, item.courseID != courseID { return false }
                    if let from, (item.dueAt ?? .distantPast) < from { return false }
                    if let until, (item.dueAt ?? .distantFuture) >= until { return false }
                    if !query.isEmpty, query.isDisjoint(with: TextFolding.words(item.title + " " + item.details)) { return false }
                    return true
                }
                return .json(.array(found.prefix(40).map { Self.json($0, courses: courses) }))
            }
        }

        // MARK: Write

        var addItem: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "add_item",
                    description: "Adds a deadline, exercise, exam, event or announcement the student told you about. Look with find_items first; update instead of adding a second item.",
                    inputSchema: Self.object([
                        "kind": ["type": "string", "enum": ["deadline", "exercise", "exam", "event", "announcement"]],
                        "title": ["type": "string", "description": "Short title, at most 8 words."],
                        "course": Self.nullable(["type": "string", "description": "Course token."]),
                        "due": Self.nullable(["type": "string", "description": "YYYY-MM-DDTHH:MM or YYYY-MM-DD; null for announcements."]),
                        "all_day": ["type": "boolean"],
                        "details": Self.nullable(["type": "string", "description": "At most 12 words on why it matters."]),
                        "relevance": Self.nullable(["type": "string", "enum": ["exam_admission", "bonus"]]),
                        "session": Self.nullable(["type": "string", "description": "Id of the session it is tied to (list_sessions)."]),
                    ])
                ),
                effect: .write
            ) { call, context in
                let courses = try await CourseTokens.load(database)
                let kind = TrackedItemKind(rawValue: call.string("kind") ?? "deadline")
                guard [.deadline, .exercise, .exam, .event, .announcement].contains(kind) else { return .error("Unknown kind.") }
                guard let title = call.string("title") else { return .error("A title is needed.") }
                if call.string("course") != nil, courses.course(call.string("course")) == nil {
                    return .error("Unknown course. Use a token from list_courses.")
                }
                var draft = DeadlineDraft(
                    kind: kind, title: title, details: Self.details(call.string("details")),
                    courseID: courses.course(call.string("course"))?.id,
                    relevance: call.string("relevance").map(ItemRelevance.init(rawValue:)),
                    lectureSessionID: call.string("session").flatMap(UUID.init(uuidString:))
                )
                var verified = false
                if let text = call.string("due") {
                    guard let due = AgentDates.parse(text, allDay: call.bool("all_day") ?? false) else {
                        return .error("due must be YYYY-MM-DDTHH:MM or YYYY-MM-DD.")
                    }
                    let checked = AgentDates.verify(due, in: context.studentText, reference: context.now)
                    draft.dueAt = checked.date
                    draft.isAllDay = checked.allDay
                    verified = checked.verified
                } else if kind != .announcement {
                    return .error("A \(kind.rawValue) needs a due date; use announcement when there is none.")
                }
                let result = try await memory.record(Self.finding(draft, context: context, verified: verified))
                return .json(Self.json(result.item, courses: courses, extra: ["created": .bool(result.created)]))
            }
        }

        var updateItem: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "update_item",
                    description: "Changes an item's title, due date or details (the student can undo it). Null leaves a field as it is.",
                    inputSchema: Self.object([
                        "item": ["type": "string", "description": "Item id (find_items)."],
                        "title": Self.nullable(["type": "string"]),
                        "due": Self.nullable(["type": "string", "description": "YYYY-MM-DDTHH:MM or YYYY-MM-DD."]),
                        "all_day": Self.nullable(["type": "boolean"]),
                        "details": Self.nullable(["type": "string"]),
                    ])
                ),
                effect: .write
            ) { call, context in
                let courses = try await CourseTokens.load(database)
                guard let id = call.string("item").flatMap(UUID.init(uuidString:)),
                      let item = try await services.records.fetch(TrackedItem.self, id: id)
                else { return .error("Unknown item. Use an id from find_items.") }
                guard !item.kind.isSessionProposal else { return .error("Proposals cannot be edited.") }
                var draft = DeadlineDraft(
                    kind: item.kind, title: call.string("title") ?? item.title, details: call.string("details").map(Self.details) ?? item.details,
                    courseID: item.courseID, dueAt: item.dueAt, isAllDay: item.isAllDay, relevance: item.relevance, room: item.room,
                    lectureSessionID: item.lectureSessionID
                )
                var verified = false
                if let text = call.string("due") {
                    guard let due = AgentDates.parse(text, allDay: call.bool("all_day") ?? false) else {
                        return .error("due must be YYYY-MM-DDTHH:MM or YYYY-MM-DD.")
                    }
                    let checked = AgentDates.verify(due, in: context.studentText, reference: context.now)
                    draft.dueAt = checked.date
                    draft.isAllDay = checked.allDay
                    verified = checked.verified
                } else if let allDay = call.bool("all_day"), allDay, let due = item.dueAt {
                    draft.dueAt = CalendarDay(due, in: timeZone).start(in: timeZone)
                    draft.isAllDay = true
                    verified = true
                }
                guard let updated = try await memory.update(id, to: draft, by: Self.finding(draft, context: context, verified: verified)) else {
                    return .error("Unknown item.")
                }
                return .json(Self.json(updated, courses: courses))
            }
        }

        var completeItem: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "complete_item", description: "Marks an item as done (the student can undo it).",
                    inputSchema: Self.object(["item": ["type": "string", "description": "Item id (find_items)."]])
                ),
                effect: .write
            ) { call, context in
                let courses = try await CourseTokens.load(database)
                guard let id = call.string("item").flatMap(UUID.init(uuidString:)),
                      let item = try await services.records.fetch(TrackedItem.self, id: id)
                else { return .error("Unknown item. Use an id from find_items.") }
                let draft = DeadlineDraft(kind: item.kind, title: item.title, courseID: item.courseID, dueAt: item.dueAt, isAllDay: item.isAllDay)
                guard let done = try await memory.complete(id, by: Self.finding(draft, context: context, verified: false)) else {
                    return .error("Unknown item.")
                }
                return .json(Self.json(done, courses: courses))
            }
        }

        // MARK: Stage

        var proposeSessionChange: AgentTool {
            AgentTool(
                tool: .custom(
                    name: "propose_session_change",
                    description: "Proposes moving one session to another room, or cancelling it. The student confirms or discards the proposal in Calendar; nothing changes until then.",
                    inputSchema: Self.object([
                        "session": ["type": "string", "description": "Session id (list_sessions)."],
                        "room": Self.nullable(["type": "string", "description": "The new room; null when cancelling."]),
                        "cancel": ["type": "boolean"],
                    ])
                ),
                effect: .stage
            ) { call, context in
                let courses = try await CourseTokens.load(database)
                guard let id = call.string("session").flatMap(UUID.init(uuidString:)),
                      let session = try await services.records.fetch(LectureSession.self, id: id)
                else { return .error("Unknown session. Use an id from list_sessions.") }
                guard !session.isCancelled else { return .error("That session is already cancelled.") }
                let cancel = call.bool("cancel") ?? false
                let room = call.string("room")
                if !cancel {
                    guard let room else { return .error("A room is needed unless the session is cancelled.") }
                    guard TextFolding.fold(room) != TextFolding.fold(session.room) else { return .error("The session is in that room already.") }
                }
                let draft = DeadlineDraft(
                    kind: cancel ? .cancellation : .roomChange, title: cancel ? "Cancel session" : "Move to \(room ?? "")?",
                    courseID: session.courseID, dueAt: session.startsAt, room: cancel ? nil : room, lectureSessionID: session.id
                )
                let result = try await memory.record(Self.finding(draft, context: context, verified: false))
                guard result.item.kind.isSessionProposal else { return .error("No proposal could be made for that session.") }
                return .json(Self.json(result.item, courses: courses, extra: ["proposal": true]))
            }
        }

        // MARK: Helpers

        static func finding(_ draft: DeadlineDraft, context: ToolContext, verified: Bool) -> ItemFinding {
            ItemFinding(
                draft: draft, source: .chat(context.conversationID), quote: context.studentText, confidence: 1,
                dateVerified: verified, trusted: true, createdBy: .agent
            )
        }

        static func details(_ text: String?) -> String {
            (text ?? "").split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
        }

        static func json(_ item: TrackedItem, courses: CourseTokens, extra: JSONObject = [:]) -> JSONValue {
            var object: JSONObject = [
                "id": .string(item.id.uuidString.lowercased()),
                "kind": .string(item.kind.rawValue),
                "title": .string(item.title),
                "course": courses.token(for: item.courseID).map(JSONValue.string) ?? .null,
                "due": AgentDates.text(item.dueAt, allDay: item.isAllDay).map(JSONValue.string) ?? .null,
                "all_day": .bool(item.isAllDay),
                "status": .string(item.status.rawValue),
                "in_calendar": .bool(item.inCalendar),
                "details": .string(item.details),
                "relevance": item.relevance.map { .string($0.rawValue) } ?? .null,
                "session": item.lectureSessionID.map { .string($0.uuidString.lowercased()) } ?? .null,
            ]
            for (key, value) in extra { object[key] = value }
            return .object(object)
        }

        /// A closed object schema with every property required (optional values are nullable), as
        /// strict tool inputs want.
        static func object(_ properties: JSONObject) -> JSONValue {
            [
                "type": "object",
                "additionalProperties": false,
                "required": .array(properties.keys.sorted().map(JSONValue.string)),
                "properties": .object(properties),
            ]
        }

        static func nullable(_ schema: JSONValue) -> JSONValue {
            ["anyOf": [schema, ["type": "null"]]]
        }
    }
}
