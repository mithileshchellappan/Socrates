import Foundation
import StudyCore

/// One of the student's other calendars (not the app's own "Socrates" calendar), shown
/// read-only in the Calendar screen when its checkbox is on (PRD #36, docs/DESIGN.md §8.3).
public struct ForeignCalendar: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The account that holds it ("iCloud", "On My Mac", "Exchange").
    public var sourceTitle: String
    /// `#rrggbb`, the colour Calendar draws its events in.
    public var colorHex: String

    public init(id: String, title: String, sourceTitle: String, colorHex: String = CalendarInfo.defaultColorHex) {
        self.id = id
        self.title = title
        self.sourceTitle = sourceTitle
        self.colorHex = colorHex
    }
}

/// An event of another calendar: only what the week grid draws.
public struct ForeignEvent: Hashable, Sendable, Identifiable {
    /// Unique per occurrence (recurring events share their event identifier).
    public var id: String
    public var calendarID: String
    public var title: String
    public var startsAt: Date
    public var endsAt: Date
    public var isAllDay: Bool

    public init(id: String, calendarID: String, title: String, startsAt: Date, endsAt: Date, isAllDay: Bool = false) {
        self.id = id
        self.calendarID = calendarID
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.isAllDay = isAllDay
    }
}

/// The calendars the sidebar lists under Calendar.
public struct ForeignCalendarList: Hashable, Sendable {
    /// The account of the app's own calendar ("iCloud"; where it will be created when it does not
    /// exist yet); nil without full access.
    public var ownSourceTitle: String?
    /// Every other calendar, in the store's order.
    public var calendars: [ForeignCalendar]

    public init(ownSourceTitle: String? = nil, calendars: [ForeignCalendar] = []) {
        self.ownSourceTitle = ownSourceTitle
        self.calendars = calendars
    }

    public static let empty = ForeignCalendarList()
}

/// The student's other calendars and their events, read-only: implementations never write,
/// never create a calendar and never ask for access (without full access they return nothing).
public protocol ForeignCalendarSource: Sendable {
    func foreignCalendars() async -> ForeignCalendarList
    /// Events of `calendarIDs` overlapping `[start, end)`; the app's own calendar is never read.
    func foreignEvents(calendarIDs: [String], from start: Date, to end: Date) async -> [ForeignEvent]
}

extension CalendarMirror: ForeignCalendarSource {
    public func foreignCalendars() async -> ForeignCalendarList {
        guard await store.access() == .fullAccess else { return .empty }
        let calendars = await store.calendars()
        let sources = await store.sources()
        let titles = Dictionary(sources.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        let own = ownCalendar(in: calendars)
        var ownSource = own.flatMap { calendar in sources.first { $0.id == calendar.sourceID } }
        if ownSource == nil {
            // Not created yet: where the mirror will create it.
            ownSource = Self.preferredSource(sources, defaultSourceID: await store.defaultSourceID())
        }
        let others = calendars.filter { !isOwn($0, ownID: own?.id) }.map { calendar in
            ForeignCalendar(
                id: calendar.id, title: calendar.title, sourceTitle: titles[calendar.sourceID] ?? "", colorHex: calendar.colorHex
            )
        }
        return ForeignCalendarList(ownSourceTitle: ownSource?.title, calendars: others)
    }

    public func foreignEvents(calendarIDs: [String], from start: Date, to end: Date) async -> [ForeignEvent] {
        guard !calendarIDs.isEmpty, start < end, await store.access() == .fullAccess else { return [] }
        let calendars = await store.calendars()
        let ownID = ownCalendar(in: calendars)?.id
        let allowed = Set(calendars.filter { !isOwn($0, ownID: ownID) }.map(\.id))
        var events: [ForeignEvent] = []
        for calendarID in calendarIDs where allowed.contains(calendarID) {
            do {
                for event in try await store.events(calendarID: calendarID, from: start, to: end) {
                    let occurrence = "\(calendarID)|\(event.id ?? event.title)|\(event.startsAt.timeIntervalSince1970)"
                    events.append(ForeignEvent(
                        id: occurrence, calendarID: calendarID, title: event.title, startsAt: event.startsAt,
                        endsAt: event.endsAt, isAllDay: event.isAllDay
                    ))
                }
            } catch {
                Log.calendar.error("Reading another calendar failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return events.sorted { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }
    }

    /// The calendar the mirror writes to: the one it remembers, else one with its title, else one
    /// with its title from before the rename (which the next sync renames).
    private func ownCalendar(in calendars: [CalendarInfo]) -> CalendarInfo? {
        let saved = defaults.string(forKey: key("calendar"))
        return calendars.first { $0.id == saved } ?? calendars.first { $0.title == title }
            ?? calendars.first { $0.title == legacyTitle }
    }

    /// The app's own calendar (or one with its title, old or new, which the mirror would adopt).
    private func isOwn(_ calendar: CalendarInfo, ownID: String?) -> Bool {
        calendar.id == ownID || calendar.title == title || calendar.title == legacyTitle
    }
}
