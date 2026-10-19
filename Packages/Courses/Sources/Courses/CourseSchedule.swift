import Foundation
import StudyCore

/// Keeps a course's lecture sessions in step with its weekly slots and the semester, and applies
/// hand edits to single sessions. Every method is one database transaction: the edit, the
/// reconciliation and the renumbering land together or not at all.
public struct CourseSchedule: Sendable {
    public let services: StudyServices
    public var planner = SessionPlanner()
    private let store: RecordStore

    public init(services: StudyServices) {
        self.services = services
        store = services.records
    }

    /// For tests: stamps writes with `store`'s clock.
    public init(services: StudyServices, store: RecordStore) {
        self.services = services
        self.store = store
    }

    // MARK: - Planning

    /// Reconciles the course's sessions with its slots (see `SessionPlanner`) and writes the
    /// result in one transaction, linking lectures without a session to the session they were
    /// held in (`SessionLectures`). A replan that changes nothing writes nothing.
    @discardableResult
    public func replan(courseID: Course.ID, now: Date = Date()) async throws -> SessionPlan {
        let planner = planner
        let store = store
        return try await services.database.write { db in
            try Self.replan(courseID: courseID, now: now, planner: planner, store: store, db: db)
        }
    }

    /// Replans every course (after a semester edit), in one transaction.
    @discardableResult
    public func replanAll(now: Date = Date()) async throws -> SessionPlan {
        let planner = planner
        let store = store
        return try await services.database.write { db in
            var total = SessionPlan()
            for course in try Course.all.fetchAll(db) {
                let plan = try Self.replan(courseID: course.id, now: now, planner: planner, store: store, db: db)
                total.inserted += plan.inserted
                total.updated += plan.updated
                total.deleted += plan.deleted
            }
            return total
        }
    }

    /// Saves a semester (lecture period, breaks) and replans every course, in one transaction.
    @discardableResult
    public func save(_ semester: Semester, now: Date = Date()) async throws -> Semester {
        let planner = planner
        let store = store
        let stamped = store.stamp(semester)
        try await services.database.write { db in
            try Semester.upsert { stamped }.execute(db)
            for course in try Course.all.fetchAll(db) {
                try Self.replan(courseID: course.id, now: now, planner: planner, store: store, db: db)
            }
        }
        return stamped
    }

    // MARK: - Slots

    /// Saves a weekly slot (new or changed) and replans its course.
    @discardableResult
    public func save(_ slot: WeeklySlot, now: Date = Date()) async throws -> WeeklySlot {
        let planner = planner
        let store = store
        return try await services.database.write { db in
            try Self.saveSlot(slot, now: now, planner: planner, store: store, db: db)
        }
    }

    /// Saves several slots (an .ics import) and replans their courses, in one transaction.
    @discardableResult
    public func save(_ slots: [WeeklySlot], now: Date = Date()) async throws -> [WeeklySlot] {
        let planner = planner
        let store = store
        let stamped = slots.map(store.stamp)
        guard !stamped.isEmpty else { return [] }
        try await services.database.write { db in
            for slot in stamped {
                try WeeklySlot.upsert { slot }.execute(db)
            }
            for courseID in Set(stamped.map(\.courseID)) {
                try Self.replan(courseID: courseID, now: now, planner: planner, store: store, db: db)
            }
        }
        return stamped
    }

    /// Saves a slot made from the course's one-off sessions (`SlotGuess`): the one-off sessions
    /// it would plan anyway (same kind, weekday and start) become its sessions, so they hold their
    /// days instead of being doubled. They stay as edited.
    @discardableResult
    public func saveAdoptingSessions(_ slot: WeeklySlot, now: Date = Date()) async throws -> WeeklySlot {
        let planner = planner
        let store = store
        let stamped = store.stamp(slot)
        let zone = TimeZone(identifier: slot.timeZone) ?? .current
        try await services.database.write { db in
            try WeeklySlot.upsert { stamped }.execute(db)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let oneOffs = try LectureSession
                .where { $0.courseID.eq(stamped.courseID) && $0.weeklySlotID.is(nil) }
                .fetchAll(db)
            for var session in oneOffs where session.kind == stamped.kind {
                let parts = calendar.dateComponents([.weekday, .hour, .minute], from: session.startsAt)
                guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute,
                      (weekday == 1 ? 7 : weekday - 1) == stamped.weekday, hour * 60 + minute == stamped.startMinute
                else { continue }
                session.weeklySlotID = stamped.id
                let adopted = store.stamp(session)
                try LectureSession.upsert { adopted }.execute(db)
            }
            try Self.replan(courseID: stamped.courseID, now: now, planner: planner, store: store, db: db)
        }
        return stamped
    }

    /// Deletes several slots (undoing an import) and replans their courses, in one transaction.
    public func deleteSlots(_ slotIDs: [WeeklySlot.ID], now: Date = Date()) async throws {
        let planner = planner
        let store = store
        try await services.database.write { db in
            var courses = Set<Course.ID>()
            for slotID in slotIDs {
                guard let slot = try WeeklySlot.find(slotID).fetchOne(db) else { continue }
                try WeeklySlot.find(slotID).delete().execute(db)
                courses.insert(slot.courseID)
            }
            for courseID in courses {
                try Self.replan(courseID: courseID, now: now, planner: planner, store: store, db: db)
            }
        }
    }

    /// Deletes a weekly slot and replans its course: its future sessions go, past ones and ones
    /// with a lecture stay.
    public func deleteSlot(_ slotID: WeeklySlot.ID, now: Date = Date()) async throws {
        let planner = planner
        let store = store
        try await services.database.write { db in
            try Self.deleteSlot(slotID, now: now, planner: planner, store: store, db: db)
        }
    }

    // MARK: - Session edits (each marks the session edited, so planning keeps it as it is)

    /// Cancels a session ("no class this week").
    @discardableResult
    public func cancel(_ sessionID: LectureSession.ID, now: Date = Date()) async throws -> LectureSession? {
        try await edit(sessionID, now: now) { $0.isCancelled = true }
    }

    /// Undoes a cancellation.
    @discardableResult
    public func restore(_ sessionID: LectureSession.ID, now: Date = Date()) async throws -> LectureSession? {
        try await edit(sessionID, now: now) { $0.isCancelled = false }
    }

    /// Moves a session to another room, keeping its time (a confirmed room change from mail).
    @discardableResult
    public func setRoom(_ sessionID: LectureSession.ID, room: String, now: Date = Date()) async throws -> LectureSession? {
        let room = room.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await edit(sessionID, now: now) { $0.room = room }
    }

    /// Moves a session to another time (and room, when given).
    @discardableResult
    public func move(
        _ sessionID: LectureSession.ID,
        startsAt: Date,
        endsAt: Date,
        room: String? = nil,
        now: Date = Date()
    ) async throws -> LectureSession? {
        try await edit(sessionID, now: now) { session in
            session.startsAt = startsAt
            session.endsAt = max(endsAt, startsAt)
            if let room { session.room = room }
        }
    }

    /// Adds a one-off session that belongs to no weekly slot.
    @discardableResult
    public func addSession(
        courseID: Course.ID,
        kind: SessionKind = .lecture,
        startsAt: Date,
        endsAt: Date,
        room: String = "",
        now: Date = Date()
    ) async throws -> LectureSession {
        let planner = planner
        let store = store
        let session = LectureSession(
            courseID: courseID, kind: kind, startsAt: startsAt, endsAt: max(endsAt, startsAt), room: room, editedAt: now
        )
        return try await services.database.write { db in
            try LectureSession.upsert { store.stamp(session) }.execute(db)
            try Self.replan(courseID: courseID, now: now, planner: planner, store: store, db: db)
            return try LectureSession.find(session.id).fetchOne(db) ?? session
        }
    }

    /// ma: moves a session to another time, keeping its room (a time change from mail or class).
    @discardableResult
    public func setTime(_ sessionID: LectureSession.ID, startsAt: Date, endsAt: Date, now: Date = Date()) async throws -> LectureSession? {
        try await move(sessionID, startsAt: startsAt, endsAt: endsAt, now: now)
    }

    /// ma: adds a one-off session the course announced (a block lecture, a make-up date).
    @discardableResult
    public func addExtra(
        courseID: Course.ID, kind: SessionKind, startsAt: Date, endsAt: Date, room: String = "", now: Date = Date()
    ) async throws -> LectureSession {
        try await addSession(courseID: courseID, kind: kind, startsAt: startsAt, endsAt: endsAt, room: room, now: now)
    }

    private func edit(
        _ sessionID: LectureSession.ID,
        now: Date,
        _ change: @escaping @Sendable (inout LectureSession) -> Void
    ) async throws -> LectureSession? {
        let planner = planner
        let store = store
        return try await services.database.write { db in
            try Self.edit(sessionID, now: now, planner: planner, store: store, db: db, change)?.after
        }
    }

    // MARK: - ma: inside the caller's transaction (AppAgent's change log, the timetable import)

    /// Changes one session inside the caller's transaction: the edit (marked `edited_at`, so
    /// planning keeps it), the reconciliation and the renumbering. The session before and after;
    /// nil when it is gone. An edit that changes nothing writes nothing (before == after).
    @discardableResult
    public static func edit(
        _ sessionID: LectureSession.ID,
        now: Date,
        planner: SessionPlanner = SessionPlanner(),
        store: RecordStore,
        db: Database,
        _ change: (inout LectureSession) -> Void
    ) throws -> (before: LectureSession, after: LectureSession)? {
        guard var session = try LectureSession.find(sessionID).fetchOne(db) else { return nil }
        let before = session
        change(&session)
        session.endsAt = max(session.endsAt, session.startsAt)
        guard session != before else { return (before, before) }
        session.editedAt = now
        let stamped = store.stamp(session)
        try LectureSession.upsert { stamped }.execute(db)
        try replan(courseID: session.courseID, now: now, planner: planner, store: store, db: db)
        let after = try LectureSession.find(sessionID).fetchOne(db) ?? stamped
        return (before, after)
    }

    /// Saves a weekly slot (new or changed) and replans its course inside the caller's
    /// transaction: Course Settings' Add Slot and slot edits (`save(_:)`) and AppAgent's slot
    /// changes. The slot as written.
    @discardableResult
    public static func saveSlot(
        _ slot: WeeklySlot,
        now: Date,
        planner: SessionPlanner = SessionPlanner(),
        store: RecordStore,
        db: Database
    ) throws -> WeeklySlot {
        let stamped = store.stamp(slot)
        try WeeklySlot.upsert { stamped }.execute(db)
        try replan(courseID: stamped.courseID, now: now, planner: planner, store: store, db: db)
        return stamped
    }

    /// Deletes a weekly slot and replans its course inside the caller's transaction (Course
    /// Settings' delete, AppAgent's slot changes): its future sessions go, past ones and ones with
    /// a lecture stay. The slot deleted; nil when it is unknown.
    @discardableResult
    public static func deleteSlot(
        _ slotID: WeeklySlot.ID,
        now: Date,
        planner: SessionPlanner = SessionPlanner(),
        store: RecordStore,
        db: Database
    ) throws -> WeeklySlot? {
        guard let slot = try WeeklySlot.find(slotID).fetchOne(db) else { return nil }
        try WeeklySlot.find(slotID).delete().execute(db)
        try replan(courseID: slot.courseID, now: now, planner: planner, store: store, db: db)
        return slot
    }

    /// Adds a one-off session (no weekly slot, `edited_at` set) inside the caller's transaction
    /// and replans its course; the session as written (numbered).
    @discardableResult
    public static func insertSession(
        courseID: Course.ID,
        kind: SessionKind,
        startsAt: Date,
        endsAt: Date,
        room: String,
        now: Date,
        planner: SessionPlanner = SessionPlanner(),
        store: RecordStore,
        db: Database
    ) throws -> LectureSession {
        let session = store.stamp(LectureSession(
            courseID: courseID, kind: kind, startsAt: startsAt, endsAt: max(endsAt, startsAt),
            room: room.trimmingCharacters(in: .whitespacesAndNewlines), editedAt: now
        ))
        try LectureSession.upsert { session }.execute(db)
        try replan(courseID: courseID, now: now, planner: planner, store: store, db: db)
        return try LectureSession.find(session.id).fetchOne(db) ?? session
    }

    // MARK: - Matching

    /// The session a recording that started at `start` belongs to (see `SessionMatch`).
    public func session(forRecordingAt start: Date, courseID: Course.ID? = nil) async throws -> LectureSession? {
        let window = SessionMatch.tolerance + 6 * 3600
        let sessions = try await SessionRepository(store: store).sessions(
            overlapping: start.addingTimeInterval(-window), start.addingTimeInterval(window), courseID: courseID
        )
        return SessionMatch.session(forRecordingAt: start, in: sessions)
    }

    // MARK: - Transaction body

    @discardableResult
    static func replan(courseID: Course.ID, now: Date, planner: SessionPlanner, store: RecordStore, db: Database) throws -> SessionPlan {
        guard let course = try Course.find(courseID).fetchOne(db) else { return .empty }
        let semester = try SemesterChoice.semester(for: course, on: now, db: db)
        let slots = try WeeklySlot.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let sessionIDs = Set(sessions.map(\.id))
        var filed = Set<LectureSession.ID>()
        for lecture in try Lecture.where({ $0.lectureSessionID.isNot(nil) }).fetchAll(db) {
            if let id = lecture.lectureSessionID, sessionIDs.contains(id) { filed.insert(id) }
        }
        for filing in try Filing.where({ $0.lectureSessionID.isNot(nil) }).fetchAll(db) {
            if let id = filing.lectureSessionID, sessionIDs.contains(id) { filed.insert(id) }
        }

        let plan = planner.plan(slots: slots, semester: semester, existing: sessions, now: now, filed: filed)
        for session in plan.deleted {
            try LectureSession.find(session.id).delete().execute(db)
        }
        for session in plan.inserted + plan.updated {
            let stamped = store.stamp(session)
            try LectureSession.upsert { stamped }.execute(db)
        }
        if !plan.isEmpty {
            CoursesLog.schedule.info(
                "Replanned course \(courseID, privacy: .public): +\(plan.inserted.count) ~\(plan.updated.count) -\(plan.deleted.count)"
            )
        }
        // Lectures filed before the slots existed belong to the sessions they were held in; linked
        // now, the next file for that session goes into them instead of a second lecture.
        let linked = try SessionLectures.linkAdoptable(courseID: courseID, in: db, stamp: store.currentDate)
        if linked > 0 {
            CoursesLog.schedule.info("Linked \(linked) lecture(s) of course \(courseID, privacy: .public) to their sessions")
        }
        return plan
    }
}

extension Semester {
    /// The semester whose lecture period contains `date`, else the next to start, else the latest,
    /// else WS 2026/27 (`SemesterRepository.current(on:)` for rows already in hand).
    public static func current(among semesters: [Semester], on date: Date = Date()) -> Semester {
        SemesterChoice.pick(from: semesters, on: date)
    }
}

/// Which semester a course's sessions are planned in, read inside a transaction (the same choice
/// as `SemesterRepository.semester(for:on:)`).
enum SemesterChoice {
    static func semester(for course: Course, on date: Date, db: Database) throws -> Semester {
        if let id = course.semesterID, let own = try Semester.find(id).fetchOne(db) { return own }
        return pick(from: try Semester.all.fetchAll(db), on: date)
    }

    static func pick(from semesters: [Semester], on date: Date) -> Semester {
        func day(_ semester: Semester) -> CalendarDay { CalendarDay(date, in: semester.zone) }
        if let containing = semesters.first(where: { $0.contains(day($0)) }) { return containing }
        if let next = semesters.filter({ day($0) < $0.lectureStart }).min(by: { $0.lectureStart < $1.lectureStart }) {
            return next
        }
        return semesters.max(by: { $0.lectureStart < $1.lectureStart }) ?? .winter2026
    }
}
