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
    /// result in one transaction. A replan that changes nothing writes nothing.
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

    // MARK: - Slots

    /// Saves a weekly slot (new or changed) and replans its course.
    @discardableResult
    public func save(_ slot: WeeklySlot, now: Date = Date()) async throws -> WeeklySlot {
        let planner = planner
        let store = store
        let stamped = store.stamp(slot)
        try await services.database.write { db in
            try WeeklySlot.upsert { stamped }.execute(db)
            try Self.replan(courseID: stamped.courseID, now: now, planner: planner, store: store, db: db)
        }
        return stamped
    }

    /// Deletes a weekly slot and replans its course: its future sessions go, past ones and ones
    /// with a lecture stay.
    public func deleteSlot(_ slotID: WeeklySlot.ID, now: Date = Date()) async throws {
        let planner = planner
        let store = store
        try await services.database.write { db in
            guard let slot = try WeeklySlot.find(slotID).fetchOne(db) else { return }
            try WeeklySlot.find(slotID).delete().execute(db)
            try Self.replan(courseID: slot.courseID, now: now, planner: planner, store: store, db: db)
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

    private func edit(
        _ sessionID: LectureSession.ID,
        now: Date,
        _ change: @escaping @Sendable (inout LectureSession) -> Void
    ) async throws -> LectureSession? {
        let planner = planner
        let store = store
        return try await services.database.write { db in
            guard var session = try LectureSession.find(sessionID).fetchOne(db) else { return nil }
            let before = session
            change(&session)
            guard session != before else { return session }
            session.editedAt = now
            let stamped = store.stamp(session)
            try LectureSession.upsert { stamped }.execute(db)
            try Self.replan(courseID: session.courseID, now: now, planner: planner, store: store, db: db)
            return try LectureSession.find(sessionID).fetchOne(db)
        }
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
        return plan
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
