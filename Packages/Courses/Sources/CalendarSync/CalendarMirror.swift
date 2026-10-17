import Courses
import Foundation
import StudyCore

/// Mirrors lecture sessions into the app's own "Study Portal" calendar (PRD #36).
///
/// - Writes only to that calendar, found by the identifier remembered in `UserDefaults`, else an
///   existing writable calendar with its title (iCloud first), else a new one in the iCloud
///   source (falling back to the default calendar's source, then a local one).
/// - One event per visible session: title = course name (+ " · Exercise" …), location = room,
///   `url = studyportal://session/<uuid>`, no notes. The event's identifier is stored in
///   `lecture_session.calendar_event_id`.
/// - `sync()` writes sessions that changed, removes events of cancelled sessions and hidden
///   courses, and removes events carrying our URL prefix that no session owns any more. Events
///   without that prefix (deadlines, anything the user added) are never touched.
/// - Without full access it does nothing and throws nothing; nothing is recorded, so the work
///   waits for the next sync.
public actor CalendarMirror {
    public static let defaultCalendarTitle = "Study Portal"
    public static let urlScheme = "studyportal"
    public static let urlPrefix = "studyportal://session/"

    private let services: StudyServices
    private let store: any CalendarStore
    private let defaults: any CalendarMirrorDefaults
    private let title: String
    private let scope: String
    private var running: Task<CalendarSyncReport, any Error>?

    /// - Parameters:
    ///   - calendarTitle: nil = "Study Portal" for the real library, "Study Portal (<folder>)"
    ///     for a library relocated with `STUDYPORTAL_DATA_ROOT`, so a throwaway library never
    ///     touches the real calendar.
    ///   - defaults: where the calendar identifier is remembered (device-local).
    public init(
        services: StudyServices,
        store: any CalendarStore = EventKitCalendarStore(),
        calendarTitle: String? = nil,
        defaults: any CalendarMirrorDefaults = UserDefaultsMirrorDefaults()
    ) {
        self.services = services
        self.store = store
        self.defaults = defaults
        title = calendarTitle ?? Self.calendarTitle(for: services.paths)
        scope = Self.scope(for: services.paths)
    }

    /// The `studyportal://session/<uuid>` link an event carries.
    public static func url(for sessionID: LectureSession.ID) -> URL? {
        URL(string: urlPrefix + sessionID.uuidString.lowercased())
    }

    /// The session an event URL points to, when it is one of ours.
    public static func sessionID(from url: URL?) -> LectureSession.ID? {
        guard let text = url?.absoluteString, text.lowercased().hasPrefix(urlPrefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(urlPrefix.count)))
    }

    /// The event a session should have (no identifier).
    public static func event(for session: LectureSession, course: Course) -> CalendarEvent {
        let room = session.room.trimmingCharacters(in: .whitespacesAndNewlines)
        return CalendarEvent(
            title: SessionText.eventTitle(courseName: course.name, kind: session.kind),
            location: room.isEmpty ? nil : room,
            url: url(for: session.id),
            notes: nil,
            startsAt: session.startsAt,
            endsAt: session.endsAt
        )
    }

    /// Full access to events, asking once when it was never decided. True when granted.
    public func requestAccess() async throws -> Bool {
        if await store.access() == .fullAccess { return true }
        return try await store.requestFullAccess()
    }

    /// Brings the calendar in line with the sessions. Runs one at a time; a call made while one
    /// runs waits for it and then runs.
    ///
    /// - Parameter full: also re-reads events of sessions that look synced (e.g. at launch, in case
    ///   the calendar was edited elsewhere). Without it, a sync with no session changes makes no
    ///   calendar calls at all.
    @discardableResult
    public func sync(full: Bool = false) async throws -> CalendarSyncReport {
        let previous = running
        let task = Task {
            _ = try? await previous?.value
            return try await self.perform(full: full)
        }
        running = task
        return try await task.value
    }

    // MARK: - Sync

    private func perform(full: Bool) async throws -> CalendarSyncReport {
        let now = Date()
        let (sessions, courses) = try await load()
        let dirty = Set(sessions.filter { Self.needsWork($0, course: courses[$0.courseID]) }.map(\.id))
        // A different set of events than after the last sync (a session deleted, a course renamed)
        // means every event gets checked.
        let fullPass = full || Self.fingerprint(sessions, courses: courses) != defaults.string(forKey: key("fingerprint"))
        if dirty.isEmpty, !fullPass {
            return CalendarSyncReport(outcome: .upToDate)
        }
        let work = fullPass ? sessions : sessions.filter { dirty.contains($0.id) }
        guard await store.access() == .fullAccess else {
            Log.calendar.info("Calendar sync skipped: no full access")
            return CalendarSyncReport(outcome: .noAccess)
        }

        var report = CalendarSyncReport(outcome: .synced)
        let calendarID = try await resolveCalendar(&report)
        let range = Self.scanRange(sessions, now: now)
        let existing = try await store.events(calendarID: calendarID, from: range.start, to: range.end)
        var byID: [String: CalendarEvent] = [:]
        var bySession: [LectureSession.ID: [CalendarEvent]] = [:]
        for event in existing {
            guard let id = event.id else { continue }
            byID[id] = event
            if let sessionID = Self.sessionID(from: event.url) { bySession[sessionID, default: []].append(event) }
        }

        // Event identifiers that belong to a session after this pass; everything else of ours goes.
        var owned: [String: LectureSession.ID] = [:]
        let workIDs = Set(work.map(\.id))
        for session in sessions where !workIDs.contains(session.id) {
            if let id = session.calendarEventID, Self.wantsEvent(session, course: courses[session.courseID]) {
                owned[id] = session.id
            }
        }

        for session in work {
            do {
                if let course = courses[session.courseID], Self.wantsEvent(session, course: course) {
                    var current = session.calendarEventID.flatMap { byID[$0] }
                    if current == nil, let id = session.calendarEventID {
                        current = try await store.event(id: id, calendarID: calendarID)
                    }
                    if current == nil {
                        current = bySession[session.id]?.first { owned[$0.id ?? ""] == nil }
                    }
                    var draft = Self.event(for: session, course: course)
                    let eventID: String
                    if let current, let id = current.id, current.hasSameContent(as: draft) {
                        eventID = id
                        report.unchanged += 1
                    } else {
                        draft.id = current?.id
                        eventID = try await store.save(draft, calendarID: calendarID)
                        if current == nil { report.created += 1 } else { report.updated += 1 }
                    }
                    owned[eventID] = session.id
                    if dirty.contains(session.id) || eventID != session.calendarEventID {
                        try await markSynced(session, eventID: eventID)
                    }
                } else {
                    if let id = session.calendarEventID, byID[id] == nil,
                       try await store.event(id: id, calendarID: calendarID) != nil {
                        try await store.removeEvent(id: id, calendarID: calendarID)
                        report.removed += 1
                    }
                    if dirty.contains(session.id) || session.calendarEventID != nil {
                        try await markSynced(session, eventID: nil)
                    }
                }
            } catch {
                report.failed += 1
                Log.calendar.error("Calendar sync of session \(session.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Our events no session owns: deleted or cancelled sessions, hidden courses, duplicates.
        for event in existing {
            guard let id = event.id, Self.sessionID(from: event.url) != nil, owned[id] == nil else { continue }
            do {
                try await store.removeEvent(id: id, calendarID: calendarID)
                report.removed += 1
            } catch {
                report.failed += 1
                Log.calendar.error("Removing calendar event failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if report.failed == 0 {
            let (after, afterCourses) = try await load()
            defaults.set(Self.fingerprint(after, courses: afterCourses), forKey: key("fingerprint"))
        }
        Log.calendar.info(
            "Calendar sync: +\(report.created) ~\(report.updated) -\(report.removed) =\(report.unchanged) !\(report.failed)"
        )
        return report
    }

    private func load() async throws -> ([LectureSession], [Course.ID: Course]) {
        try await services.database.read { db in
            let sessions = try LectureSession.order(by: \.startsAt).fetchAll(db)
            let courses = try Course.all.fetchAll(db)
            return (sessions, Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    /// `SessionRepository.markCalendarSynced`, guarded against an edit that landed while the event
    /// was written: the event identifier is kept either way, but such a session stays dirty.
    private func markSynced(_ snapshot: LectureSession, eventID: String?) async throws {
        let store = services.records
        try await services.database.write { db in
            guard var row = try LectureSession.find(snapshot.id).fetchOne(db) else { return }
            let unchanged = row.updatedAt == snapshot.updatedAt
            row.calendarEventID = eventID
            row = store.stamp(row)
            if unchanged { row.calendarSyncedAt = row.updatedAt }
            let stamped = row
            try LectureSession.upsert { stamped }.execute(db)
        }
    }

    private func resolveCalendar(_ report: inout CalendarSyncReport) async throws -> String {
        let calendars = await store.calendars()
        if let saved = defaults.string(forKey: key("calendar")),
           calendars.contains(where: { $0.id == saved && $0.allowsModifications }) {
            return saved
        }
        let sources = await store.sources()
        let preferred = Self.preferredSource(sources, defaultSourceID: await store.defaultSourceID())
        let named = calendars.filter { $0.title == title && $0.allowsModifications }
        if let adopted = named.first(where: { $0.sourceID == preferred?.id }) ?? named.first {
            defaults.set(adopted.id, forKey: key("calendar"))
            return adopted.id
        }
        guard let source = preferred else { throw CalendarMirrorError.noCalendarSource }
        let created = try await store.createCalendar(title: title, colorHex: nil, sourceID: source.id)
        defaults.set(created.id, forKey: key("calendar"))
        report.calendarCreated = true
        Log.calendar.info("Created the \(self.title, privacy: .public) calendar in \(source.title, privacy: .public)")
        return created.id
    }

    // MARK: - Rules

    static func wantsEvent(_ session: LectureSession, course: Course?) -> Bool {
        guard let course else { return false }
        return course.showsInCalendar && !session.isCancelled
    }

    static func needsWork(_ session: LectureSession, course: Course?) -> Bool {
        let wants = wantsEvent(session, course: course)
        return session.needsCalendarSync || (wants && session.calendarEventID == nil) || (!wants && session.calendarEventID != nil)
    }

    /// iCloud, else the default calendar's account, else On My Mac/iPhone, else any.
    static func preferredSource(_ sources: [CalendarSource], defaultSourceID: String?) -> CalendarSource? {
        sources.first { $0.kind == .iCloud }
            ?? sources.first { $0.id == defaultSourceID }
            ?? sources.first { $0.kind == .local }
            ?? sources.first
    }

    /// Changes whenever a session with an event appears, disappears, changes its event, or its
    /// course's name (the event title) changes.
    static func fingerprint(_ sessions: [LectureSession], courses: [Course.ID: Course]) -> String {
        let text = sessions
            .compactMap { session -> String? in
                guard let eventID = session.calendarEventID else { return nil }
                let title = courses[session.courseID].map { SessionText.eventTitle(courseName: $0.name, kind: session.kind) } ?? ""
                return "\(session.id.uuidString.lowercased())=\(eventID)=\(title)"
            }
            .sorted()
            .joined(separator: "\n")
        return "\(sessions.count):" + fnv1a(text)
    }

    /// Where our events can be: every session's time, and a year around now (deleted sessions).
    static func scanRange(_ sessions: [LectureSession], now: Date) -> (start: Date, end: Date) {
        let year: TimeInterval = 366 * 86_400
        let start = min(sessions.map(\.startsAt).min() ?? now, now.addingTimeInterval(-year)).addingTimeInterval(-86_400)
        let end = max(sessions.map(\.endsAt).max() ?? now, now.addingTimeInterval(year)).addingTimeInterval(86_400)
        return (start, end)
    }

    static func calendarTitle(for paths: AppPaths) -> String {
        guard let live = try? AppPaths.live(environment: [:]) else { return defaultCalendarTitle }
        if paths.root.standardizedFileURL.path(percentEncoded: false) == live.root.standardizedFileURL.path(percentEncoded: false) {
            return defaultCalendarTitle
        }
        return "\(defaultCalendarTitle) (\(paths.root.lastPathComponent))"
    }

    static func scope(for paths: AppPaths) -> String {
        fnv1a(paths.root.standardizedFileURL.path(percentEncoded: false))
    }

    private func key(_ name: String) -> String {
        "StudyPortal.calendarMirror.\(scope).\(name)"
    }

    private static func fnv1a(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }
}

/// What one `sync()` did.
public struct CalendarSyncReport: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        /// Nothing changed since the last sync; the calendar was not touched.
        case upToDate
        /// No full access to events; nothing was done.
        case noAccess
        case synced
    }

    public var outcome: Outcome
    public var calendarCreated = false
    public var created = 0
    public var updated = 0
    public var removed = 0
    public var unchanged = 0
    public var failed = 0

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

public enum CalendarMirrorError: Error, Equatable {
    case noCalendarSource
}

/// Device-local values the mirror remembers (the calendar identifier, the last synced state).
public protocol CalendarMirrorDefaults: Sendable {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
}

/// `UserDefaults` (standard, or a suite).
public struct UserDefaultsMirrorDefaults: CalendarMirrorDefaults {
    public let suiteName: String?

    public init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
