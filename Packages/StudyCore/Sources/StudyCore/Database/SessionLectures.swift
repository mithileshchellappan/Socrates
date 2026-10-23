import Foundation
import SQLiteData

/// Which lecture belongs to a lecture session.
///
/// A lecture is linked to its session by `lecture.lecture_session_id`. Lectures filed before the
/// course had weekly slots (or into a new lecture by hand) have no session, so once slots are
/// entered their session would otherwise look empty and the next file for it would create a
/// second lecture. Such a lecture is *adoptable* by the session it was held in:
/// - dated with a time: the session whose start is within ±30 min of it, or that was running
///   then (nearest start first), as a recording is matched;
/// - dated by day only (a title slide's date): the first numbered session of that day;
/// - undated: the numbered session with its number.
///
/// Numbered sessions are lectures, or seminars in a course without lectures.
///
/// One class meeting, one lecture (2026-10-21): an exercise, tutorial or seminar of a course with
/// lectures that adjoins one of its lectures (a recitation right after it, ≤ 30 min between them)
/// is part of that class meeting (`meeting(of:among:)`), so what was recorded or shown in it goes
/// into that lecture. Such a session takes a lecture of its own only when it stands alone, and
/// never gives it a lecture number (its own count is not one: `numbersLectures`).
public enum SessionLectures {
    /// A lecture may start this long before or after its session's start.
    public static let tolerance: TimeInterval = 30 * 60
    /// At most this between a lecture and an exercise, tutorial or seminar of its course for the
    /// two to be one class meeting.
    public static let adjoining: TimeInterval = 30 * 60

    /// The session `lecture` was held in, among its course's `sessions` (cancelled ones never);
    /// a session that is part of a lecture's class meeting gives that lecture's session.
    public static func session(for lecture: Lecture, in sessions: [LectureSession], zone: TimeZone) -> LectureSession? {
        let open = sessions.filter { $0.courseID == lecture.courseID && !$0.isCancelled }
        let numbered = numberedKind(open)
        if let heldAt = lecture.heldAt {
            let day = CalendarDay(heldAt, in: zone)
            if day.start(in: zone) == heldAt {
                return open
                    .filter { $0.kind == numbered && CalendarDay($0.startsAt, in: zone) == day }
                    .min { $0.startsAt < $1.startsAt }
            }
            return open
                .filter { session in
                    abs(heldAt.timeIntervalSince(session.startsAt)) <= tolerance
                        || (session.startsAt <= heldAt && heldAt < session.endsAt)
                }
                .min { lhs, rhs in
                    let left = abs(heldAt.timeIntervalSince(lhs.startsAt))
                    let right = abs(heldAt.timeIntervalSince(rhs.startsAt))
                    return left == right ? lhs.id.uuidString < rhs.id.uuidString : left < right
                }
                .map { meeting(of: $0, among: open) }
        }
        guard let number = lecture.number else { return nil }
        return open.first { $0.kind == numbered && $0.number == number }
    }

    /// Whether `session`'s own number is a lecture number: a numbered session (a lecture, or a
    /// seminar in a course without lectures), or any session of a course without numbered ones.
    /// An exercise's count beside lectures is not one ("L2" twice on one day).
    public static func numbersLectures(_ session: LectureSession, among sessions: [LectureSession]) -> Bool {
        let open = sessions.filter { $0.courseID == session.courseID && !$0.isCancelled }
        let numbered = numberedKind(open)
        return session.kind == numbered || !open.contains { $0.kind == numbered }
    }

    /// The session whose lecture holds what happened in `session`: `session` itself, or, for an
    /// exercise, tutorial or seminar beside lectures, the course's numbered session it adjoins
    /// (≤ `adjoining` between the two; the nearer, the earlier on a tie). One that stands alone
    /// (another day, the evening) is its own.
    public static func meeting(of session: LectureSession, among sessions: [LectureSession]) -> LectureSession {
        guard !numbersLectures(session, among: sessions) else { return session }
        let open = sessions.filter { $0.courseID == session.courseID && !$0.isCancelled }
        let numbered = numberedKind(open)
        return open
            .filter { $0.kind == numbered && gap($0, session) <= adjoining }
            .min { lhs, rhs in
                let left = gap(lhs, session)
                let right = gap(rhs, session)
                return left == right ? lhs.startsAt < rhs.startsAt : left < right
            } ?? session
    }

    /// Time between two sessions (0 when they overlap or touch).
    static func gap(_ lhs: LectureSession, _ rhs: LectureSession) -> TimeInterval {
        max(0, max(lhs.startsAt, rhs.startsAt).timeIntervalSince(min(lhs.endsAt, rhs.endsAt)))
    }

    /// The lecture without a session among `lectures` that was held in `session` (oldest first).
    public static func adoptable(
        for session: LectureSession, among lectures: [Lecture], sessions: [LectureSession], zone: TimeZone
    ) -> Lecture? {
        guard !session.isCancelled else { return nil }
        return lectures
            .filter { $0.courseID == session.courseID && $0.lectureSessionID == nil }
            .sorted { $0.createdAt < $1.createdAt }
            .first { Self.session(for: $0, in: sessions, zone: zone)?.id == session.id }
    }

    /// Lectures numbered by session: lectures, or seminars when a course has no lecture sessions.
    static func numberedKind(_ sessions: [LectureSession]) -> SessionKind {
        sessions.contains { $0.kind == .lecture } || !sessions.contains { $0.kind == .seminar } ? .lecture : .seminar
    }

    // MARK: - Inside a transaction

    /// The number a new lecture of `session` takes: the session's, unless that is not a lecture
    /// number (an exercise beside lectures: `numbersLectures`) or another lecture of the course
    /// has it (2026-10-23: a lecture's number is its label, which stays with it when the student
    /// moves lectures to other classes; "DC 3" names one lecture).
    public static func lectureNumber(for session: LectureSession, in db: Database) throws -> Int? {
        let courseID = session.courseID
        let sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
        guard numbersLectures(session, among: sessions), let number = session.number else { return nil }
        let taken = try Lecture.where { $0.courseID.eq(courseID) && $0.number.eq(Int?.some(number)) }.fetchCount(db)
        return taken == 0 ? number : nil
    }

    /// The lecture filed to `sessionID`, else the one it adopts (`isLinked` false; not written).
    public static func lecture(forSession sessionID: LectureSession.ID, in db: Database) throws -> (lecture: Lecture, isLinked: Bool)? {
        if let linked = try Lecture.where({ $0.lectureSessionID.eq(sessionID) }).order(by: \.createdAt).fetchOne(db) {
            return (linked, true)
        }
        guard let session = try LectureSession.find(sessionID).fetchOne(db) else { return nil }
        let courseID = session.courseID
        let lectures = try Lecture.where { $0.courseID.eq(courseID) && $0.lectureSessionID.is(nil) }.fetchAll(db)
        guard !lectures.isEmpty else { return nil }
        let sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let zone = try zone(courseID: courseID, on: session.startsAt, in: db)
        return adoptable(for: session, among: lectures, sessions: sessions, zone: zone).map { ($0, false) }
    }

    /// The lecture filed to `sessionID`, linking an adoptable one to it first (see `link`).
    public static func resolve(sessionID: LectureSession.ID, in db: Database, stamp: Date) throws -> Lecture? {
        guard let found = try lecture(forSession: sessionID, in: db) else { return nil }
        return found.isLinked ? found.lecture : try link(found.lecture.id, toSession: sessionID, in: db, stamp: stamp)
    }

    /// Links a lecture to a session (only these columns are written). A lecture without a time
    /// (undated, or dated by day) takes the session's start.
    @discardableResult
    public static func link(_ lectureID: Lecture.ID, toSession sessionID: LectureSession.ID, in db: Database, stamp: Date) throws -> Lecture? {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db),
              let session = try LectureSession.find(sessionID).fetchOne(db)
        else { return nil }
        let zone = try zone(courseID: lecture.courseID, on: session.startsAt, in: db)
        let untimed = lecture.heldAt.map { CalendarDay($0, in: zone).start(in: zone) == $0 } ?? true
        let heldAt = untimed ? session.startsAt : lecture.heldAt
        let id: LectureSession.ID? = sessionID
        try Lecture.find(lectureID)
            .update { $0.lectureSessionID = id; $0.heldAt = heldAt; $0.updatedAt = stamp }
            .execute(db)
        return try Lecture.find(lectureID).fetchOne(db)
    }

    /// Links every lecture of `courseID` without a session to the session it was held in, when
    /// that session has no lecture (one lecture per session). Returns how many were linked.
    @discardableResult
    public static func linkAdoptable(courseID: Course.ID, in db: Database, stamp: Date) throws -> Int {
        let unlinked = try Lecture.where { $0.courseID.eq(courseID) && $0.lectureSessionID.is(nil) }
            .order(by: \.createdAt)
            .fetchAll(db)
        guard !unlinked.isEmpty else { return 0 }
        let sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
        guard !sessions.isEmpty else { return 0 }
        var taken = Set(try Lecture.where { $0.courseID.eq(courseID) && $0.lectureSessionID.isNot(nil) }
            .fetchAll(db)
            .compactMap(\.lectureSessionID))
        let zone = try zone(courseID: courseID, on: sessions.map(\.startsAt).min() ?? Date(), in: db)
        var linked = 0
        for lecture in unlinked {
            guard let session = session(for: lecture, in: sessions, zone: zone), !taken.contains(session.id) else { continue }
            try link(lecture.id, toSession: session.id, in: db, stamp: stamp)
            taken.insert(session.id)
            linked += 1
        }
        return linked
    }

    /// The time zone a course's sessions are planned in (its semester's).
    static func zone(courseID: Course.ID, on date: Date, in db: Database) throws -> TimeZone {
        if let semesterID = try Course.find(courseID).fetchOne(db)?.semesterID,
           let own = try Semester.find(semesterID).fetchOne(db) {
            return own.zone
        }
        return SemesterRepository.pick(from: try Semester.all.fetchAll(db), on: date).zone
    }
}
