import Agent
import ClaudeKit
import Courses
import Deadlines
import Filing
import Foundation
import StudyCore

/// The agent creates courses and their timetable (PRD "Manage it through the agent, not UI"):
/// add_course, add_weekly_slot, change_weekly_slot, remove_weekly_slot. Each only when the student
/// asks in chat (quote: their words asking, verified like remove_course's), each through the change
/// log in one transaction with its `agent_change` row and Undo, each through the app's own code: a
/// course as New Course… makes one (`CourseLibrary.insert`), a slot as Course Settings' Add Slot
/// saves one (`CourseSchedule.saveSlot` / `deleteSlot`: the sessions are planned, and the calendar
/// mirror writes them into the "Study Portal" calendar after the log's `onChange`).
extension WriteTools {
    static let weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]

    var quoteProperty: JSONValue {
        Schema.string("The student's words in the message you are answering that ask for it (at least 3 words).")
    }

    /// The student's words asking for a change (chat only), or why not.
    func studentAsked(_ call: ToolUseBlock, context: ToolContext) async throws -> Result<VerifiedQuote, Refusal> {
        guard chatSource else { return .failure("Only the student can ask for that.") }
        guard let quote = call.text("quote"),
              let checked = try await applier.verify(quote, line: nil, material: .chat(context.conversationID, words: context.studentText, date: context.now))
        else { return .failure("quote must be the student's words asking for it (at least 3 words), copied exactly.") }
        return .success(checked)
    }

    /// Applies a course or slot change the student asked for.
    func applyAsked(_ request: ChangeLog.Request, checked: VerifiedQuote, context: ToolContext) async throws -> ChangeLog.Outcome {
        let taskID = try await AgentTaskRepository(store: services.records).taskID(conversation: context.conversationID)
        let origin = ChangeLog.Origin(
            source: checked.source, sourceDate: context.now, model: ClaudeModel.opus55.rawValue, taskID: taskID,
            conversationID: context.conversationID
        )
        return try await changeLog.apply(request, quote: checked.quote, origin: origin)
    }

    // MARK: add_course

    var addCourse: AgentTool {
        AgentTool(
            tool: .custom(
                name: "add_course",
                description: """
                    Creates a course as New Course… does (the next colour, the current semester, mail rules for its \
                    lecturers; it shows in the sidebar), ONLY when the student's message asks you to (quote: their words \
                    asking). Then add its classes with add_weekly_slot. Recording stays off until the student turns it \
                    on. language: taught in (null: en); admin_language: its admin mail (null: de); in_calendar: its \
                    sessions in the Study Portal calendar (null: true). Undo removes it.
                    """,
                inputSchema: Schema.object([
                    "name": Schema.string("The course's full name."),
                    "short_name": Schema.optionalString("Its abbreviation, which becomes its token (\"DC\"); null: the initials of the name."),
                    "lecturers": Schema.optionalString("The lecturers, separated by \";\"; null when not known."),
                    "language": Schema.nullable(Schema.stringEnum(["en", "de"])),
                    "admin_language": Schema.nullable(Schema.stringEnum(["en", "de"])),
                    "credits": Schema.nullable(PlanTools.number),
                    "in_calendar": Schema.nullable(["type": "boolean"]),
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
            guard let name = call.text("name") else { return .error("name is empty.") }
            let courses = try await CourseList.load(services.database)
            let short = call.text("short_name")
            if let short, let other = courses.course(short) {
                return .error("\(short) names \(other.name) already; choose another short_name.")
            }
            let credits = call.number("credits")
            if let credits {
                guard credits > 0, credits <= 60 else { return .error("credits must be between 0 and 60.") }
                guard PlanTools.states(credits, in: checked.quote) else {
                    return .error("The quote must state \(CoachCatalogNumber.text(credits)); else leave credits null (set_course_credits later).")
                }
            }
            let draft = CourseDraft(
                name: name, lecturers: call.text("lecturers") ?? "", language: call.text("language") ?? "en",
                adminLanguage: call.text("admin_language") ?? "de", shortName: short, showsInCalendar: call.flag("in_calendar") ?? true,
                credits: credits
            )
            let outcome = try await applyAsked(.courseAdd(draft), checked: checked, context: context)
            switch outcome {
            case .applied(let change):
                let token = try await CourseList.load(services.database).token(for: change.targetID)
                return .json([
                    "applied": true, "course": ToolJSON.string(token), "cite": .string(change.citation.marker), "title": .string(change.title),
                    "summary": .string(change.summary),
                ])
            case .unchanged(let text):
                return .json(["applied": false, "note": .string(text)])
            case .conflict(let text), .refused(let text):
                return .error(text)
            }
        }
    }

    // MARK: Weekly slots

    var slotProperties: JSONObject {
        [
            "room": Schema.optionalString("Room (\"Room 115\"); null: none yet."),
            "first": Schema.optionalString("First day, YYYY-MM-DD; null: the semester's lecture start (it also sets which weeks for every second week)."),
            "last": Schema.optionalString("Last day, YYYY-MM-DD; null: the semester's lecture end."),
            "every": Schema.nullable(Schema.stringEnum(["week", "second_week"])),
            "quote": quoteProperty,
        ]
    }

    var addWeeklySlot: AgentTool {
        AgentTool(
            tool: .custom(
                name: "add_weekly_slot",
                description: """
                    Adds a course's weekly class as Course Settings' Add Slot does, ONLY when the student asks (quote: \
                    their words asking): its sessions are planned for the semester's lecture days (breaks skipped) and \
                    appear in the Study Portal calendar. Times are the university's time zone. every: null for every week. Undo \
                    removes it with its planned sessions.
                    """,
                inputSchema: Schema.object(slotProperties.merging([
                    "course": Schema.string("Course token."),
                    "kind": Schema.stringEnum(["lecture", "exercise", "tutorial", "seminar"]),
                    "weekday": Schema.stringEnum(Self.weekdays),
                    "starts": Schema.string("HH:MM."),
                    "ends": Schema.string("HH:MM."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await studentAsked(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            guard let course = try await CourseList.load(services.database).course(call.text("course")) else {
                return .error("course must be a course token (a course add_course just made: its token from that result).")
            }
            guard let weekday = call.text("weekday").flatMap({ Self.weekdays.firstIndex(of: $0.lowercased()) }) else {
                return .error("weekday must be monday … sunday.")
            }
            guard let start = Self.minute(call.text("starts")), let end = Self.minute(call.text("ends")) else {
                return .error("starts and ends must be HH:MM.")
            }
            var slot = WeeklySlot(
                courseID: course.id, kind: SessionKind(rawValue: call.text("kind") ?? "lecture"), weekday: weekday + 1, startMinute: start,
                durationMinutes: end - start, room: call.text("room") ?? "", timeZone: AppAgentModule.timeZone.identifier
            )
            if let refusal = Self.period(call, into: &slot) { return .error(refusal) }
            return try await slotOutput(applyAsked(.slotAdd(slot), checked: checked, context: context), slotID: slot.id, now: context.now)
        }
    }

    var changeWeeklySlot: AgentTool {
        AgentTool(
            tool: .custom(
                name: "change_weekly_slot",
                description: """
                    Changes a weekly slot (the catalog's [slot 1a2b3c4d]) ONLY when the student asks (quote: their words \
                    asking): another day, time, room, kind, period or rhythm for every week from now (null leaves a \
                    field). Its sessions are planned again; a single session is change_session's. Undo puts it back.
                    """,
                inputSchema: Schema.object(slotProperties.merging([
                    "slot": Schema.string("The slot's key (the 8 hex of [slot 1a2b3c4d])."),
                    "kind": Schema.nullable(Schema.stringEnum(["lecture", "exercise", "tutorial", "seminar"])),
                    "weekday": Schema.nullable(Schema.stringEnum(Self.weekdays)),
                    "starts": Schema.optionalString("HH:MM; the length stays unless ends is given."),
                    "ends": Schema.optionalString("HH:MM."),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await studentAsked(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            guard var slot = try await weeklySlot(call.text("slot")) else { return .error("Unknown slot. Use a [slot 1a2b3c4d] key from the catalog.") }
            if let kind = call.text("kind") { slot.kind = SessionKind(rawValue: kind) }
            if let text = call.text("weekday") {
                guard let index = Self.weekdays.firstIndex(of: text.lowercased()) else { return .error("weekday must be monday … sunday.") }
                slot.weekday = index + 1
            }
            let starts = call.text("starts")
            let ends = call.text("ends")
            if starts != nil || ends != nil {
                guard starts == nil || Self.minute(starts) != nil, ends == nil || Self.minute(ends) != nil else {
                    return .error("starts and ends must be HH:MM.")
                }
                let start = Self.minute(starts) ?? slot.startMinute
                let end = Self.minute(ends) ?? start + slot.durationMinutes
                slot.startMinute = start
                slot.durationMinutes = end - start
            }
            if let room = call.text("room") { slot.room = room }
            if let refusal = Self.period(call, into: &slot) { return .error(refusal) }
            return try await slotOutput(applyAsked(.slotChange(slot), checked: checked, context: context), slotID: slot.id, now: context.now)
        }
    }

    var removeWeeklySlot: AgentTool {
        AgentTool(
            tool: .custom(
                name: "remove_weekly_slot",
                description: """
                    Removes a weekly slot (the catalog's [slot 1a2b3c4d]) ONLY when the student asks (quote: their words \
                    asking): its future sessions go (past ones and ones with a lecture stay). Undo puts it back.
                    """,
                inputSchema: Schema.object([
                    "slot": Schema.string("The slot's key (the 8 hex of [slot 1a2b3c4d])."),
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
            guard let slot = try await weeklySlot(call.text("slot")) else { return .error("Unknown slot. Use a [slot 1a2b3c4d] key from the catalog.") }
            switch try await applyAsked(.slotRemove(slot.id), checked: checked, context: context) {
            case .applied(let change):
                return .json(["applied": true, "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary)])
            case .unchanged(let text):
                return .json(["applied": false, "note": .string(text)])
            case .conflict(let text), .refused(let text):
                return .error(text)
            }
        }
    }

    /// The result of a slot added or changed: its cite marker and the sessions it plans now.
    func slotOutput(_ outcome: ChangeLog.Outcome, slotID: WeeklySlot.ID, now: Date) async throws -> ToolOutput {
        switch outcome {
        case .applied(let change):
            let sessions = try await services.database.read { db in
                try LectureSession.where { $0.weeklySlotID.eq(WeeklySlot.ID?.some(slotID)) && !$0.isCancelled }.order(by: \.startsAt).fetchAll(db)
            }
            var object: JSONObject = [
                "applied": true, "slot": .string(ChatCitation.key(slotID)), "cite": .string(change.citation.marker),
                "title": .string(change.title), "summary": .string(change.summary), "sessions": .int(sessions.count),
            ]
            if let next = sessions.first(where: { $0.startsAt >= now }) { object["next"] = ToolJSON.string(AgentText.iso(next.startsAt)) }
            if sessions.isEmpty { object["note"] = "No lecture day of the semester fits it (check first and last)." }
            return .json(.object(object))
        case .unchanged(let text):
            return .json(["applied": false, "note": .string(text)])
        case .conflict(let text), .refused(let text):
            return .error(text)
        }
    }

    /// A slot by its key ("1a2b3c4d", "[slot 1a2b3c4d]") or id.
    func weeklySlot(_ reference: String?) async throws -> WeeklySlot? {
        guard var text = reference?.lowercased() else { return nil }
        for noise in ["[", "]", "slot"] { text = text.replacingOccurrences(of: noise, with: "") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: text) { return try await services.records.fetch(WeeklySlot.self, id: id) }
        let key = String(text.prefix(8))
        guard key.count == 8, key.allSatisfy(\.isHexDigit) else { return nil }
        return try await services.database.read { db in
            let ids = try String.fetchAll(db, sql: #"SELECT "id" FROM "weekly_slot" WHERE "id" LIKE ? LIMIT 2"#, arguments: [key + "%"])
            guard ids.count == 1, let id = UUID(uuidString: ids[0]) else { return nil }
            return try WeeklySlot.find(id).fetchOne(db)
        }
    }

    /// "10:15", "9:00", "14.15" → minutes after midnight.
    static func minute(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else {
            return nil
        }
        return hour * 60 + minute
    }

    /// Writes `first`, `last` and `every` into `slot` (null leaves them), or why not.
    static func period(_ call: ToolUseBlock, into slot: inout WeeklySlot) -> String? {
        if let text = call.text("first") {
            guard let day = CalendarDay(rawValue: text) else { return "first must be YYYY-MM-DD." }
            slot.validFrom = day
        }
        if let text = call.text("last") {
            guard let day = CalendarDay(rawValue: text) else { return "last must be YYYY-MM-DD." }
            slot.validUntil = day
        }
        if let every = call.text("every") { slot.weekInterval = every == "second_week" ? 2 : 1 }
        return nil
    }
}

// MARK: - The change log

extension ChangeLog {
    static let weekdayNames = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    /// "Mon 12:15–13:45".
    static func slotTime(_ slot: WeeklySlot) -> String {
        func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60 % 24, minute % 60) }
        let day = (1...7).contains(slot.weekday) ? weekdayNames[slot.weekday - 1] : "?"
        return "\(day) \(clock(slot.startMinute))–\(clock(slot.endMinute))"
    }

    /// "lecture Mon 12:15–13:45 · Room 115 · every 2nd week · from 2026-11-02": a slot as the
    /// catalog and the activity log name it.
    static func slotText(_ slot: WeeklySlot) -> String {
        var parts = ["\(slot.kind.rawValue) \(slotTime(slot))"]
        if !slot.room.isEmpty { parts.append(slot.room) }
        if slot.weekInterval == 2 { parts.append("every 2nd week") } else if slot.weekInterval > 2 { parts.append("every \(slot.weekInterval) weeks") }
        if let from = slot.validFrom { parts.append("from \(from.rawValue)") }
        if let until = slot.validUntil { parts.append("until \(until.rawValue)") }
        return parts.joined(separator: " · ")
    }

    /// Two slots of a course that would plan the same class.
    static func sameClass(_ lhs: WeeklySlot, _ rhs: WeeklySlot) -> Bool {
        lhs.id != rhs.id && lhs.courseID == rhs.courseID && lhs.kind == rhs.kind && lhs.weekday == rhs.weekday && lhs.startMinute == rhs.startMinute
    }

    /// Why a slot cannot be saved, nil when it can.
    static func invalid(_ slot: WeeklySlot) -> String? {
        guard SessionKind.slotKinds.contains(slot.kind) else { return "kind must be lecture, exercise, tutorial or seminar." }
        guard (1...7).contains(slot.weekday) else { return "weekday must be monday … sunday." }
        guard slot.durationMinutes > 0 else { return "The class must end after it starts." }
        guard slot.endMinute <= 24 * 60, slot.durationMinutes <= 12 * 60 else { return "A class ends on the day it starts." }
        guard (1...2).contains(slot.weekInterval) else { return "every must be week or second_week." }
        if let from = slot.validFrom, let until = slot.validUntil, until < from { return "last must not be before first." }
        return nil
    }

    // MARK: Courses

    static func addCourse(_ draft: CourseDraft, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date) throws -> Outcome {
        guard draft.isValid else { return .refused("A course needs a name.") }
        let semesters = try Semester.all.fetchAll(db)
        let semester = draft.semesterID.flatMap { id in semesters.first { $0.id == id } } ?? Semester.current(among: semesters, on: now)
        let name = TextFolding.fold(draft.trimmedName)
        if let same = try Course.all.fetchAll(db).first(where: { TextFolding.fold($0.name) == name && ($0.semesterID ?? semester.id) == semester.id }) {
            return .refused("\(same.name) is a course of \(semester.name) already.")
        }
        var draft = draft
        draft.semesterID = semester.id
        // Recording consent is the student's own (Course Settings), never the agent's.
        draft.records = false
        let course = try CourseLibrary.insert(draft, now: now, consentAt: now, store: store, db: db)
        var change = AgentChange(
            kind: .courseAdd, targetTable: .course, targetID: course.id, title: course.name, summary: "New course · \(semester.name)",
            before: AgentChangeValues(exists: false),
            after: AgentChangeValues(exists: true, professors: course.professors, credits: course.credits), sourceKind: origin.sourceKind,
            taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1, model: origin.model, apiCallID: origin.apiCallID,
            appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    /// Undo of `add_course`: the course goes through smart import's delete (its slots, sessions,
    /// mail rules, items and plan with it), only while it holds none of the student's work (then
    /// Delete Course… is theirs to use); its slot changes are marked undone with it.
    func undoCourseAdd(_ change: AgentChange, at date: Date) async throws -> Bool {
        guard change.undoneAt == nil else { return false }
        let courseID = change.targetID
        if let courseID {
            let key = courseID.uuidString.lowercased()
            let state = try await services.database.read { db -> (exists: Bool, holds: Bool) in
                guard try Course.find(courseID).fetchOne(db) != nil else { return (false, false) }
                let holds = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM "lecture" WHERE "course_id" = ?1)
                        OR EXISTS (SELECT 1 FROM "deck" WHERE "course_id" = ?1)
                        OR EXISTS (SELECT 1 FROM "recording" WHERE "course_id" = ?1)
                        OR EXISTS (SELECT 1 FROM "note" WHERE "course_id" = ?1)
                    """, arguments: [key]) ?? true
                return (true, holds)
            }
            if state.holds { throw UndoRefused.holdsWork }
            if state.exists { _ = try await (filing ?? FilingService(services: services)).delete(.course(courseID)) }
        }
        let id = change.id
        try await services.database.write { db in
            try AgentChangeRepository.markUndone(id, at: date, db: db)
            let slotChanges = try AgentChange.where({ $0.targetTable.eq(AgentChangeTarget.slot) && $0.undoneAt.is(nil) }).fetchAll(db)
            for row in slotChanges where courseID != nil && (row.after?.courseID == courseID || row.before?.courseID == courseID) {
                try AgentChangeRepository.markUndone(row.id, at: date, db: db)
            }
        }
        await onChange()
        return true
    }

    // MARK: Weekly slots

    static func addSlot(_ slot: WeeklySlot, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date) throws -> Outcome {
        guard let course = try Course.find(slot.courseID).fetchOne(db) else { return .refused("Unknown course.") }
        if let refusal = invalid(slot) { return .refused(refusal) }
        let others = try WeeklySlot.where { $0.courseID.eq(slot.courseID) }.fetchAll(db)
        if let same = others.first(where: { sameClass($0, slot) }) {
            return .refused("\(course.name) has that \(slot.kind.rawValue) already ([slot \(ChatCitation.key(same.id))]).")
        }
        let saved = try CourseSchedule.saveSlot(slot, now: now, store: store, db: db)
        let change = try logSlot(
            kind: .slotAdd, course: course, before: nil, after: saved, summary: "Weekly " + slotText(saved), quote: quote, origin: origin,
            db: db, store: store, now: now
        )
        return .applied(change)
    }

    static func changeSlot(_ slot: WeeklySlot, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date) throws -> Outcome {
        guard let old = try WeeklySlot.find(slot.id).fetchOne(db) else { return .refused("Unknown weekly slot.") }
        guard slot.courseID == old.courseID, let course = try Course.find(old.courseID).fetchOne(db) else {
            return .refused("A slot stays with its course.")
        }
        if let refusal = invalid(slot) { return .refused(refusal) }
        guard WeeklySlotValues(slot) != WeeklySlotValues(old) else { return .unchanged("The slot is like that already.") }
        let others = try WeeklySlot.where { $0.courseID.eq(slot.courseID) }.fetchAll(db)
        if let same = others.first(where: { sameClass($0, slot) }) {
            return .refused("\(course.name) has that \(slot.kind.rawValue) already ([slot \(ChatCitation.key(same.id))]).")
        }
        let id = slot.id
        let previous = try AgentChange
            .where { $0.targetTable.eq(AgentChangeTarget.slot) && $0.targetID.eq(UUID?.some(id)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) && $0.kind.eq(AgentChangeKind.slotChange) }
            .fetchAll(db)
        let saved = try CourseSchedule.saveSlot(slot, now: now, store: store, db: db)
        let change = try logSlot(
            kind: .slotChange, course: course, before: old, after: saved, summary: "Weekly \(slotText(saved)) (was \(slotTime(old)))",
            quote: quote, origin: origin, db: db, store: store, now: now
        )
        for row in previous { try AgentChangeRepository.supersede(row.id, by: change.id, at: now, db: db) }
        return .applied(change)
    }

    static func removeSlot(_ id: WeeklySlot.ID, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date) throws -> Outcome {
        guard let old = try WeeklySlot.find(id).fetchOne(db), let course = try Course.find(old.courseID).fetchOne(db) else {
            return .refused("Unknown weekly slot.")
        }
        try CourseSchedule.deleteSlot(id, now: now, store: store, db: db)
        let change = try logSlot(
            kind: .slotRemove, course: course, before: old, after: nil, summary: "Removed weekly " + slotText(old), quote: quote,
            origin: origin, db: db, store: store, now: now
        )
        return .applied(change)
    }

    /// The change row of a slot added (`before` nil), changed or removed (`after` nil).
    static func logSlot(
        kind: AgentChangeKind, course: Course, before: WeeklySlot?, after: WeeklySlot?, summary: String, quote: String, origin: Origin,
        db: Database, store: RecordStore, now: Date
    ) throws -> AgentChange {
        func values(_ slot: WeeklySlot?) -> AgentChangeValues {
            AgentChangeValues(exists: slot != nil, courseID: course.id, slot: slot.map(WeeklySlotValues.init))
        }
        var change = AgentChange(
            kind: kind, targetTable: .slot, targetID: (after ?? before)?.id, title: course.name, summary: summary, before: values(before),
            after: values(after), sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1,
            model: origin.model, apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return change
    }

    /// Undo of a slot change inside the caller's transaction: an added slot is deleted (its
    /// planned sessions with it), a changed one gets its old values back while it still holds what
    /// the change wrote, a removed one comes back unless the course has that class again.
    static func undoSlot(_ change: AgentChange, slotID: WeeklySlot.ID, db: Database, store: RecordStore, now: Date) throws {
        let current = try WeeklySlot.find(slotID).fetchOne(db)
        switch change.kind {
        case .slotAdd:
            if current != nil { try CourseSchedule.deleteSlot(slotID, now: now, store: store, db: db) }
        case .slotChange:
            guard let before = change.before?.slot else { return }
            guard let current, WeeklySlotValues(current) == change.after?.slot else { throw UndoRefused.changedSince }
            try CourseSchedule.saveSlot(before.slot(updatedAt: now), now: now, store: store, db: db)
        case .slotRemove:
            guard let before = change.before?.slot else { return }
            let restored = before.slot(updatedAt: now)
            guard current == nil, try Course.find(before.courseID).fetchOne(db) != nil else { throw UndoRefused.changedSince }
            let others = try WeeklySlot.where { $0.courseID.eq(before.courseID) }.fetchAll(db)
            guard !others.contains(where: { sameClass($0, restored) }) else { throw UndoRefused.changedSince }
            try CourseSchedule.saveSlot(restored, now: now, store: store, db: db)
        default:
            break
        }
    }
}
