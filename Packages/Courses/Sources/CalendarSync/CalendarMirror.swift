import Courses
import Foundation
import StudyCore

/// Mirrors lecture sessions into the app's own "Socrates" calendar (PRD #36).
///
/// - Writes only to that calendar, found by the identifier remembered in `UserDefaults`, else an
///   existing writable calendar with its title (iCloud first), else one with the title it had
///   before the app was renamed ("Study Portal"), else a new one in the iCloud source (falling
///   back to the default calendar's source, then a local one).
/// - A calendar it writes to that still has the old title is renamed in place (same identifier,
///   same events); a calendar the student renamed to anything else keeps its title.
/// - One event per visible session: title = course name (+ " · Exercise" …), location = room,
///   `url = studyportal://session/<uuid>`, no notes. The event's identifier is stored in
///   `lecture_session.calendar_event_id`.
/// - `sync()` writes sessions that changed, removes events of cancelled sessions and hidden
///   courses, and removes events carrying our URL prefix that no session owns any more. Events
///   without our prefixes (anything the user added) are never touched.
/// - Tracked items that want an event (`TrackedItem.wantsCalendarEvent`: deadlines from mail with
///   a verified date, or added with Add to Calendar) get one too: the item's title at its due time
///   (all-day without a time), `url = studyportal://item/<uuid>`, the exact quote as notes. Undo,
///   done or dismissed items lose it.
/// - Without full access it does nothing and throws nothing; nothing is recorded, so the work
///   waits for the next sync.
public actor CalendarMirror {
    public static let defaultCalendarTitle = "Socrates"
    /// The app's calendar's title before the app was renamed; such a calendar is renamed in place.
    public static let legacyCalendarTitle = "Study Portal"
    public static let urlScheme = "studyportal"
    public static let urlPrefix = "studyportal://session/"
    /// Deadlines and other tracked items (from mail): `studyportal://item/<uuid>`.
    public static let itemURLPrefix = "studyportal://item/"

    private let services: StudyServices
    let store: any CalendarStore
    let defaults: any CalendarMirrorDefaults
    /// The app's own calendar's title ("Socrates").
    let title: String
    /// The title that calendar had before the app was renamed ("Study Portal"); nil for a title
    /// given by the caller.
    let legacyTitle: String?
    private let scope: String
    private var running: Task<CalendarSyncReport, any Error>?

    /// - Parameters:
    ///   - calendarTitle: nil = "Socrates" for the real library, "Socrates (<folder>)" for a
    ///     library relocated with `SOCRATES_DATA_ROOT`, so a throwaway library never touches the
    ///     real calendar.
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
        legacyTitle = calendarTitle == nil ? Self.calendarTitle(for: services.paths, base: Self.legacyCalendarTitle) : nil
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

    /// The `studyportal://item/<uuid>` link a deadline's event carries.
    public static func url(forItem itemID: TrackedItem.ID) -> URL? {
        URL(string: itemURLPrefix + itemID.uuidString.lowercased())
    }

    /// The tracked item an event URL points to, when it is one of ours.
    public static func itemID(from url: URL?) -> TrackedItem.ID? {
        guard let text = url?.absoluteString, text.lowercased().hasPrefix(itemURLPrefix) else { return nil }
        return UUID(uuidString: String(text.dropFirst(itemURLPrefix.count)))
    }

    /// The event a tracked item should have (no identifier): its title at the due time (all-day
    /// on its day when it has no time), the room as location, the exact quote it was read from
    /// as notes. Deadlines are a moment; exams and events last an hour. Nil without a due date.
    public static func event(for item: TrackedItem, course: Course?, calendar: Calendar = .current) -> CalendarEvent? {
        guard let due = item.dueAt else { return nil }
        let room = item.room?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let quote = item.sourceQuote.trimmingCharacters(in: .whitespacesAndNewlines)
        var event = CalendarEvent(
            title: item.title,
            location: room.isEmpty ? nil : room,
            url: url(forItem: item.id),
            notes: quote.isEmpty ? nil : quote,
            startsAt: due,
            endsAt: due
        )
        if item.isAllDay {
            let day = calendar.startOfDay(for: due)
            event.isAllDay = true
            event.startsAt = day
            event.endsAt = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        } else if item.kind != .deadline, item.kind != .exercise {
            event.endsAt = due.addingTimeInterval(3_600)
        }
        return event
    }

    /// True when the calendar has work: a course shown in the calendar has a session that is not
    /// cancelled, or a tracked item wants an event. The app asks for Calendar access only then.
    public static func hasCalendarWork(_ services: StudyServices) async throws -> Bool {
        try await services.database.read { db in
            let items = try TrackedItem.where { $0.inCalendar && $0.dueAt.isNot(nil) }.fetchAll(db)
            if items.contains(where: \.wantsCalendarEvent) { return true }
            let visible = try Course.where { $0.showsInCalendar }.fetchAll(db).map(\.id)
            guard !visible.isEmpty else { return false }
            return try LectureSession.where { !$0.isCancelled && $0.courseID.in(visible) }.fetchCount(db) > 0
        }
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

    /// What owns one of our events: a lecture session or a tracked item (a deadline from mail).
    enum Owner: Hashable {
        case session(LectureSession.ID)
        case item(TrackedItem.ID)
    }

    /// The owner an event URL of ours names.
    static func owner(of url: URL?) -> Owner? {
        if let id = sessionID(from: url) { return .session(id) }
        if let id = itemID(from: url) { return .item(id) }
        return nil
    }

    private func perform(full: Bool) async throws -> CalendarSyncReport {
        let now = Date()
        let (sessions, courses, items) = try await load()
        let dirty = Set(sessions.filter { Self.needsWork($0, course: courses[$0.courseID]) }.map(\.id))
        let dirtyItems = Set(items.filter(Self.needsWork).map(\.id))
        // A different set of events than after the last sync (a session deleted, a course renamed)
        // means every event gets checked.
        var fullPass = full || Self.fingerprint(sessions, items: items, courses: courses) != defaults.string(forKey: key("fingerprint"))
        if dirty.isEmpty, dirtyItems.isEmpty, !fullPass {
            return CalendarSyncReport(outcome: .upToDate)
        }
        guard await store.access() == .fullAccess else {
            Log.calendar.info("Calendar sync skipped: no full access")
            return CalendarSyncReport(outcome: .noAccess)
        }

        var report = CalendarSyncReport(outcome: .synced)
        // Nothing wants an event and nothing of ours can be in a calendar: no calendar to find,
        // and above all none to create (a deleted calendar is not brought back empty).
        let wantsAny = sessions.contains { Self.wantsEvent($0, course: courses[$0.courseID]) } || items.contains(where: \.wantsCalendarEvent)
        let knowsCalendar = defaults.string(forKey: key("calendar")) != nil
        let holdsAny = sessions.contains { $0.calendarEventID != nil } || items.contains { $0.calendarEventID != nil }
        if !wantsAny, !knowsCalendar, !holdsAny {
            try await markSynced(sessions.filter { dirty.contains($0.id) }.map { ($0, nil) })
            try await markSynced(items: items.filter { dirtyItems.contains($0.id) }.map { ($0, nil) })
            defaults.set(Self.fingerprint(sessions, items: items, courses: courses), forKey: key("fingerprint"))
            return report
        }

        let (calendarID, calendarChanged) = try await resolveCalendar(&report)
        // Another calendar than last time (the user deleted ours): every event id we hold points
        // into the old one, so every session is written again.
        if calendarChanged { fullPass = true }
        let work = fullPass ? sessions : sessions.filter { dirty.contains($0.id) }
        let itemWork = fullPass ? items : items.filter { dirtyItems.contains($0.id) }
        let range = Self.scanRange(sessions, items: items, now: now)
        let existing = try await store.events(calendarID: calendarID, from: range.start, to: range.end)
        var pass = PassState(report: report)
        for event in existing {
            guard let id = event.id else { continue }
            pass.byID[id] = event
            if let owner = Self.owner(of: event.url) { pass.byOwner[owner, default: []].append(event) }
        }
        let workIDs = Set(work.map(\.id))
        for session in sessions where !workIDs.contains(session.id) {
            if let id = session.calendarEventID, Self.wantsEvent(session, course: courses[session.courseID]) {
                pass.owned[id] = .session(session.id)
            }
        }
        let itemWorkIDs = Set(itemWork.map(\.id))
        for item in items where !itemWorkIDs.contains(item.id) {
            if let id = item.calendarEventID, item.wantsCalendarEvent { pass.owned[id] = .item(item.id) }
        }

        // What the pass wrote, applied in one transaction at the end.
        var synced: [(LectureSession, String?)] = []
        for session in work {
            do {
                let course = courses[session.courseID]
                let draft = course.flatMap { Self.wantsEvent(session, course: $0) ? Self.event(for: session, course: $0) : nil }
                // ma: a synced session whose event the student changed in another calendar app is
                // a new fact for the app agent; its event stays as the student left it until
                // triage has decided (then the session's version is written again).
                if !calendarChanged, !dirty.contains(session.id), let draft, let course,
                   try await keepsEditElsewhere(session, course: course, draft: draft, calendarID: calendarID, pass: &pass) {
                    continue
                }
                let eventID = try await reconcile(.session(session.id), eventID: session.calendarEventID, draft: draft, calendarID: calendarID, pass: &pass)
                if dirty.contains(session.id) || eventID != session.calendarEventID {
                    synced.append((session, eventID))
                }
            } catch {
                pass.report.failed += 1
                // A failed write leaves the event as it was: never delete it as an orphan.
                if let found = session.calendarEventID, pass.owned[found] == nil { pass.owned[found] = .session(session.id) }
                Log.calendar.error("Calendar sync of session \(session.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        var syncedItems: [(TrackedItem, String?)] = []
        for item in itemWork {
            do {
                let draft = item.wantsCalendarEvent ? Self.event(for: item, course: item.courseID.flatMap { courses[$0] }) : nil
                let eventID = try await reconcile(.item(item.id), eventID: item.calendarEventID, draft: draft, calendarID: calendarID, pass: &pass)
                if dirtyItems.contains(item.id) || eventID != item.calendarEventID {
                    syncedItems.append((item, eventID))
                }
            } catch {
                pass.report.failed += 1
                if let found = item.calendarEventID, pass.owned[found] == nil { pass.owned[found] = .item(item.id) }
                Log.calendar.error("Calendar sync of item \(item.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Our events nothing owns: deleted or cancelled sessions, hidden courses, undone or done
        // deadlines, duplicates. Events without our URL prefixes are never touched.
        var swept = Set<String>()
        for event in existing {
            // Once per event, not per occurrence.
            guard let id = event.id, Self.owner(of: event.url) != nil, pass.owned[id] == nil, swept.insert(id).inserted else { continue }
            do {
                try await store.removeEvent(id: id, calendarID: calendarID)
                pass.report.removed += 1
            } catch {
                pass.report.failed += 1
                Log.calendar.error("Removing calendar event failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        try await markSynced(synced)
        try await markSynced(items: syncedItems)
        report = pass.report
        if report.failed == 0 {
            // The state this pass worked on (with the events it wrote), not a fresh read: sessions
            // deleted meanwhile still count, so the next sync sees the change and sweeps their events.
            let written = Dictionary(synced.map { ($0.0.id, $0.1) }, uniquingKeysWith: { _, last in last })
            let after = sessions.map { session in
                var session = session
                if let eventID = written[session.id] { session.calendarEventID = eventID }
                return session
            }
            let writtenItems = Dictionary(syncedItems.map { ($0.0.id, $0.1) }, uniquingKeysWith: { _, last in last })
            let itemsAfter = items.map { item in
                var item = item
                if let eventID = writtenItems[item.id] { item.calendarEventID = eventID }
                return item
            }
            defaults.set(Self.fingerprint(after, items: itemsAfter, courses: courses), forKey: key("fingerprint"))
        }
        Log.calendar.info(
            "Calendar sync: +\(report.created) ~\(report.updated) -\(report.removed) =\(report.unchanged) !\(report.failed)"
        )
        return report
    }

    /// One pass's view of the calendar and what it did.
    struct PassState {
        var report: CalendarSyncReport
        var byID: [String: CalendarEvent] = [:]
        var byOwner: [Owner: [CalendarEvent]] = [:]
        /// Event identifiers that belong to a session or item after this pass; everything else of
        /// ours goes.
        var owned: [String: Owner] = [:]
    }

    /// Writes (`draft`) or removes (nil) one owner's event; returns the event identifier it has
    /// afterwards.
    private func reconcile(
        _ owner: Owner, eventID: String?, draft: CalendarEvent?, calendarID: String, pass: inout PassState
    ) async throws -> String? {
        if var draft {
            var current = eventID.flatMap { pass.byID[$0] }
            if current == nil, let id = eventID {
                current = try await store.event(id: id, calendarID: calendarID)
            }
            if current == nil {
                let owned = pass.owned
                current = pass.byOwner[owner]?.first { owned[$0.id ?? ""] == nil }
            }
            if let current, let id = current.id, current.hasSameContent(as: draft) {
                pass.report.unchanged += 1
                pass.owned[id] = owner
                return id
            }
            draft.id = current?.id
            let written = try await store.save(draft, calendarID: calendarID)
            if current == nil { pass.report.created += 1 } else { pass.report.updated += 1 }
            pass.owned[written] = owner
            return written
        }
        if let id = eventID, pass.byID[id] == nil, try await store.event(id: id, calendarID: calendarID) != nil {
            try await store.removeEvent(id: id, calendarID: calendarID)
            pass.report.removed += 1
        }
        return nil
    }

    /// ma: whether the event of a synced session was moved, re-roomed or deleted in another
    /// calendar app and is kept as it is for now. The first time a version of such an edit is
    /// seen it is recorded as a `calendar` event (`agent_event`, detail = what changed); while
    /// triage has not decided it (pending, or escalated with its task still open), the event
    /// stays; once decided (applied to the session or not, the escalation task ended), the
    /// session's version is written again as usual.
    private func keepsEditElsewhere(
        _ session: LectureSession, course: Course, draft: CalendarEvent, calendarID: String, pass: inout PassState
    ) async throws -> Bool {
        guard let eventID = session.calendarEventID else { return false }
        var current = pass.byID[eventID]
        if current == nil { current = try await store.event(id: eventID, calendarID: calendarID) }
        let zone = UniversityProfile.current.zone
        let was = Self.describe(start: session.startsAt, end: session.endsAt, location: session.room, zone: zone)
        let name = SessionText.title(of: session, courseName: course.name, shortName: course.shortName)
        let detail: String
        let version: String
        if let current {
            let moved = current.startsAt != draft.startsAt || current.endsAt != draft.endsAt
            let reroomed = (current.location ?? "").trimmingCharacters(in: .whitespaces) != (draft.location ?? "")
            guard moved || reroomed, !current.isAllDay else { return false }
            let now = Self.describe(start: current.startsAt, end: current.endsAt, location: current.location ?? "", zone: zone)
            detail = "The student changed the Socrates event of \(name) (session \(session.id.uuidString.lowercased())) in the Calendar app: was \(was), now \(now)."
            version = "\(Int(current.startsAt.timeIntervalSince1970))-\(Int(current.endsAt.timeIntervalSince1970))-\(current.location ?? "")"
        } else {
            detail = "The student deleted the Socrates event of \(name) (session \(session.id.uuidString.lowercased())), \(was), in the Calendar app."
            version = "deleted"
        }
        let key = "calendar:\(eventID):\(version)"
        let records = services.records
        let keep = try await services.database.write { db -> Bool in
            if let event = try AgentEvent.where({ $0.sourceKey.eq(key) }).fetchOne(db) {
                switch event.state {
                case .pending:
                    return true
                case .escalated:
                    // Decided once its escalation task ended (succeeded, failed or cancelled).
                    guard let taskID = event.taskID else { return false }
                    return try AgentTask.find(taskID).fetchOne(db)?.state.isOpen ?? false
                default:
                    return false
                }
            }
            let event = records.stamp(AgentEvent(kind: .calendar, sourceKey: key, courseID: session.courseID, detail: detail))
            try AgentEvent.upsert { event }.execute(db)
            return true
        }
        guard keep else { return false }
        if let current, let id = current.id {
            pass.owned[id] = .session(session.id)
            pass.report.unchanged += 1
        }
        return true
    }

    /// "Tue 2026-10-20 12:15–13:45 in Room 5".
    static func describe(start: Date, end: Date, location: String, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][(calendar.component(.weekday, from: start) - 1 + 7) % 7]
        func clock(_ date: Date) -> String {
            let parts = calendar.dateComponents([.hour, .minute], from: date)
            return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        }
        let room = location.trimmingCharacters(in: .whitespaces)
        return "\(weekday) \(CalendarDay(start, in: zone).rawValue) \(clock(start))–\(clock(end))" + (room.isEmpty ? "" : " in \(room)")
    }

    private func load() async throws -> ([LectureSession], [Course.ID: Course], [TrackedItem]) {
        try await services.database.read { db in
            let sessions = try LectureSession.order(by: \.startsAt).fetchAll(db)
            let courses = try Course.all.fetchAll(db)
            // Items that are in the calendar, or were (their event must go).
            let items = try TrackedItem
                .where { $0.inCalendar || $0.calendarEventID.isNot(nil) }
                .order(by: \.createdAt)
                .fetchAll(db)
            return (sessions, Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), items)
        }
    }

    /// `SessionRepository.markCalendarSynced` for every session the pass wrote, in one transaction
    /// (one change for the screens that observe sessions, not one per session), guarded against
    /// an edit that landed while the event was written: the event identifier is kept either way,
    /// but such a session stays dirty.
    private func markSynced(_ snapshots: [(LectureSession, String?)]) async throws {
        guard !snapshots.isEmpty else { return }
        let store = services.records
        let rows = snapshots.map { (session: $0.0, eventID: $0.1) }
        try await services.database.write { db in
            for (snapshot, eventID) in rows {
                guard var row = try LectureSession.find(snapshot.id).fetchOne(db) else { continue }
                let unchanged = row.updatedAt == snapshot.updatedAt
                row.calendarEventID = eventID
                row = store.stamp(row)
                if unchanged { row.calendarSyncedAt = row.updatedAt }
                let stamped = row
                try LectureSession.upsert { stamped }.execute(db)
            }
        }
    }

    /// The same for tracked items (`TrackedItemRepository.markCalendarSynced`, in one
    /// transaction): an item changed meanwhile (Undo while its event was written) keeps the
    /// event identifier and stays dirty.
    private func markSynced(items snapshots: [(TrackedItem, String?)]) async throws {
        guard !snapshots.isEmpty else { return }
        let store = services.records
        let rows = snapshots.map { (item: $0.0, eventID: $0.1) }
        try await services.database.write { db in
            for (snapshot, eventID) in rows {
                guard var row = try TrackedItem.find(snapshot.id).fetchOne(db) else { continue }
                let unchanged = row.updatedAt == snapshot.updatedAt
                row.calendarEventID = eventID
                row = store.stamp(row)
                if unchanged { row.calendarSyncedAt = row.updatedAt }
                let stamped = row
                try TrackedItem.upsert { stamped }.execute(db)
            }
        }
    }

    /// The calendar to write to, and whether it is another than the one remembered (adopted or
    /// created now: the remembered one was deleted, or there was none).
    private func resolveCalendar(_ report: inout CalendarSyncReport) async throws -> (id: String, changed: Bool) {
        let calendars = await store.calendars()
        let saved = defaults.string(forKey: key("calendar"))
        if let saved, let own = calendars.first(where: { $0.id == saved && $0.allowsModifications }) {
            await renameIfLegacy(own)
            return (saved, false)
        }
        let sources = await store.sources()
        let preferred = Self.preferredSource(sources, defaultSourceID: await store.defaultSourceID())
        let named = calendars.filter { $0.title == title && $0.allowsModifications }
        let legacy = calendars.filter { $0.title == legacyTitle && $0.allowsModifications }
        if let adopted = named.first(where: { $0.sourceID == preferred?.id }) ?? named.first
            ?? legacy.first(where: { $0.sourceID == preferred?.id }) ?? legacy.first {
            defaults.set(adopted.id, forKey: key("calendar"))
            await renameIfLegacy(adopted)
            return (adopted.id, true)
        }
        guard let source = preferred else { throw CalendarMirrorError.noCalendarSource }
        let created = try await store.createCalendar(title: title, colorHex: nil, sourceID: source.id)
        defaults.set(created.id, forKey: key("calendar"))
        report.calendarCreated = true
        Log.calendar.info("Created the \(self.title, privacy: .public) calendar in \(source.title, privacy: .public)")
        return (created.id, true)
    }

    /// The app's own calendar still titled as before the rename ("Study Portal") gets the new
    /// title in place: same identifier, same events. Any other title (the student's own) stays.
    /// A failure leaves the old title; the next sync tries again.
    private func renameIfLegacy(_ calendar: CalendarInfo) async {
        guard let legacyTitle, calendar.title == legacyTitle, calendar.title != title else { return }
        do {
            try await store.renameCalendar(id: calendar.id, title: title)
            Log.calendar.info("Renamed the \(legacyTitle, privacy: .public) calendar to \(self.title, privacy: .public)")
        } catch {
            Log.calendar.error("Renaming the \(legacyTitle, privacy: .public) calendar failed: \(error.localizedDescription, privacy: .public)")
        }
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

    static func needsWork(_ item: TrackedItem) -> Bool {
        let wants = item.wantsCalendarEvent
        return item.needsCalendarSync || (wants && item.calendarEventID == nil) || (!wants && item.calendarEventID != nil)
    }

    /// iCloud, else the default calendar's account, else On My Mac/iPhone, else any.
    static func preferredSource(_ sources: [CalendarSource], defaultSourceID: String?) -> CalendarSource? {
        sources.first { $0.kind == .iCloud }
            ?? sources.first { $0.id == defaultSourceID }
            ?? sources.first { $0.kind == .local }
            ?? sources.first
    }

    /// Changes whenever a session or item with an event appears, disappears, changes its event,
    /// or its course's name (the event title) changes.
    static func fingerprint(_ sessions: [LectureSession], items: [TrackedItem] = [], courses: [Course.ID: Course]) -> String {
        var lines = sessions.compactMap { session -> String? in
            guard let eventID = session.calendarEventID else { return nil }
            let title = courses[session.courseID].map { SessionText.eventTitle(courseName: $0.name, kind: session.kind) } ?? ""
            return "\(session.id.uuidString.lowercased())=\(eventID)=\(title)"
        }
        lines += items.compactMap { item -> String? in
            guard let eventID = item.calendarEventID else { return nil }
            return "item-\(item.id.uuidString.lowercased())=\(eventID)"
        }
        return "\(sessions.count):" + fnv1a(lines.sorted().joined(separator: "\n"))
    }

    /// Where our events can be: every session's time and item's due date, and a year around now
    /// (deleted sessions and items).
    static func scanRange(_ sessions: [LectureSession], items: [TrackedItem] = [], now: Date) -> (start: Date, end: Date) {
        let year: TimeInterval = 366 * 86_400
        let dues = items.compactMap(\.dueAt)
        let earliest = min(sessions.map(\.startsAt).min() ?? now, dues.min() ?? now)
        let latest = max(sessions.map(\.endsAt).max() ?? now, dues.max() ?? now)
        let start = min(earliest, now.addingTimeInterval(-year)).addingTimeInterval(-86_400)
        let end = max(latest, now.addingTimeInterval(year)).addingTimeInterval(2 * 86_400)
        return (start, end)
    }

    public static func calendarTitle(for paths: AppPaths, base: String = defaultCalendarTitle) -> String {
        guard let live = try? AppPaths.live(environment: [:]) else { return base }
        if paths.root.standardizedFileURL.path(percentEncoded: false) == live.root.standardizedFileURL.path(percentEncoded: false) {
            return base
        }
        return "\(base) (\(paths.root.lastPathComponent))"
    }

    static func scope(for paths: AppPaths) -> String {
        fnv1a(paths.root.standardizedFileURL.path(percentEncoded: false))
    }

    /// A device-local key of this library's mirror ("calendar": the own calendar's identifier).
    func key(_ name: String) -> String {
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
