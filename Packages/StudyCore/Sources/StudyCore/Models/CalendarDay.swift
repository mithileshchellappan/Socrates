import Foundation
import SQLiteData

/// A date without a time of day ("2026-10-12"), stored as TEXT `YYYY-MM-DD` and as that string in
/// JSON. Used for semester periods, breaks and weekly-slot validity, where a `Date` would drift by
/// the time zone offset.
///
/// Day arithmetic is proleptic Gregorian on day numbers, so it never fails and needs no calendar.
/// Converting to a `Date` needs a time zone (`start(in:)`, `date(minute:in:)`).
public struct CalendarDay: Hashable, Sendable, Comparable, RawRepresentable, QueryBindable,
    CustomStringConvertible, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Out-of-range values roll over ("2026-10-32" is 1 November).
    public init(year: Int, month: Int, day: Int) {
        let monthIndex = month - 1
        let first = Self.dayNumber(year: year + monthIndex.floorDivided(by: 12), month: monthIndex.modulo(12) + 1, day: 1)
        self.init(dayNumber: first + day - 1)
    }

    /// The day `days` days after 1970-01-01.
    public init(dayNumber days: Int) {
        // Howard Hinnant's civil_from_days.
        let z = days + 719_468
        let era = z.floorDivided(by: 146_097)
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        year = yoe + era * 400 + (m <= 2 ? 1 : 0)
        month = m
        day = d
    }

    /// The calendar day `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        let components = Self.calendar(timeZone).dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 1970, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// Parses `YYYY-MM-DD`; anything after the tenth character (e.g. a time) is ignored.
    public init?(rawValue: String) {
        let parts = rawValue.prefix(10).split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let value = CalendarDay(year: year, month: month, day: day)
        guard value.month == month, value.day == day else { return nil }
        self = value
    }

    public var rawValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { rawValue }

    /// Days since 1970-01-01.
    public var dayNumber: Int { Self.dayNumber(year: year, month: month, day: day) }

    /// ISO 8601 weekday: 1 = Monday … 7 = Sunday.
    public var weekday: Int { (dayNumber + 3).modulo(7) + 1 }

    public func adding(days: Int) -> CalendarDay { CalendarDay(dayNumber: dayNumber + days) }

    /// Days from `self` to `other` (positive when `other` is later).
    public func days(to other: CalendarDay) -> Int { other.dayNumber - dayNumber }

    /// Local midnight of this day in `timeZone`.
    public func start(in timeZone: TimeZone) -> Date {
        date(minute: 0, in: timeZone)
    }

    /// The instant `minute` minutes after local midnight on this day in `timeZone` (wall-clock
    /// time, so 10:15 stays 10:15 across a daylight-saving change).
    public func date(minute: Int, in timeZone: TimeZone) -> Date {
        let components = DateComponents(year: year, month: month, day: day, hour: minute / 60, minute: minute % 60)
        if let date = Self.calendar(timeZone).date(from: components) { return date }
        let utc = Double(dayNumber) * 86_400 + Double(minute) * 60
        return Date(timeIntervalSince1970: utc - Double(timeZone.secondsFromGMT()))
    }

    public static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool { lhs.dayNumber < rhs.dayNumber }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let value = CalendarDay(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a YYYY-MM-DD day: \(raw)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: - Helpers

    static func dayNumber(year: Int, month: Int, day: Int) -> Int {
        // Howard Hinnant's days_from_civil.
        let y = month <= 2 ? year - 1 : year
        let era = y.floorDivided(by: 400)
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func calendar(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

extension Int {
    fileprivate func floorDivided(by divisor: Int) -> Int {
        let quotient = self / divisor
        return (self % divisor != 0 && (self < 0) != (divisor < 0)) ? quotient - 1 : quotient
    }

    fileprivate func modulo(_ divisor: Int) -> Int {
        let remainder = self % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }
}
