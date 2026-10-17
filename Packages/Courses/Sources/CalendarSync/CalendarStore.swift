import Foundation

/// The calendar database as the mirror needs it: EventKit in the app (`EventKitCalendarStore`),
/// an in-memory fake in tests. Calendars are identified by `calendarIdentifier`, events by
/// `calendarItemExternalIdentifier`.
public protocol CalendarStore: Sendable {
    /// Current permission to read and write events.
    func access() async -> CalendarAccess
    /// Asks for full access (the system prompt, once). True when granted.
    func requestFullAccess() async throws -> Bool
    /// Accounts that can hold calendars (iCloud, On My Mac, Exchange, …).
    func sources() async -> [CalendarSource]
    /// The source of the user's default calendar for new events, if any.
    func defaultSourceID() async -> String?
    /// Event calendars.
    func calendars() async -> [CalendarInfo]
    func createCalendar(title: String, colorHex: String?, sourceID: String) async throws -> CalendarInfo
    /// The event with this identifier in `calendarID`; nil when it is gone or in another calendar.
    func event(id: String, calendarID: String) async throws -> CalendarEvent?
    /// Events of `calendarID` overlapping `[start, end)`.
    func events(calendarID: String, from start: Date, to end: Date) async throws -> [CalendarEvent]
    /// Creates (`event.id` nil) or updates an event in `calendarID`; returns its identifier.
    func save(_ event: CalendarEvent, calendarID: String) async throws -> String
    /// Removes the event when it is in `calendarID`; never touches other calendars.
    func removeEvent(id: String, calendarID: String) async throws
}

public enum CalendarAccess: Hashable, Sendable {
    case notDetermined
    case denied
    case restricted
    case writeOnly
    case fullAccess
}

/// An account that holds calendars.
public struct CalendarSource: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case iCloud
        case local
        case calDAV
        case exchange
        case other
    }

    public var id: String
    public var title: String
    public var kind: Kind

    public init(id: String, title: String, kind: Kind) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

public struct CalendarInfo: Hashable, Sendable {
    public var id: String
    public var title: String
    public var sourceID: String
    public var allowsModifications: Bool

    public init(id: String, title: String, sourceID: String, allowsModifications: Bool = true) {
        self.id = id
        self.title = title
        self.sourceID = sourceID
        self.allowsModifications = allowsModifications
    }
}

/// The parts of an event the mirror writes and compares.
public struct CalendarEvent: Hashable, Sendable {
    /// `calendarItemExternalIdentifier`; nil for an event not saved yet.
    public var id: String?
    public var title: String
    public var location: String?
    public var url: URL?
    public var notes: String?
    public var startsAt: Date
    public var endsAt: Date
    /// An all-day event (a deadline without a time): `startsAt` is the day's start.
    public var isAllDay: Bool

    public init(
        id: String? = nil,
        title: String,
        location: String? = nil,
        url: URL? = nil,
        notes: String? = nil,
        startsAt: Date,
        endsAt: Date,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.url = url
        self.notes = notes
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
    }

    /// Same visible content (identifier ignored; empty and missing text are the same).
    public func hasSameContent(as other: CalendarEvent) -> Bool {
        title == other.title
            && (location ?? "") == (other.location ?? "")
            && url == other.url
            && (notes ?? "") == (other.notes ?? "")
            && isAllDay == other.isAllDay
            && abs(startsAt.timeIntervalSince(other.startsAt)) < 1
            && (isAllDay || abs(endsAt.timeIntervalSince(other.endsAt)) < 1)
    }
}
