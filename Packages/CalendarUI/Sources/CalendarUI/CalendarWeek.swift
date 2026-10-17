import Courses
import Foundation
import StudyCore
import StudyUI

/// One ISO 8601 week, Monday to Sunday: what the grid shows.
struct CalendarWeek: Hashable, Sendable {
    let monday: CalendarDay

    /// The week `day` falls in.
    init(containing day: CalendarDay) {
        monday = day.adding(days: 1 - day.weekday)
    }

    var days: [CalendarDay] { (0..<7).map { monday.adding(days: $0) } }
    var sunday: CalendarDay { monday.adding(days: 6) }

    func adding(weeks: Int) -> CalendarWeek {
        CalendarWeek(containing: monday.adding(days: 7 * weeks))
    }

    /// 0 (Monday) … 6 (Sunday), or nil when `day` is in another week.
    func index(of day: CalendarDay) -> Int? {
        let offset = monday.days(to: day)
        return (0..<7).contains(offset) ? offset : nil
    }

    /// The ISO 8601 week number: the week of the year's first Thursday is week 1.
    var number: Int {
        let thursday = monday.adding(days: 3)
        return CalendarDay(year: thursday.year, month: 1, day: 1).days(to: thursday) / 7 + 1
    }

    /// Local midnight on Monday.
    func start(in timeZone: TimeZone) -> Date { monday.start(in: timeZone) }
    /// Local midnight after Sunday (a week with a clock change is an hour longer or shorter).
    func end(in timeZone: TimeZone) -> Date { monday.adding(days: 7).start(in: timeZone) }
}

/// Words and times of the Calendar screen.
enum CalendarText {
    /// "October 2026"; "Oct – Nov 2026" across two months; "Dec 2026 – Jan 2027" across years.
    static func title(_ week: CalendarWeek, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let first = week.monday
        let last = week.sunday
        let full = calendar.standaloneMonthSymbols
        let short = calendar.shortStandaloneMonthSymbols
        guard full.count == 12, short.count == 12 else { return "\(first.year)" }
        if first.month == last.month, first.year == last.year {
            return "\(full[first.month - 1]) \(first.year)"
        }
        if first.year == last.year {
            return "\(short[first.month - 1]) – \(short[last.month - 1]) \(first.year)"
        }
        return "\(short[first.month - 1]) \(first.year) – \(short[last.month - 1]) \(last.year)"
    }

    /// "Week 43".
    static func subtitle(_ week: CalendarWeek) -> String {
        String(localized: "Week \(week.number)")
    }

    /// The day header's weekday: "Mon".
    static func weekday(_ day: CalendarDay, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortStandaloneWeekdaySymbols // Sunday first
        guard symbols.count == 7 else { return "" }
        return symbols[day.weekday % 7]
    }

    /// A session in the grid, by the course's short name: "DC Lecture 3", "DC Exercise",
    /// "CL Tutorial" (mockup 06).
    static func eventTitle(_ session: LectureSession, course: Course?) -> String {
        let short = course?.shortName.trimmingCharacters(in: .whitespaces) ?? ""
        let name = short.isEmpty ? (course?.name ?? "") : short
        let kind = session.kind.displayName
        if session.kind == .lecture, let number = session.number {
            return name.isEmpty ? String(localized: "Lecture \(number)") : String(localized: "\(name) Lecture \(number)")
        }
        return name.isEmpty ? kind : "\(name) \(kind)"
    }

    /// The proposal card's question: "Move to Room 5?"; a cancellation "Cancelled?".
    static func question(_ proposal: TrackedItem) -> String {
        if proposal.kind == .roomChange, let room = proposal.room?.trimmingCharacters(in: .whitespaces), !room.isEmpty {
            return String(localized: "Move to \(room)?")
        }
        if proposal.kind == .cancellation { return String(localized: "Cancelled?") }
        return proposal.title
    }

    /// The dashed tag inside the session a proposal is about: "Room 5?", "Cancelled?".
    static func proposalTag(_ proposal: TrackedItem) -> String {
        if proposal.kind == .roomChange, let room = proposal.room?.trimmingCharacters(in: .whitespaces), !room.isEmpty {
            return "\(room)?"
        }
        return question(proposal)
    }

    /// The proposal card's grey line: "DC Lecture 4, Thu 22 Oct only".
    static func proposalDetail(
        _ proposal: TrackedItem, session: LectureSession?, course: Course?, locale: Locale, timeZone: TimeZone
    ) -> String {
        if let session {
            let day = DayText.day(session.startsAt, locale: locale, timeZone: timeZone)
            return String(localized: "\(eventTitle(session, course: course)), \(day) only")
        }
        guard let due = proposal.dueAt else { return "" }
        return String(localized: "\(DayText.day(due, locale: locale, timeZone: timeZone)) only")
    }
}

/// Wall-clock minutes after midnight, in a time zone.
enum WallClock {
    static func minute(of date: Date, in timeZone: TimeZone) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}
