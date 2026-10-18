import ClaudeKit
import Deadlines
import Foundation
import os
import StudyCore

/// The agent tool runtime (`AgentRuntime`: conversation kinds with fixed tool sets, append-only
/// turns, streaming, staged proposals), the deadline tools, transcript extraction
/// (`TranscriptItemPipeline`) and the composer (`DeadlineComposer`). Logs through
/// `Log.logger(category: "agent")`; never logs the student's words, quotes or transcript text at
/// `.public`.
public enum AgentModule {
    public static let moduleName = "Agent"

    /// `api_call.purpose` prefix of this package's calls ("agent.deadlines", "agent.transcript").
    public static let purposePrefix = "agent."

    /// `api_call.purpose` of transcript extraction calls.
    public static let transcriptPurpose = "agent.transcript"

    /// The purpose of a conversation kind's calls ("agent.deadlines"; ma: "agent.app", "agent.task").
    public static func purpose(of kind: ConversationKind) -> String { purposePrefix + kind.rawValue }

    /// ma: the app agent's model (its memory writes name it in the activity log).
    static let appModel = ClaudeModel.opus55.rawValue

    static let log = Log.logger(category: "agent")
}

/// ma: what conversation kinds built outside this package (the app agent and its sub-agents in
/// AppAgent) share with the deadline tools: strict schemas, the student's-words quote check, and
/// dates as the agent reads and writes them (the university's time zone).
public enum AgentToolSupport {
    /// A closed object schema, every property required (optional values nullable).
    public static func object(_ properties: JSONObject) -> JSONValue { DeadlineTools.Tools.object(properties) }

    public static func nullable(_ schema: JSONValue) -> JSONValue { DeadlineTools.Tools.nullable(schema) }

    /// The original span of the student's `words` that `quote` stands for (whitespace and
    /// typographic quotes normalized), at least 3 characters; nil when it is not in them.
    public static func span(of quote: String, in words: String) -> String? {
        DeadlineTools.Tools.span(of: quote, in: words)
    }

    /// "2026-10-20T12:00" (local) or "2026-10-20" (all-day), the university's time zone.
    public static func dateText(_ date: Date?, allDay: Bool) -> String? { AgentDates.text(date, allDay: allDay) }

    /// Parses "YYYY-MM-DDTHH:MM" (local) or "YYYY-MM-DD" (all-day), the university's time zone.
    public static func parseDate(_ text: String?, allDay: Bool) -> (date: Date, allDay: Bool)? {
        AgentDates.parse(text, allDay: allDay)
    }

    /// A date checked against the words it came from (`DateMentions`): verified when the day
    /// (and a stated time) is in them; a time the words do not state is dropped (all-day).
    public static func verify(
        _ due: (date: Date, allDay: Bool), in words: String, reference: Date
    ) -> (date: Date, allDay: Bool, verified: Bool) {
        AgentDates.verify(due, in: words, reference: reference)
    }

    /// "Fri 16 Oct 2026, 15:02" in the university's time zone.
    public static func spoken(_ date: Date) -> String { AgentDates.spoken(date) }

    /// "Mon 12 Oct 2026".
    public static func dayText(_ day: CalendarDay) -> String { AgentDates.dayText(day) }

    /// The tracked items whose text a mail or a lecture wrote (any source other than the
    /// student's words): their titles go to a model as `untrusted_title`, without details.
    public static func untrustedItems(_ ids: [TrackedItem.ID], services: StudyServices) async throws -> Set<TrackedItem.ID> {
        try await DeadlineTools.Tools(services: services, memory: DeadlineMemory(services: services)).untrustedItems(ids)
    }
}

extension ToolUseBlock {
    /// ma: a trimmed, non-empty string input (AppAgent's tools).
    public func trimmedString(_ key: String) -> String? { string(key) }

    /// ma: a boolean input.
    public func boolean(_ key: String) -> Bool? { bool(key) }
}

extension Calendar {
    /// Gregorian in `timeZone`, POSIX locale.
    static func gregorian(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }
}

/// Dates as the agent reads and writes them, in the university's time zone.
enum AgentDates {
    static let timeZone = DeadlinesModule.timeZone

    /// "2026-10-20T12:00" (local) or "2026-10-20" (all-day).
    static func text(_ date: Date?, allDay: Bool) -> String? {
        guard let date else { return nil }
        let day = CalendarDay(date, in: timeZone)
        guard !allDay else { return day.rawValue }
        let minute = DateMentions.minute(of: date, timeZone: timeZone)
        return day.rawValue + String(format: "T%02d:%02d", minute / 60, minute % 60)
    }

    /// Parses "YYYY-MM-DDTHH:MM" (local) or "YYYY-MM-DD" (all-day).
    static func parse(_ text: String?, allDay: Bool) -> (date: Date, allDay: Bool)? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), let day = CalendarDay(rawValue: text) else { return nil }
        let rest = text.dropFirst(10).drop { $0 == "T" || $0 == " " || $0 == "t" }
        let parts = rest.split(separator: ":")
        if !allDay, parts.count >= 2, let hour = Int(parts[0]), let minute = Int(parts[1].prefix(2)),
           (0...24).contains(hour), (0..<60).contains(minute) {
            let minutes = min(hour * 60 + minute, 23 * 60 + 59)
            return (day.date(minute: minutes, in: timeZone), false)
        }
        return (day.start(in: timeZone), true)
    }

    /// "Mon 12 Oct 2026".
    static func dayText(_ day: CalendarDay) -> String {
        let weekday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][(day.weekday - 1 + 7) % 7]
        let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][(day.month - 1 + 12) % 12]
        return "\(weekday) \(day.day) \(month) \(day.year)"
    }

    /// "Fri 16 Oct 2026, 15:02".
    static func spoken(_ date: Date) -> String {
        let parts = Calendar.gregorian(in: timeZone).dateComponents([.weekday, .day, .month, .year, .hour, .minute], from: date)
        let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][((parts.weekday ?? 1) - 1 + 7) % 7]
        let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][((parts.month ?? 1) - 1 + 12) % 12]
        return "\(weekday) \(parts.day ?? 1) \(month) \(parts.year ?? 2026), " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A due date checked against the words it came from: verified when `DateMentions` finds the
    /// day (and the stated time); a time the words do not state is dropped (all-day).
    static func verify(_ due: (date: Date, allDay: Bool), in words: String, reference: Date) -> (date: Date, allDay: Bool, verified: Bool) {
        let mentions = DateMentions.parse(words, reference: reference, timeZone: timeZone)
        switch mentions.verdict(for: due.date, allDay: due.allDay, timeZone: timeZone) {
        case .confirmed(let withTime):
            if !withTime, !due.allDay {
                return (CalendarDay(due.date, in: timeZone).start(in: timeZone), true, true)
            }
            return (due.date, due.allDay, true)
        case .unconfirmed:
            return (due.date, due.allDay, false)
        }
    }
}

/// The courses as the agent names them: a short upper-case token each ("DC", "CL", "SN").
struct CourseTokens: Sendable {
    struct Entry: Sendable {
        var token: String
        var course: Course
    }

    let entries: [Entry]

    init(_ courses: [Course]) {
        var used: Set<String> = []
        entries = courses.map { course in
            let base = Self.baseToken(course)
            var token = base
            var counter = 2
            while used.contains(token) {
                token = "\(base)\(counter)"
                counter += 1
            }
            used.insert(token)
            return Entry(token: token, course: course)
        }
    }

    static func baseToken(_ course: Course) -> String {
        let short = course.shortName.trimmingCharacters(in: .whitespaces)
        if !short.isEmpty { return short.uppercased().replacingOccurrences(of: " ", with: "") }
        let initials = TextFolding.words(course.name).compactMap(\.first).map { String($0).uppercased() }.joined()
        return initials.isEmpty ? "C" : initials
    }

    static func load(_ database: any DatabaseReader) async throws -> CourseTokens {
        CourseTokens(try await database.read { db in try Course.order(by: \.sortOrder).fetchAll(db) })
    }

    func token(for courseID: Course.ID?) -> String? {
        guard let courseID else { return nil }
        return entries.first { $0.course.id == courseID }?.token
    }

    /// A course by token, name, short name or id.
    func course(_ reference: String?) -> Course? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        if let id = UUID(uuidString: reference) { return entries.first { $0.course.id == id }?.course }
        let folded = TextFolding.fold(reference)
        return entries.first { entry in
            TextFolding.fold(entry.token) == folded || TextFolding.fold(entry.course.name) == folded
                || (!entry.course.shortName.isEmpty && TextFolding.fold(entry.course.shortName) == folded)
        }?.course
    }

    /// One line per course: "DC: Data Centers; lecturers: Prof. Dr. Ada Example".
    var promptLines: String {
        guard !entries.isEmpty else { return "(no courses yet)" }
        return entries.map { entry in
            var line = "\(entry.token): \(entry.course.name)"
            if !entry.course.professors.isEmpty { line += "; lecturers: \(entry.course.professors.joined(separator: ", "))" }
            return line
        }
        .joined(separator: "\n")
    }
}
