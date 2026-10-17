import CoreGraphics
import EventKit
import Foundation
import StudyCore

/// `CalendarStore` over EventKit. One `EKEventStore` per instance, used only from this actor.
public actor EventKitCalendarStore: CalendarStore {
    private let store = EKEventStore()

    /// EventKit's event predicates span at most four years; longer ranges are read in windows.
    private static let window: TimeInterval = 3 * 365 * 86_400

    public init() {}

    public func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .fullAccess
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    public func requestFullAccess() async throws -> Bool {
        let granted: Bool = try await withCheckedThrowingContinuation { continuation in
            store.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
        if granted { store.refreshSourcesIfNecessary() }
        return granted
    }

    public func sources() -> [CalendarSource] {
        store.sources.map { source in
            CalendarSource(id: source.sourceIdentifier, title: source.title, kind: Self.kind(of: source))
        }
    }

    public func defaultSourceID() -> String? {
        store.defaultCalendarForNewEvents?.source?.sourceIdentifier
    }

    public func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map(Self.info)
    }

    public func createCalendar(title: String, colorHex: String?, sourceID: String) throws -> CalendarInfo {
        guard let source = store.sources.first(where: { $0.sourceIdentifier == sourceID }) else {
            throw CalendarStoreError.sourceNotFound
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = title
        calendar.source = source
        if let colorHex, let color = Self.color(hex: colorHex) {
            calendar.cgColor = color
        }
        try store.saveCalendar(calendar, commit: true)
        return Self.info(calendar)
    }

    public func event(id: String, calendarID: String) -> CalendarEvent? {
        ekEvent(id: id, calendarID: calendarID).map(Self.value)
    }

    public func events(calendarID: String, from start: Date, to end: Date) -> [CalendarEvent] {
        guard start < end, let calendar = store.calendar(withIdentifier: calendarID) else { return [] }
        var seen = Set<String>()
        var result: [CalendarEvent] = []
        var windowStart = start
        while windowStart < end {
            let windowEnd = min(end, windowStart.addingTimeInterval(Self.window))
            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: [calendar])
            for event in store.events(matching: predicate) {
                let value = Self.value(event)
                guard let id = value.id, seen.insert(id).inserted else { continue }
                result.append(value)
            }
            windowStart = windowEnd
        }
        return result
    }

    public func save(_ value: CalendarEvent, calendarID: String) throws -> String {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw CalendarStoreError.calendarNotFound }
        let event: EKEvent
        if let id = value.id, let existing = ekEvent(id: id, calendarID: calendarID) {
            event = existing
        } else {
            event = EKEvent(eventStore: store)
            event.calendar = calendar
        }
        event.title = value.title
        event.location = value.location
        event.url = value.url
        event.notes = value.notes
        event.startDate = value.startsAt
        event.endDate = value.endsAt
        try store.save(event, span: .thisEvent, commit: true)
        if let external = event.calendarItemExternalIdentifier, !external.isEmpty { return external }
        return event.calendarItemIdentifier
    }

    public func removeEvent(id: String, calendarID: String) throws {
        guard let event = ekEvent(id: id, calendarID: calendarID) else { return }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    // MARK: - Helpers

    /// Looks an event up by external identifier, then by local identifier, in one calendar only.
    private func ekEvent(id: String, calendarID: String) -> EKEvent? {
        let external = store.calendarItems(withExternalIdentifier: id)
            .compactMap { $0 as? EKEvent }
            .first { $0.calendar?.calendarIdentifier == calendarID }
        if let external { return external }
        if let local = store.calendarItem(withIdentifier: id) as? EKEvent, local.calendar?.calendarIdentifier == calendarID {
            return local
        }
        return nil
    }

    private static func value(_ event: EKEvent) -> CalendarEvent {
        let external = event.calendarItemExternalIdentifier
        return CalendarEvent(
            id: (external?.isEmpty == false) ? external : event.calendarItemIdentifier,
            title: event.title ?? "",
            location: event.location,
            url: event.url,
            notes: event.notes,
            startsAt: event.startDate,
            endsAt: event.endDate
        )
    }

    private static func info(_ calendar: EKCalendar) -> CalendarInfo {
        CalendarInfo(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            sourceID: calendar.source?.sourceIdentifier ?? "",
            allowsModifications: calendar.allowsContentModifications
        )
    }

    private static func kind(of source: EKSource) -> CalendarSource.Kind {
        switch source.sourceType {
        case .calDAV: source.title.localizedCaseInsensitiveContains("icloud") ? .iCloud : .calDAV
        case .local: .local
        case .exchange: .exchange
        default: .other
        }
    }

    private static func color(hex: String) -> CGColor? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return CGColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }
}

public enum CalendarStoreError: Error, Equatable {
    case sourceNotFound
    case calendarNotFound
}
