import Agent
import ClaudeKit
import Coach
import Deadlines
import Foundation
import StudyCore

/// mc: the app agent's plan tools (docs/plan-coach.md §4 "Agent tools"; PRD "Manage it through the
/// agent, not UI": no settings screen for any of this).
///
/// | Tool | Effect | Does |
/// |---|---|---|
/// | plan_query | read | the blocks of a day or range (state, minutes), each day's total, per course the budget, this week against its share, Ready, the exam sat, the rules in effect with memory ids (`CoachCatalog.report`) |
/// | plan_adjust | verified write (chat ≥ 3 words) | skip / cap / sitting / seminar_hours / attend → a `plan` memory with its `PlanRule` + `agent_change` (`ChangeLog.Request.planRule`), then a replan; move → the block row itself, `created_by = user` |
/// | set_course_credits | verified write (chat, mail, lecture) | credits and/or self-study hours (`ChangeLog.Request.courseCredits`, before / after, Undo) |
/// | mark_away_days | verified write (chat ≥ 3 words) | weekdays and/or a date range, cap minutes → a `plan` memory with `PlanRule.away` |
///
/// Every write waits for the coach's replan (when the app runs one), so the result names the plan
/// as it is now. The coach also follows the rows on its own (`agent_memory`, `course`).
struct PlanTools: Sendable {
    let services: StudyServices
    let changeLog: ChangeLog
    let coach: CoachEngine?
    /// The conversation's verified writes (the quote checks of set_course_credits).
    let writes: WriteTools

    var applier: FactApplier { FactApplier(services: services) }
    var zone: TimeZone { AppAgentModule.timeZone }

    static let weekdayNames = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]
    static let blockKinds = ["review", "round", "exercise", "read", "practice_exam", "seminar_step"]

    static let integer: JSONValue = ["type": "integer"]
    static let number: JSONValue = ["type": "number"]
    static let boolean: JSONValue = ["type": "boolean"]
    static var weekdays: JSONValue {
        Schema.nullable(["type": "array", "items": Schema.stringEnum(weekdayNames), "description": "Weekdays it applies to every week."])
    }

    // MARK: - plan_query

    var planQuery: AgentTool {
        AgentTool(
            tool: .custom(
                name: "plan_query",
                description: """
                    The study plan: the blocks of a day or a range (id, kind, courses, title, minutes, state, by planner or \
                    student), each day's planned total, per course the self-study budget, this week's studied time against \
                    its share, Ready (the share of taught topics known solidly) and the exam sat, and the plan rules in effect \
                    with their memory ids.
                    """,
                inputSchema: Schema.object([
                    "from": Schema.optionalString("First day, YYYY-MM-DD; null for today."),
                    "through": Schema.optionalString("Last day, YYYY-MM-DD; null for the same day. At most 14 days after from."),
                ])
            ),
            effect: .read
        ) { call, context in
            let today = CalendarDay(context.now, in: zone)
            let first = call.text("from").flatMap(CalendarDay.init(rawValue:)) ?? today
            var last = call.text("through").flatMap(CalendarDay.init(rawValue:)) ?? first
            if last < first { last = first }
            if first.days(to: last) > CoachRules.planDays { last = first.adding(days: CoachRules.planDays) }
            let courses = try await CourseList.load(services.database)
            let now = context.now
            let through = last
            let report = try await services.database.read { db in
                try CoachCatalog.report(db: db, now: now, from: first, through: through) { courses.token(for: $0) ?? "-" }
            }
            guard case .object(var object) = report, case .array(let days)? = object["days"] else { return .error("The plan could not be read.") }
            object["days"] = nil
            return ToolJSON.fitted(object, key: "days", rows: days)
        }
    }

    // MARK: - plan_adjust

    var planAdjust: AgentTool {
        AgentTool(
            tool: .custom(
                name: "plan_adjust",
                description: """
                    Changes the study plan when the student asks (quote: their words asking): skip one block, or a course's \
                    blocks (of one kind) on a day or days; cap the minutes of study a day; which exam date of a course they \
                    sit (1 first, 2 second); weekly study hours for a seminar on or off; a class they do not attend (once, or \
                    every week) or attend after all; move one block to another day. All but move are kept as a plan memory \
                    (forget undoes it). The plan follows at once; classes and deadlines never move.
                    """,
                inputSchema: Schema.object([
                    "action": Schema.stringEnum(["skip", "cap", "sitting", "seminar_hours", "attend", "move"]),
                    "block": Schema.optionalString("A block's id (plan_query): skip or move that block."),
                    "course": Schema.optionalString("Course token: skip a course's blocks, sitting, seminar_hours."),
                    "block_kind": Schema.nullable(Schema.stringEnum(Self.blockKinds)),
                    "first": Schema.optionalString("First day it applies, YYYY-MM-DD (skip: null for today; cap: null for from now on)."),
                    "last": Schema.optionalString("Last day it applies, YYYY-MM-DD (skip: null for the first day; cap: null for open-ended)."),
                    "weekdays": Self.weekdays,
                    "minutes": Schema.nullable(Self.integer),
                    "sitting": Schema.nullable(Self.integer),
                    "enabled": Schema.nullable(Self.boolean),
                    "session": Schema.optionalString("attend: a session's id (query_sessions)."),
                    "every_week": Schema.nullable(Self.boolean),
                    "to_day": Schema.optionalString("move: the new day, YYYY-MM-DD."),
                    "quote": Schema.string("The student's words in the message you are answering that ask for it (at least 3 words)."),
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            guard let quote = call.text("quote"),
                  let checked = try await applier.verify(quote, line: nil, material: .chat(context.conversationID, words: context.studentText, date: context.now))
            else { return .error("quote must be the student's words asking for it (at least 3 words), copied exactly.") }
            let action = call.text("action") ?? ""
            if action == "move" { return try await move(call, context: context) }
            let built: Result<(rule: PlanRule, text: String, courseID: Course.ID?, block: StudyBlock?), Refusal>
            switch action {
            case "skip": built = try await skipRule(call, context: context)
            case "cap": built = capRule(call, context: context)
            case "sitting", "seminar_hours": built = try await courseRule(call, action: action)
            case "attend": built = try await attendRule(call)
            default: return .error("action must be skip, cap, sitting, seminar_hours, attend or move.")
            }
            switch built {
            case .failure(let refusal): return .error(refusal.message)
            case .success(let value):
                let output = try await remember(value.rule, text: value.text, courseID: value.courseID, checked: checked, context: context)
                // A skipped block that is still open is skipped at once (today's are fixed).
                if let block = value.block, block.state.isOpen {
                    try await StudyPlanRepository(store: services.records).setState(block.id, .skipped)
                }
                await coach?.replan()
                return output
            }
        }
    }

    /// Writes the rule's memory through the change log.
    func remember(_ rule: PlanRule, text: String, courseID: Course.ID?, checked: VerifiedQuote, context: ToolContext) async throws -> ToolOutput {
        let origin = ChangeLog.Origin(
            source: checked.source, sourceDate: context.now, model: ClaudeModel.opus55.rawValue, conversationID: context.conversationID
        )
        let outcome = try await changeLog.apply(.planRule(rule, text: text, courseID: courseID), quote: checked.quote, origin: origin)
        switch outcome {
        case .applied(let change):
            return .json([
                "applied": true, "cite": .string(change.citation.marker), "memory": change.targetID.map { .string(ChatCitation.key($0)) } ?? .null,
                "rule": .string(text),
            ])
        case .unchanged(let text):
            return .json(["applied": false, "note": .string(text)])
        case .conflict(let text), .refused(let text):
            return .error(text)
        }
    }

    func day(_ text: String?) -> CalendarDay? { text.flatMap(CalendarDay.init(rawValue:)) }

    /// ISO weekdays in the order given (Fri, Sat, Sun, Mon), each once.
    func weekdays(_ call: ToolUseBlock) -> [Int]? {
        var days: [Int] = []
        for name in call.strings("weekdays") {
            guard let index = Self.weekdayNames.firstIndex(of: name.lowercased()), !days.contains(index + 1) else { continue }
            days.append(index + 1)
        }
        return days.isEmpty ? nil : days
    }

    static func kindName(_ kind: StudyBlockKind?) -> String {
        switch kind {
        case .review?: "reviews"
        case .round?: "practice rounds"
        case .exercise?: "exercises"
        case .read?: "readings"
        case .practiceExam?: "practice exams"
        case .seminarStep?: "seminar steps"
        default: "study"
        }
    }

    /// "Fri 23 Oct", "Fri 23 Oct – Mon 26 Oct", "from Fri 23 Oct", "until Mon 26 Oct".
    static func span(_ first: CalendarDay?, _ last: CalendarDay?) -> String {
        switch (first, last) {
        case let (first?, last?) where first == last: CoachText.day(first)
        case let (first?, last?): "\(CoachText.day(first)) – \(CoachText.day(last))"
        case let (first?, nil): "from \(CoachText.day(first))"
        case let (nil, last?): "until \(CoachText.day(last))"
        default: ""
        }
    }

    func skipRule(_ call: ToolUseBlock, context: ToolContext) async throws -> Result<(rule: PlanRule, text: String, courseID: Course.ID?, block: StudyBlock?), Refusal> {
        let courses = try await CourseList.load(services.database)
        if let id = call.id("block") {
            guard let block = try await services.records.fetch(StudyBlock.self, id: id) else { return .failure("Unknown block. Use plan_query.") }
            guard block.state != .done else { return .failure("That block is done already.") }
            let rule = PlanRule(kind: .skip, first: block.day, last: block.day, courseID: block.courseID, blockKind: block.kind)
            let name = block.courseID.flatMap { courses.token(for: $0) }.map { " of \($0)" } ?? ""
            return .success((rule, "Skip \(Self.kindName(block.kind))\(name) on \(CoachText.day(block.day))", block.courseID, block))
        }
        let today = CalendarDay(context.now, in: zone)
        let first = day(call.text("first")) ?? today
        let last = day(call.text("last")) ?? first
        guard last >= first else { return .failure("last must not be before first.") }
        var courseID: Course.ID?
        if let token = call.text("course") {
            guard let course = courses.course(token) else { return .failure("Unknown course token.") }
            courseID = course.id
        }
        let kind = call.text("block_kind").map(StudyBlockKind.init(rawValue:))
        let days = weekdays(call)
        let rule = PlanRule(kind: .skip, weekdays: days, first: first, last: last, courseID: courseID, blockKind: kind)
        var text = "Skip \(Self.kindName(kind))"
        if let courseID, let token = courses.token(for: courseID) { text += " of \(token)" }
        text += " " + (first == last ? "on " : "") + Self.span(first, last)
        if let days { text += " (\(CoachText.weekdays(days)))" }
        return .success((rule, text, courseID, nil))
    }

    func capRule(_ call: ToolUseBlock, context: ToolContext) -> Result<(rule: PlanRule, text: String, courseID: Course.ID?, block: StudyBlock?), Refusal> {
        guard let minutes = call.integer("minutes"), (0...720).contains(minutes) else { return .failure("minutes must be 0 to 720 a day.") }
        let first = day(call.text("first"))
        let last = day(call.text("last"))
        if let first, let last, last < first { return .failure("last must not be before first.") }
        let days = weekdays(call)
        let rule = PlanRule(kind: .cap, weekdays: days, first: first, last: last, minutes: minutes)
        var text = "At most \(CoachText.duration(minutes: minutes)) of study a day"
        if let days { text += " on \(CoachText.weekdays(days))" }
        let span = Self.span(first, last)
        if !span.isEmpty { text += ", " + span }
        return .success((rule, text, nil, nil))
    }

    func courseRule(_ call: ToolUseBlock, action: String) async throws -> Result<(rule: PlanRule, text: String, courseID: Course.ID?, block: StudyBlock?), Refusal> {
        let courses = try await CourseList.load(services.database)
        guard let course = courses.course(call.text("course")) else { return .failure("course must be a course token.") }
        if action == "sitting" {
            guard let sitting = call.integer("sitting"), sitting == 1 || sitting == 2 else { return .failure("sitting must be 1 (first date) or 2 (second date).") }
            let rule = PlanRule(kind: .sitting, courseID: course.id, sitting: sitting)
            return .success((rule, "Sits the \(sitting == 2 ? "second" : "first") exam date of \(course.name)", course.id, nil))
        }
        guard let enabled = call.flag("enabled") else { return .failure("enabled must be true (weekly hours) or false (seminar steps only).") }
        let rule = PlanRule(kind: .seminarHours, courseID: course.id, enabled: enabled)
        return .success((rule, enabled ? "Weekly study hours for \(course.name)" : "Only seminar steps for \(course.name), no weekly hours", course.id, nil))
    }

    func attendRule(_ call: ToolUseBlock) async throws -> Result<(rule: PlanRule, text: String, courseID: Course.ID?, block: StudyBlock?), Refusal> {
        guard let id = call.id("session"), let session = try await services.records.fetch(LectureSession.self, id: id) else {
            return .failure("session must be a session's id (query_sessions).")
        }
        let attends = call.flag("enabled") ?? false
        let weekly = call.flag("every_week") ?? false
        if weekly, session.weeklySlotID == nil { return .failure("That session is a one-off; leave every_week false.") }
        let rule = PlanRule(
            kind: .attend, courseID: session.courseID, enabled: attends, slotID: weekly ? session.weeklySlotID : nil,
            sessionID: weekly ? nil : session.id
        )
        let courses = try await CourseList.load(services.database)
        let name = "\(courses.token(for: session.courseID) ?? "") \(session.kind.rawValue)"
        let when = weekly
            ? "every week (\(CoachText.dayTime(session.startsAt)))"
            : CoachText.dayTime(session.startsAt)
        let text = (attends ? "Attends \(name) after all, " : "Does not attend \(name), ") + when + (attends ? "" : "; reviews it from the recording")
        return .success((rule, text, session.courseID, nil))
    }

    /// Moves a block to another day: the row itself, `created_by = user` (a replan never moves or
    /// drops it), at the end of that day.
    func move(_ call: ToolUseBlock, context: ToolContext) async throws -> ToolOutput {
        guard let id = call.id("block"), let block = try await services.records.fetch(StudyBlock.self, id: id) else {
            return .error("block must be a block's id (plan_query).")
        }
        guard block.state == .planned else { return .error("Only a block not started yet can move.") }
        let today = CalendarDay(context.now, in: zone)
        guard let target = day(call.text("to_day")), target >= today, today.days(to: target) <= CoachRules.planDays else {
            return .error("to_day must be a day from today to \(CoachRules.planDays) days ahead, YYYY-MM-DD.")
        }
        let store = services.records
        let now = context.now
        let from = block.day
        try await services.database.write { db in
            let last = try StudyBlock.where { $0.day.eq(target) }.fetchAll(db).map(\.sortOrder).max() ?? -1
            var moved = block
            moved.day = target
            moved.sortOrder = last + 1
            moved.createdBy = .user
            moved.isAway = false
            moved.updatedAt = now
            let stamped = store.stamp(moved)
            try StudyBlock.upsert { stamped }.execute(db)
        }
        await coach?.replan()
        return .json([
            "moved": true, "block": ToolJSON.id(block.id), "title": .string(block.title), "from": .string(from.rawValue), "to": .string(target.rawValue),
        ])
    }

    // MARK: - mark_away_days

    var markAwayDays: AgentTool {
        AgentTool(
            tool: .custom(
                name: "mark_away_days",
                description: """
                    Marks days the student is away (travelling, at home): every week on the given weekdays and/or a date \
                    range. Those days get only phone-sized study (one short round, one short read) up to minutes a day; work \
                    due on them is planned the day before. Kept as a plan memory (forget undoes it).
                    """,
                inputSchema: Schema.object([
                    "weekdays": Self.weekdays,
                    "first": Schema.optionalString("First day, YYYY-MM-DD; null when every week."),
                    "last": Schema.optionalString("Last day, YYYY-MM-DD; null: open-ended (or the same as first for one day)."),
                    "minutes": Schema.nullable(Self.integer),
                    "quote": Schema.string("The student's words in the message you are answering that say it (at least 3 words)."),
                ])
            ),
            effect: .verifiedWrite
        ) { call, context in
            guard let quote = call.text("quote"),
                  let checked = try await applier.verify(quote, line: nil, material: .chat(context.conversationID, words: context.studentText, date: context.now))
            else { return .error("quote must be the student's words saying it (at least 3 words), copied exactly.") }
            let days = weekdays(call)
            let first = day(call.text("first"))
            var last = day(call.text("last"))
            if days == nil, let first, last == nil { last = first }
            guard days != nil || first != nil else { return .error("Give weekdays and/or first (and last).") }
            if let first, let last, last < first { return .error("last must not be before first.") }
            let minutes = call.integer("minutes")
            if let minutes, !(0...240).contains(minutes) { return .error("minutes must be 0 to 240 a day.") }
            let rule = PlanRule(kind: .away, weekdays: days, first: first, last: last, minutes: minutes)
            var text = "Away"
            if let days { text += " \(CoachText.weekdays(days))" + (first == nil && last == nil ? " every week" : "") }
            let span = Self.span(first, last)
            if !span.isEmpty { text += (days == nil ? " " : ", ") + span }
            text += ": at most \(CoachText.duration(minutes: minutes ?? PlanRule.awayMinutes)) of study a day"
            let output = try await remember(rule, text: text, courseID: nil, checked: checked, context: context)
            await coach?.replan()
            return output
        }
    }

    // MARK: - set_course_credits

    var setCourseCredits: AgentTool {
        AgentTool(
            tool: .custom(
                name: "set_course_credits",
                description: """
                    Records a course's credit points (ECTS / LP) and/or its stated self-study hours, as the student, a mail \
                    or the lecture states them (the self-study budget follows: stated hours, else credits × 30 h minus class \
                    hours). Undo puts the old values back.
                    """,
                inputSchema: Schema.object(writes.sourceProperties.merging([
                    "course": Schema.string("Course token."),
                    "credits": Schema.nullable(Self.number),
                    "self_study_hours": Schema.nullable(Self.number),
                ]) { first, _ in first })
            ),
            effect: .verifiedWrite
        ) { call, context in
            let checked: VerifiedQuote
            switch try await writes.verified(call, context: context) {
            case .success(let value): checked = value
            case .failure(let refusal): return .error(refusal.message)
            }
            let courses = try await CourseList.load(services.database)
            guard let course = courses.course(call.text("course")) else { return .error("course must be a course token.") }
            let credits = call.number("credits")
            let hours = call.number("self_study_hours")
            guard credits != nil || hours != nil else { return .error("Give credits and/or self_study_hours.") }
            for value in [credits, hours].compactMap({ $0 }) where !Self.states(value, in: checked.quote) {
                return .error("The quote must state \(CoachCatalogNumber.text(value)).")
            }
            let taskID = try await AgentTaskRepository(store: services.records).taskID(conversation: context.conversationID)
            let origin = ChangeLog.Origin(
                source: checked.source, sourceDate: checked.reference, model: ClaudeModel.opus55.rawValue, taskID: taskID,
                conversationID: context.conversationID, trusted: checked.trusted
            )
            let outcome = try await changeLog.apply(.courseCredits(course.id, credits: credits, selfStudyHours: hours), quote: checked.quote, origin: origin)
            await coach?.replan()
            switch outcome {
            case .applied(let change):
                return .json(["applied": true, "cite": .string(change.citation.marker), "title": .string(change.title), "summary": .string(change.summary)])
            case .unchanged(let text):
                return .json(["applied": false, "note": .string(text)])
            case .conflict(let text), .refused(let text):
                return .error(text)
            }
        }
    }

    /// The quote names the number ("6 ECTS", "6,0 LP", "180 Stunden").
    static func states(_ value: Double, in quote: String) -> Bool {
        var numbers: [Double] = []
        var current = ""
        for character in quote + " " {
            if character.isASCII, character.isNumber || ((character == "." || character == ",") && !current.isEmpty) {
                current.append(character)
            } else if !current.isEmpty {
                let cleaned = current.trimmingCharacters(in: CharacterSet(charactersIn: ".,")).replacingOccurrences(of: ",", with: ".")
                if let number = Double(cleaned) { numbers.append(number) }
                current = ""
            }
        }
        return numbers.contains { abs($0 - value) < 0.001 }
    }
}

/// Numbers as the tools say them ("6", "7.5").
enum CoachCatalogNumber {
    static func text(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
}

// MARK: - The university profile's items

/// mc: the university profile's own items (plan §4 "Profile items"): each registration window
/// `ProfileItems.wanted` names becomes one "Register for exams" deadline through the change log
/// (source `profile`, the window's rule as the quote; listed, undoable). A window whose key has a
/// change row (applied or undone) is never added again.
enum ProfileItemWriter {
    static func apply(services: StudyServices, changeLog: ChangeLog, now: Date) async throws {
        let profile = SourceRef.Kind.profile
        let (wanted, known) = try await services.database.read { db in
            (
                try ProfileItems.wanted(db: db, now: now),
                Set(try AgentChange.where { $0.sourceKind.eq(profile) }.fetchAll(db).map(\.rfcMessageID))
            )
        }
        for item in wanted where !known.contains(item.key) {
            let origin = ChangeLog.Origin(source: .external(.profile, reference: item.key), sourceDate: now, model: "")
            _ = try await changeLog.apply(.itemAdd(item.draft, dateVerified: true), quote: item.quote, origin: origin)
        }
    }
}
