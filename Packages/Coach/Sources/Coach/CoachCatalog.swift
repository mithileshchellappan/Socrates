import ClaudeKit
import Foundation
import StudyCore

/// What the app agent knows of the coach (plan §4 "Agent tools"): the catalog's lines (one per
/// course: credits · budget · Ready · this week · exam; and today's plan in one line) and
/// `plan_query`'s answer. Both computed from `CoachRows` with StudyCore's measures, as the screens.
public enum CoachCatalog {
    /// The catalog's coach lines, built in the catalog's read. `token`: the course token the
    /// catalog names a course by ("DC"). Measured at the start of today, so the lines change only
    /// with the data (the catalog is sent again only when it changed).
    public static func lines(db: Database, now: Date, token: (Course.ID?) -> String) throws -> [String] {
        let zone = CoachModule.timeZone
        let dayStart = CalendarDay(now, in: zone).start(in: zone)
        let rows = try CoachRows.load(db, now: dayStart)
        var lines: [String] = []
        for status in rows.statuses {
            lines.append("coach \(token(status.course.id)): " + courseLine(status, rows: rows))
        }
        lines.append(planLine(rows, token: token))
        return lines
    }

    static func courseLine(_ status: CoachRows.CourseStatus, rows: CoachRows) -> String {
        var parts: [String] = []
        let course = status.course
        if let credits = course.credits {
            parts.append("\(number(credits)) credits")
        } else {
            parts.append("credits unknown (planned with \(number(rows.profile.defaultCredits)); ask the student once)")
        }
        if let stated = course.selfStudyHours {
            parts.append("self-study \(number(stated)) h (stated)")
        } else {
            parts.append("self-study \(number(status.budget.totalHours.rounded())) h")
        }
        if let ready = status.ready { parts.append("Ready \(Int((ready * 100).rounded()))%") }
        if status.weeklyShare > 0 {
            parts.append("this week \(CoachText.duration(seconds: status.studiedThisWeek)) of \(CoachText.duration(seconds: status.weeklyShare))")
        } else if status.studiedThisWeek > 0 {
            parts.append("this week \(CoachText.duration(seconds: status.studiedThisWeek))")
        }
        if status.isSeminar {
            parts.append(rows.rules.plansSeminarHours(course.id) ? "seminar (weekly hours on)" : "seminar (steps only)")
        } else if let exam = status.exams.sat?.dueAt {
            var text = (status.exams.sitsSecondDate ? "second date " : "exam ") + CoachText.dayTime(exam, allDay: status.exams.sat?.isAllDay ?? false)
            if !status.exams.sitsSecondDate, let second = status.exams.second?.dueAt {
                text += " (second date \(CoachText.dayTime(second, allDay: status.exams.second?.isAllDay ?? false)))"
            }
            parts.append(text)
        }
        if let runway = status.budget.runwayStart, rows.today >= runway, let exam = status.examDay, rows.today <= exam {
            parts.append("exam runway")
        }
        return parts.joined(separator: " · ")
    }

    static func planLine(_ rows: CoachRows, token: (Course.ID?) -> String) -> String {
        let blocks = rows.blocks.filter { $0.day == rows.today && $0.state != .skipped }.sorted { $0.sortOrder < $1.sortOrder }
        guard !blocks.isEmpty else { return "plan today: nothing planned" }
        let total = blocks.reduce(0) { $0 + $1.minutes }
        var head = "plan today (\(CoachText.duration(minutes: total)) planned"
        if rows.rules.isAway(rows.today) { head += ", away day" }
        head += "): "
        return head + blocks.map { block in
            var text = block.title
            if !block.detail.isEmpty { text += " " + block.detail }
            var meta = block.courses.map { token($0) }
            meta.append(CoachText.duration(minutes: block.minutes))
            if block.state != .planned { meta.append(block.state.rawValue) }
            return text + " (" + meta.joined(separator: ", ") + ")"
        }.joined(separator: " · ")
    }

    static func number(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }

    // MARK: - plan_query

    /// `plan_query`'s answer: the blocks of `first…last` with states and minutes, each day's
    /// total, per course the budget, this week's studied time and share, Ready and the exam sat,
    /// and the plan rules in effect with their memory keys.
    public static func report(db: Database, now: Date, from first: CalendarDay, through last: CalendarDay, token: (Course.ID?) -> String) throws -> JSONValue {
        let rows = try CoachRows.load(db, now: now)
        let extra = try StudyBlock
            .where { $0.day.gte(first) && $0.day.lte(last) }
            .order { ($0.day, $0.sortOrder, $0.createdAt) }
            .fetchAll(db)
        var days: [JSONValue] = []
        var day = first
        while day <= last {
            let blocks = extra.filter { $0.day == day }
            let total = blocks.filter { $0.state != .skipped }.reduce(0) { $0 + $1.minutes }
            days.append([
                "day": .string(day.rawValue),
                "date": .string(CoachText.day(day)),
                "away": .bool(rows.rules.isAway(day)),
                "planned": .string(CoachText.duration(minutes: total)),
                "blocks": .array(blocks.map { block in
                    [
                        "block": .string(block.id.uuidString.lowercased()),
                        "kind": .string(block.kind.rawValue),
                        "courses": .array(block.courses.map { .string(token($0)) }),
                        "title": .string(block.title),
                        "detail": .string(block.detail),
                        "why": .string(block.why),
                        "minutes": .int(block.minutes),
                        "state": .string(block.state.rawValue),
                        "by": .string(block.createdBy == .user ? "student" : "planner"),
                    ]
                }),
            ])
            day = day.adding(days: 1)
        }
        let courses: [JSONValue] = rows.statuses.map { status in
            var object: JSONObject = [
                "course": .string(token(status.course.id)),
                "credits": status.course.credits.map { .double($0) } ?? .null,
                "self_study_hours": status.course.selfStudyHours.map { .double($0) } ?? .null,
                "budget_hours": .double(status.budget.totalHours.rounded()),
                "this_week": .string(CoachText.duration(seconds: status.studiedThisWeek)),
                "week_share": .string(CoachText.duration(seconds: status.weeklyShare)),
                "ready": status.ready.map { .string("\(Int(($0 * 100).rounded()))%") } ?? .null,
                "seminar": .bool(status.isSeminar),
                "credits_unknown": .bool(status.creditsUnknown),
            ]
            object["exam"] = status.exams.first?.dueAt.map { .string(CoachText.dayTime($0, allDay: status.exams.first?.isAllDay ?? false)) } ?? .null
            object["second_date"] = status.exams.second?.dueAt.map { .string(CoachText.dayTime($0, allDay: status.exams.second?.isAllDay ?? false)) } ?? .null
            object["sits"] = .string(status.exams.sitsSecondDate ? "second date" : "first date")
            object["runway_from"] = status.budget.runwayStart.map { .string($0.rawValue) } ?? .null
            return .object(object)
        }
        let rules: [JSONValue] = rows.planMemories.compactMap { memory in
            guard let rule = memory.planRule else { return nil }
            return [
                "memory": .string(ChatCitation.key(memory.id)),
                "kind": .string(rule.kind.rawValue),
                "text": .string(memory.text),
                "expired": .bool(rule.hasExpired(before: rows.today)),
            ]
        }
        return [
            "today": .string(rows.today.rawValue),
            "days": .array(days),
            "courses": .array(courses),
            "rules": .array(rules),
        ]
    }
}
