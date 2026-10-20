import Foundation
import StudyCore

extension SessionKind {
    /// The kinds a weekly slot offers, in menu order.
    public static let slotKinds: [SessionKind] = [.lecture, .exercise, .tutorial, .seminar]

    /// "Lecture", "Exercise", "Tutorial", "Seminar" (other kinds: the raw value, capitalised).
    public var displayName: String {
        switch self {
        case .lecture: String(localized: "Lecture")
        case .exercise: String(localized: "Exercise")
        case .tutorial: String(localized: "Tutorial")
        case .seminar: String(localized: "Seminar")
        default: rawValue.replacing("_", with: " ").capitalized
        }
    }
}

/// Words and times for sessions, shared by Today, course settings and the calendar mirror.
public struct SessionText: Sendable {
    public var locale: Locale
    public var timeZone: TimeZone

    public init(locale: Locale = .current, timeZone: TimeZone = .current) {
        self.locale = locale
        self.timeZone = timeZone
    }

    /// Calendar event title: "Data Centers", "Data Centers · Exercise".
    public static func eventTitle(courseName: String, kind: SessionKind) -> String {
        kind == .lecture ? courseName : "\(courseName) · \(kind.displayName)"
    }

    /// A session's name in lists that mix courses: "Data Centers Lecture 3" for numbered
    /// lectures, else "Data Centers exercise". A long course name gives way to its short name
    /// when there is one ("CL tutorial", mockup 01; "Data Centers exercise" stays).
    public static func title(of session: LectureSession, courseName: String, shortName: String = "") -> String {
        let short = shortName.trimmingCharacters(in: .whitespaces)
        let courseName = !short.isEmpty && isLong(courseName) ? short : courseName
        if session.kind == .lecture, let number = session.number {
            return courseName.isEmpty ? String(localized: "Lecture \(number)") : String(localized: "\(courseName) Lecture \(number)")
        }
        let kind = session.kind.displayName.lowercased(with: Locale(identifier: "en"))
        return courseName.isEmpty ? session.kind.displayName : "\(courseName) \(kind)"
    }

    /// Longer than "Data Centers": three words or more, or over 16 characters.
    static func isLong(_ name: String) -> Bool {
        name.count > 16 || name.split(whereSeparator: \.isWhitespace).count >= 3
    }

    /// "10:15" (24-hour, wall clock in `timeZone`).
    public func time(_ date: Date) -> String {
        date.formatted(Self.clock(timeZone))
    }

    /// "10:15–11:45".
    public func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start))–\(time(end))"
    }

    /// "10:15–11:45" for a slot's minutes after midnight.
    public static func minutes(_ start: Int, _ end: Int) -> String {
        func clock(_ minute: Int) -> String {
            let wrapped = ((minute % 1440) + 1440) % 1440
            return String(format: "%02d:%02d", wrapped / 60, wrapped % 60)
        }
        return "\(clock(start))–\(clock(end))"
    }

    /// "Mon 19 Oct" (German "Mo. 19 Okt."): weekday, day, month whatever the region, the pattern
    /// of StudyUI's `DayText` that the sidebar and the other screens use.
    public func day(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(weekday: .abbreviated) \(day: .defaultDigits) \(month: .abbreviated)",
            locale: locale,
            timeZone: timeZone,
            calendar: Calendar(identifier: .gregorian)
        ))
    }

    /// "Wednesday".
    public func weekday(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.wide))
    }

    /// "Friday, 16 October 2026".
    public func fullDate(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).weekday(.wide).day().month(.wide).year())
    }

    /// "Wed" for an ISO weekday (1 = Monday).
    public func shortWeekday(_ isoWeekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.shortWeekdaySymbols // Sunday first
        guard (1...7).contains(isoWeekday), symbols.count == 7 else { return "" }
        return symbols[isoWeekday % 7]
    }

    /// "Wednesday" for an ISO weekday.
    public func weekdayName(_ isoWeekday: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let symbols = calendar.weekdaySymbols
        guard (1...7).contains(isoWeekday), symbols.count == 7 else { return "" }
        return symbols[isoWeekday % 7]
    }

    private static func clock(_ zone: TimeZone) -> Date.VerbatimFormatStyle {
        Date.VerbatimFormatStyle(
            format: "\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: zone,
            calendar: Calendar(identifier: .gregorian)
        )
    }
}
