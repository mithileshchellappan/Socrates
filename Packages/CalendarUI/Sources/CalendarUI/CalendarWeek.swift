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

    // MARK: Detail popover

    /// The detail popover's title of a session: "Data Centers · Lecture 3", "Data Centers ·
    /// Exercise 2" (the kind with its number when known).
    static func sessionTitle(_ session: LectureSession, course: Course?) -> String {
        let kind = session.number.map { "\(session.kind.displayName) \($0)" } ?? session.kind.displayName
        let name = course?.name.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? kind : "\(name) · \(kind)"
    }

    /// "weekly", "every 2 weeks" (as the timetable sheet writes a slot).
    static func recurrence(_ slot: WeeklySlot) -> String {
        switch slot.weekInterval {
        case ...1: String(localized: "weekly")
        case 2: String(localized: "every 2 weeks")
        default: String(localized: "every \(slot.weekInterval) weeks")
        }
    }

    /// A room as it is stored, split into the short room and the full location when it holds one:
    /// "B1-0101 (Room 101) Sample Street 1, …" → ("Room 101", "Sample Street 1, …");
    /// "Room 5" → ("Room 5", nil). Several rooms (" / ") give one location per line.
    static func place(_ stored: String) -> (room: String, location: String?) {
        let parts = stored.components(separatedBy: " / ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return ("", nil) }
        let rooms = parts.map { part in
            let room = TimetableText.room(fromLocation: part)
            return room.isEmpty ? part : room
        }
        let room = rooms.joined(separator: " / ")
        return (room, rooms == parts ? nil : parts.map(locationLine).joined(separator: "\n"))
    }

    /// An event block's title in the grid: the course's short name for its name, as sessions
    /// ("Computational Linguistics exam review" → "CL exam review").
    static func blockTitle(_ item: TrackedItem, course: Course?) -> String {
        guard let course else { return item.title }
        let short = course.shortName.trimmingCharacters(in: .whitespaces)
        let name = course.name.trimmingCharacters(in: .whitespaces)
        guard !short.isEmpty, !name.isEmpty,
              let range = item.title.range(of: name, options: [.anchored, .caseInsensitive, .diacriticInsensitive])
        else { return item.title }
        return short + item.title[range.upperBound...]
    }

    /// "B1-0101 (Room 101) Sample Street 1, Lecture Building (L | 01)" → "Sample Street 1, Lecture
    /// Building": the address without the room number, the room and the building code.
    static func locationLine(_ location: String) -> String {
        var text = location
        if let match = text.firstMatch(of: /\(([^()]+)\)/) {
            // Everything before the room's parenthesis is the room number ("B1-0101").
            text = String(text[match.range.upperBound...])
        }
        text = text.replacing(/\s*\([^()]*\|[^()]*\)\s*$/, with: "")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
        return trimmed.isEmpty ? location : trimmed
    }

    /// An item's short rooms ("Room 102 / Hall A"), from its stored location.
    static func rooms(_ item: TrackedItem) -> String {
        place(item.room ?? "").room
    }

    /// "Exam", "Exercise", "Deadline", "Event", "Task".
    static func kindName(_ kind: TrackedItemKind) -> String {
        switch kind {
        case .deadline: String(localized: "Deadline")
        case .exercise: String(localized: "Exercise")
        case .exam: String(localized: "Exam")
        case .event: String(localized: "Event")
        case .task: String(localized: "Task")
        case .announcement: String(localized: "Announcement")
        default: kind.rawValue.replacing("_", with: " ").capitalized
        }
    }

    /// "L2 · Virtualization & IaaS"; the title alone, or "Lecture 2", when a part is missing.
    static func lectureTitle(_ lecture: Lecture) -> String {
        let title = lecture.title.trimmingCharacters(in: .whitespaces)
        switch (lecture.number, title.isEmpty) {
        case (let number?, false): return "L\(number) · \(title)"
        case (let number?, true): return String(localized: "Lecture \(number)")
        case (nil, false): return title
        case (nil, true): return String(localized: "Lecture")
        }
    }

    /// "5 highlights, 3 not on the slides" (Today's hero line); nil before the study pass.
    static func studyLine(_ info: LectureInfo) -> String? {
        var parts: [String] = []
        switch info.highlights {
        case 0: break
        case 1: parts.append(String(localized: "1 highlight"))
        default: parts.append(String(localized: "\(info.highlights) highlights"))
        }
        if info.notOnSlides > 0 { parts.append(String(localized: "\(info.notOnSlides) not on the slides")) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// A settled or waiting change of a session as its popover names it: "Move to Room 5?",
    /// "Cancelled?" while it waits; "Moved to Room 5", "Cancelled" once confirmed; ma: "Moved to Thu
    /// 22 Oct, 10:15" (the session's new start) and "Extra session", applied on their own; another
    /// tied item by its title.
    static func change(_ item: TrackedItem, session: LectureSession? = nil, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        if item.kind == .timeChange {
            guard let start = session?.startsAt ?? item.dueAt else { return item.title }
            return String(localized: "Moved to \(DayText.dayTime(start, locale: locale, timeZone: timeZone))")
        }
        if item.kind == .extraSession { return String(localized: "Extra session") }
        guard item.kind.isSessionProposal, item.status != .open else {
            return item.kind.isSessionProposal ? question(item) : item.title
        }
        if item.kind == .roomChange, let room = item.room?.trimmingCharacters(in: .whitespaces), !room.isEmpty {
            return String(localized: "Moved to \(room)")
        }
        return item.kind == .cancellation ? String(localized: "Cancelled") : item.title
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
