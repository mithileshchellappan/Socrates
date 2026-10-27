import Agent
import ClaudeKit
import Deadlines
import Filing
import Foundation
import StudyCore

/// 2026-10-23: the lecture plan, changed when the student asks ("we already did chapter 3 today",
/// "chapter 3 continues next week", "that recording is Tuesday's", "L4 is really L3", "delete the
/// empty L7"). Registered actions only (`run_action`), student-only (quote: their words asking,
/// verified like merge_lectures'), each through the change log (`ChangeLog.editLecturePlan` /
/// `moveRecording` → smart import, one transaction with its change row and Undo):
///
/// - `move_lecture {lecture, session | date, later, quote}`: the lecture to a class of its course
///   (a class whose lecture stays joins its meeting); `later: follow` moves the course's planned
///   lectures numbered after it to the free classes after it, in order. The quote must state the
///   day of the class it goes to or the class it leaves (a date, a weekday, today, yesterday,
///   "next week"), read against when the student wrote them.
/// - `edit_lecture {lecture, title?, number?, later_numbers, quote}`: rename and renumber.
/// - `move_recording {recording, to, quote}`: a recording to another lecture (another course's only
///   when the quote names that course).
/// - `delete_lecture {lecture, quote}`: a lecture that holds nothing.
extension WriteTools {
    // MARK: move_lecture

    var moveLecture: AgentTool {
        AgentTool(
            tool: .custom(
                name: "move_lecture",
                description: """
                    Moves a lecture to another class of its course, ONLY when the student says a class covered more or less \
                    than planned or a lecture sits on the wrong day ("we already did chapter 3 today", "chapter 3 continues \
                    next week"). The class: session (an id from query_sessions) or date ("YYYY-MM-DD"; "YYYY-MM-DDTHH:MM" \
                    picks one of two classes that day). A class whose lecture stays keeps it, and this lecture joins that \
                    meeting. later: "follow" moves the planned lectures numbered after it to the free classes after it, in \
                    order (the rest of the plan shifts); "stay" (default) leaves them. The quote must state the day of the \
                    class it goes to or leaves. Undo puts every lecture back.
                    """,
                inputSchema: Schema.object([
                    "lecture": Schema.string("The lecture: its key from list_lectures, course token and number (\"DC 3\") or id."),
                    "session": Schema.optionalString("The class's id from query_sessions; null: date."),
                    "date": Schema.optionalString("The class's day, \"YYYY-MM-DD\", or \"YYYY-MM-DDTHH:MM\" for one of two classes that day; null: session."),
                    "later": Schema.nullable(Schema.stringEnum(["follow", "stay"])),
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
            guard let reference = call.text("lecture"), let lectureID = try await WriteToolsLookup.lectureID(reference, services: services),
                  let lecture = try await services.records.fetch(Lecture.self, id: lectureID)
            else { return .error("No single lecture is that: use its key from list_lectures.") }
            let session: LectureSession
            switch try await planClass(call, courseID: lecture.courseID) {
            case .success(let value): session = value
            case .failure(let refusal): return .error(refusal.message)
            }
            // The student's words state the day of the class it goes to, or of the class it leaves.
            let zone = AppAgentModule.timeZone
            var days = [CalendarDay(session.startsAt, in: zone)]
            if let held = lecture.heldAt { days.append(CalendarDay(held, in: zone)) }
            guard days.contains(where: { Self.states($0, in: checked.quote, reference: checked.reference, timeZone: zone) }) else {
                return .error(
                    "quote must state the day of the class it goes to or leaves (a date, a weekday, today, yesterday, next week), in the student's words. If their message lacks it, ask which day."
                )
            }
            let follow = call.text("later") == "follow"
            let outcome = try await changeLog.editLecturePlan(
                .place(lectureID, session: session.id, followers: follow), quote: checked.quote, origin: try await askedOrigin(checked, context: context)
            )
            guard case .applied(let change) = outcome else { return outcome.toolOutput }
            return try await placedResult(change, lectureID: lectureID, session: session)
        }
    }

    /// The class `session` or `date` names (a numbered class that day, else its meeting).
    func planClass(_ call: ToolUseBlock, courseID: Course.ID) async throws -> Result<LectureSession, Refusal> {
        let sessions = try await services.database.read { db in
            try LectureSession.where { $0.courseID.eq(courseID) }.order(by: \.startsAt).fetchAll(db)
        }
        if let id = call.id("session") {
            guard let session = sessions.first(where: { $0.id == id }) else {
                return .failure("session must be a class of the lecture's course (an id from query_sessions).")
            }
            return .success(session)
        }
        guard let text = call.text("date"), let day = CalendarDay(rawValue: String(text.prefix(10))) else {
            return .failure("Give session (an id from query_sessions) or date (\"YYYY-MM-DD\").")
        }
        let zone = AppAgentModule.timeZone
        let onDay = sessions.filter { CalendarDay($0.startsAt, in: zone) == day }
        let open = onDay.filter { !$0.isCancelled }
        guard !open.isEmpty else {
            return .failure(onDay.isEmpty
                ? "The course has no class that day. If the student says one took place, add_session first (find_actions), then move_lecture to it."
                : "That day's class is cancelled. If it took place after all, restore it with change_session first (only when the student says so).")
        }
        if text.count > 10, let parsed = AgentToolSupport.parseDate(text, allDay: false), !parsed.allDay {
            let near = open.filter { abs($0.startsAt.timeIntervalSince(parsed.date)) <= 30 * 60 }
                .min { abs($0.startsAt.timeIntervalSince(parsed.date)) < abs($1.startsAt.timeIntervalSince(parsed.date)) }
            guard let near else {
                return .failure("No class starts near that time; that day: \(open.map { ChangeSummary.time($0.startsAt) }.joined(separator: ", ")).")
            }
            return .success(near)
        }
        let numbered = open.filter { SessionLectures.numbersLectures($0, among: sessions) }
        if numbered.count > 1 {
            return .failure("The course has \(numbered.count) classes that day (\(numbered.map { ChangeSummary.time($0.startsAt) }.joined(separator: ", "))): give date as \"YYYY-MM-DDTHH:MM\".")
        }
        return .success(numbered.first ?? SessionLectures.meeting(of: open[0], among: sessions))
    }

    /// The result of a placement: where the lecture is now, the lecture it joined, the later
    /// lectures that moved and those left without a class.
    func placedResult(_ change: AgentChange, lectureID: Lecture.ID, session: LectureSession) async throws -> ToolOutput {
        let courses = try await CourseList.load(services.database)
        let values = change.after?.lectures ?? []
        func name(_ value: LecturePlacementValues, courseID: Course.ID) -> String {
            let token = courses.token(for: courseID) ?? ""
            return value.number.map { "\(token) L\($0)" } ?? "\(token) \(ChatCitation.key(value.id))"
        }
        guard let lecture = try await services.records.fetch(Lecture.self, id: lectureID) else { return ChangeLog.Outcome.applied(change).toolOutput }
        var result: JSONObject = [
            "moved": true, "lecture": .string(name(LecturePlacementValues(lecture, filings: []), courseID: lecture.courseID)),
            "class": ToolJSON.string(lecture.heldAt.map { AgentText.dayTime($0) }), "cite": .string(change.citation.marker),
        ]
        if lecture.lectureSessionID == nil {
            // Joined: the class meeting's own lecture.
            let course = lecture.courseID
            let holder = try await services.database.read { db -> Lecture? in
                let sessions = try LectureSession.where { $0.courseID.eq(course) }.fetchAll(db)
                let meeting: LectureSession.ID? = SessionLectures.meeting(of: session, among: sessions).id
                return try Lecture.where { $0.lectureSessionID.eq(meeting) }.fetchOne(db)
            }
            if let holder { result["with"] = .string(name(LecturePlacementValues(holder, filings: []), courseID: holder.courseID)) }
        }
        // The later lectures that moved: a new date, or none left (a joined lecture that only took
        // the link of the class it shares keeps its date and is not one of them).
        let was = Dictionary((change.before?.lectures ?? []).map { ($0.id, $0.heldAt) }, uniquingKeysWith: { first, _ in first })
        let others = values.filter { value in
            guard value.id != lectureID, let old = was[value.id] else { return false }
            switch (old, value.heldAt) {
            case (let old?, let new?): return abs(old.timeIntervalSince(new)) >= 1
            case (nil, nil): return false
            default: return true
            }
        }
        let moved = others.filter { $0.heldAt != nil }.map { value in
            JSONValue.string("\(name(value, courseID: lecture.courseID)) → \(value.heldAt.map { AgentText.dayTime($0) } ?? "")")
        }
        let unplaced = others.filter { $0.heldAt == nil }.map { JSONValue.string(name($0, courseID: lecture.courseID)) }
        if !moved.isEmpty { result["later_moved"] = .array(moved) }
        if !unplaced.isEmpty {
            result["unplaced"] = .array(unplaced)
            result["note"] = "No class is left for the unplaced lectures: they are undated now. Tell the student."
        }
        return ToolJSON.object(result)
    }

    // MARK: edit_lecture

    var editLecture: AgentTool {
        AgentTool(
            tool: .custom(
                name: "edit_lecture",
                description: """
                    Renames or renumbers a lecture, ONLY when the student asks ("call L5 'Optical flow'", "L4 is really \
                    L3"). A lecture's number is its place in the course's sequence (the decks' 03_…), not the class it is \
                    held in. later_numbers: true moves every lecture numbered after it by the same step. A number another \
                    lecture has is refused. Undo puts the names and numbers back.
                    """,
                inputSchema: Schema.object([
                    "lecture": Schema.string("The lecture: its key from list_lectures, course token and number (\"DC 3\") or id."),
                    "title": Schema.optionalString("Its new title; null: unchanged."),
                    "number": Schema.nullable(["type": "integer", "description": "Its new number (1–999); null: unchanged."]),
                    "later_numbers": Schema.nullable(["type": "boolean", "description": "True: the lectures numbered after it move by the same step."]),
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
                return .error("No single lecture is that: use its key from list_lectures.")
            }
            let title = call.text("title")
            let number = call.integer("number")
            guard title != nil || number != nil else { return .error("Give title, number or both.") }
            if let number, !(1...999).contains(number) { return .error("number must be 1–999.") }
            let outcome = try await changeLog.editLecturePlan(
                .label(lectureID, title: title, number: number, shiftLater: call.flag("later_numbers") ?? false), quote: checked.quote,
                origin: try await askedOrigin(checked, context: context)
            )
            return outcome.toolOutput
        }
    }

    // MARK: move_recording

    var moveRecording: AgentTool {
        AgentTool(
            tool: .custom(
                name: "move_recording",
                description: """
                    Moves a recording to another lecture, ONLY when the student says it belongs there ("that recording is \
                    Tuesday's"). Its transcript, slide stamps, notes and flags go along; both lectures' study passes are \
                    built again; the lecture it leaves stays (delete_lecture when the student asks). recording: a key \
                    from list_lectures' recordings (also its recordings_without_lecture, which this places), or a \
                    lecture that has exactly one. Into another course only when the quote names that course. Undo \
                    moves it back.
                    """,
                inputSchema: Schema.object([
                    "recording": Schema.string("The recording's key (list_lectures' recordings or recordings_without_lecture), or a lecture with exactly one recording."),
                    "to": Schema.string("The lecture it goes to: its key, course token and number (\"DC 3\") or id."),
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
            guard let recordingID = try await recordingID(call.text("recording") ?? "") else {
                return .error("No single recording is that: use a recording key from list_lectures (or a lecture with exactly one recording).")
            }
            guard let reference = call.text("to"), let lectureID = try await WriteToolsLookup.lectureID(reference, services: services),
                  let target = try await services.records.fetch(Lecture.self, id: lectureID)
            else {
                return .error("to must name one lecture: its key from list_lectures, or course token and number.")
            }
            // Never across courses unasked: the student's own words (the quote) name the target's course.
            let across = try await recordingCourse(recordingID).map { $0 != target.courseID } ?? false
            if across {
                let courses = try await CourseList.load(services.database)
                guard courses.names(target.courseID, in: checked.quote) else {
                    return .error(
                        "That lecture is another course's than the recording's. Ask the student which course it belongs to; it moves across only when their words name that course (quote them)."
                    )
                }
            }
            let outcome = try await changeLog.moveRecording(
                recordingID, to: lectureID, acrossCourses: across, quote: checked.quote, origin: try await askedOrigin(checked, context: context)
            )
            return outcome.toolOutput
        }
    }

    /// A recording by its id, its key ("b680d175", "9a7d94d1/b680d175"), or a lecture with one.
    /// A "lecture/recording" key whose recording part matches none is nobody (never the lecture's
    /// only recording: that may be another one than the agent named).
    func recordingID(_ reference: String) async throws -> Recording.ID? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let id = UUID(uuidString: text) { return id }
        let parts = text.lowercased().split(separator: "/").map(String.init)
        if let key = parts.last, key.count == 8, key.allSatisfy(\.isHexDigit) {
            let found = try await services.database.read { db in
                try String.fetchAll(db, sql: #"SELECT "id" FROM "recording" WHERE "id" LIKE ? LIMIT 2"#, arguments: [key + "%"])
            }
            if found.count == 1, let id = found.first.flatMap(UUID.init(uuidString:)) { return id }
        }
        guard parts.count == 1 else { return nil }
        guard let lectureID = try await WriteToolsLookup.lectureID(text, services: services) else { return nil }
        let reference: Lecture.ID? = lectureID
        let recordings = try await services.database.read { db in try Recording.where { $0.lectureID.eq(reference) }.fetchAll(db) }
        return recordings.count == 1 ? recordings.first?.id : nil
    }

    /// The course a recording is in now: its lecture's, else its own.
    func recordingCourse(_ recordingID: Recording.ID) async throws -> Course.ID? {
        guard let recording = try await services.records.fetch(Recording.self, id: recordingID) else { return nil }
        if let id = recording.lectureID, let lecture = try await services.records.fetch(Lecture.self, id: id) { return lecture.courseID }
        return recording.courseID
    }

    // MARK: delete_lecture

    var deleteLecture: AgentTool {
        AgentTool(
            tool: .custom(
                name: "delete_lecture",
                description: """
                    Deletes an empty lecture (no recording, slides, notes, flags, practice answers or sections the student \
                    said it covered), ONLY when the student asks ("delete the empty L7"). A lecture that holds something is \
                    refused. Undo brings it back.
                    """,
                inputSchema: Schema.object([
                    "lecture": Schema.string("The lecture: its key from list_lectures, course token and number (\"DC 7\") or id."),
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
                return .error("No single lecture is that: use its key from list_lectures.")
            }
            let outcome = try await changeLog.editLecturePlan(
                .deleteEmpty(lectureID), quote: checked.quote, origin: try await askedOrigin(checked, context: context)
            )
            return outcome.toolOutput
        }
    }

    // MARK: - Shared

    /// Whether `quote` states `day`, read at `reference`: a date, today or tomorrow, a coming
    /// weekday, a week named without a day ("next week"), or, for a day of the past six,
    /// "yesterday" / "gestern" / "vorgestern" or its weekday's name ("on Thursday we already did…").
    static func states(_ day: CalendarDay, in quote: String, reference: Date, timeZone: TimeZone) -> Bool {
        let mentions = DateMentions.parse(quote, reference: reference, timeZone: timeZone)
        if mentions.days.contains(day) || mentions.weeks.contains(day.adding(days: 1 - day.weekday)) { return true }
        let back = day.days(to: CalendarDay(reference, in: timeZone))
        guard (1...6).contains(back) else { return false }
        let words = Set(TextFolding.words(quote))
        if back == 1, words.contains("yesterday") || words.contains("gestern") { return true }
        if back == 2, words.contains("vorgestern") { return true }
        let names = [
            ["monday", "montag"], ["tuesday", "dienstag"], ["wednesday", "mittwoch"], ["thursday", "donnerstag"],
            ["friday", "freitag"], ["saturday", "samstag", "sonnabend"], ["sunday", "sonntag"],
        ]
        return names[(day.weekday - 1 + 7) % 7].contains(where: words.contains)
    }
}
