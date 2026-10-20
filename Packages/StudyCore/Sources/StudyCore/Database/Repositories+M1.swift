import Foundation
import SQLiteData

// Repositories shared by milestone-1 modules (courses + calendar, smart import, review, search).
// Module-private queries live in the modules; these are the reads and writes more than one
// module relies on.

public struct SemesterRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func all() async throws -> [Semester] {
        try await store.database.read { db in
            try Semester.order(by: \.lectureStart).fetchAll(db)
        }
    }

    /// The semester whose lecture period contains `date`; else the next one to start; else the
    /// latest one; else the built-in WS 2026/27.
    public func current(on date: Date = Date()) async throws -> Semester {
        Self.pick(from: try await all(), on: date)
    }

    /// The semester a course's sessions are planned in: its own, else the current one.
    public func semester(for course: Course, on date: Date = Date()) async throws -> Semester {
        if let id = course.semesterID, let own = try await store.fetch(Semester.self, id: id) { return own }
        return try await current(on: date)
    }

    static func pick(from semesters: [Semester], on date: Date) -> Semester {
        func day(_ semester: Semester) -> CalendarDay { CalendarDay(date, in: semester.zone) }
        if let containing = semesters.first(where: { $0.contains(day($0)) }) { return containing }
        if let next = semesters.filter({ day($0) < $0.lectureStart }).min(by: { $0.lectureStart < $1.lectureStart }) {
            return next
        }
        return semesters.max(by: { $0.lectureStart < $1.lectureStart }) ?? .placeholder(on: date)
    }
}

public struct SessionRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// A course's sessions in time order (cancelled ones included).
    public func sessions(courseID: Course.ID) async throws -> [LectureSession] {
        try await store.database.read { db in
            try LectureSession
                .where { $0.courseID.eq(courseID) }
                .order(by: \.startsAt)
                .fetchAll(db)
        }
    }

    /// Sessions overlapping `[start, end)`, all courses or one, in time order.
    public func sessions(overlapping start: Date, _ end: Date, courseID: Course.ID? = nil) async throws -> [LectureSession] {
        try await store.database.read { db in
            try LectureSession
                .where { $0.startsAt.lt(end) && $0.endsAt.gt(start) }
                .order(by: \.startsAt)
                .fetchAll(db)
                .filter { courseID == nil || $0.courseID == courseID }
        }
    }

    /// Non-cancelled sessions still running or starting at or after `date`, soonest first.
    public func upcoming(after date: Date, courseID: Course.ID? = nil, limit: Int = 20) async throws -> [LectureSession] {
        try await store.database.read { db in
            try LectureSession
                .where { $0.endsAt.gt(date) && !$0.isCancelled }
                .order(by: \.startsAt)
                .fetchAll(db)
                .filter { courseID == nil || $0.courseID == courseID }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// Sessions whose calendar event must be written or removed.
    public func needingCalendarSync() async throws -> [LectureSession] {
        try await store.database.read { db in
            try LectureSession.order(by: \.startsAt).fetchAll(db).filter(\.needsCalendarSync)
        }
    }

    /// Records that the calendar event now matches the session: sets `calendarEventID` and stamps
    /// `updatedAt` and `calendarSyncedAt` with the same instant, in one transaction. Returns nil
    /// when the session is gone.
    @discardableResult
    public func markCalendarSynced(_ sessionID: LectureSession.ID, eventID: String?) async throws -> LectureSession? {
        let store = store
        return try await store.database.write { db in
            guard var session = try LectureSession.find(sessionID).fetchOne(db) else { return nil }
            session.calendarEventID = eventID
            session = store.stamp(session)
            session.calendarSyncedAt = session.updatedAt
            let synced = session
            try LectureSession.upsert { synced }.execute(db)
            return synced
        }
    }
}

extension LectureRepository {
    /// Lectures with a transcript that the student has not reviewed, newest first (Today).
    public func unreviewed(courseID: Course.ID? = nil, limit: Int = 10) async throws -> [Lecture] {
        try await store.database.read { db in
            try Lecture
                .where { $0.reviewedAt.is(nil) }
                .order { ($0.heldAt.desc(), $0.createdAt.desc()) }
                .fetchAll(db)
                .filter { lecture in
                    guard courseID == nil || lecture.courseID == courseID else { return false }
                    return try TranscriptSegment.where { $0.lectureID.eq(lecture.id) }.fetchCount(db) > 0
                }
                .prefix(limit)
                .map { $0 }
        }
    }

    /// The lecture filed to a session, if any.
    public func lecture(sessionID: LectureSession.ID) async throws -> Lecture? {
        try await store.database.read { db in
            try Lecture.where { $0.lectureSessionID.eq(sessionID) }.order(by: \.createdAt).fetchOne(db)
        }
    }

    /// Marks a lecture reviewed (nil clears it). Writes only `reviewed_at` and `updated_at`, so a
    /// concurrent change of the lecture's other columns is never reverted, and observers of
    /// other columns are not woken.
    @discardableResult
    public func setReviewed(_ lectureID: Lecture.ID, at date: Date?) async throws -> Lecture? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try Lecture.find(lectureID).update { $0.reviewedAt = date; $0.updatedAt = stamp }.execute(db)
            return try Lecture.find(lectureID).fetchOne(db)
        }
    }

    /// Remembers where review left off (seconds on the recording clock). Writes only
    /// `review_position` and `updated_at` (the review screen saves it every few seconds).
    @discardableResult
    public func setReviewPosition(_ lectureID: Lecture.ID, seconds: Double?) async throws -> Lecture? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try Lecture.find(lectureID).update { $0.reviewPosition = seconds; $0.updatedAt = stamp }.execute(db)
            return try Lecture.find(lectureID).fetchOne(db)
        }
    }
}

extension RecordingRepository {
    /// Sets a manual "slide starts here" marker (`page` nil = off the slides from here) at
    /// `seconds` on the recording clock, replacing manual markers within `replacingWithin` seconds
    /// of it, in one transaction. The aligner uses it as given on its next run.
    @discardableResult
    public func setManualAnchor(
        recordingID: Recording.ID,
        lectureID: Lecture.ID?,
        deckID: Deck.ID?,
        page: Int?,
        at seconds: Double,
        replacingWithin window: Double = 1
    ) async throws -> SlideEvent? {
        let store = store
        return try await store.database.write { db in
            guard let recording = try Recording.find(recordingID).fetchOne(db) else { return nil }
            let rate = recording.sampleRate > 0 ? recording.sampleRate : 48_000
            let sample = Int64((max(0, seconds) * rate).rounded())
            let radius = Int64((window * rate).rounded())
            try SlideEvent
                .where {
                    $0.recordingID.eq(recordingID) && $0.kind.eq(SlideEventKind.manual)
                        && $0.sampleTime.gte(Int64?.some(sample - radius)) && $0.sampleTime.lte(Int64?.some(sample + radius))
                }
                .delete()
                .execute(db)
            let event = store.stamp(SlideEvent(
                recordingID: recordingID,
                lectureID: lectureID ?? recording.lectureID,
                kind: .manual,
                deckID: deckID,
                pageNumber: page,
                sampleTime: sample,
                wallClock: recording.startedAt.addingTimeInterval(max(0, seconds))
            ))
            try SlideEvent.upsert { event }.execute(db)
            return event
        }
    }

    /// Manual markers of a recording in clock order.
    public func manualAnchors(recordingID: Recording.ID) async throws -> [SlideEvent] {
        try await slideEvents(recordingID: recordingID).filter { $0.kind == .manual }
    }
}

public struct NoteRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// A lecture's notes by slide, then creation.
    public func notes(lectureID: Lecture.ID) async throws -> [Note] {
        try await store.database.read { db in
            try Note
                .where { $0.lectureID.eq(lectureID) }
                .order { ($0.pageNumber, $0.createdAt) }
                .fetchAll(db)
        }
    }

    /// Notes anchored to one slide of a lecture, oldest first.
    public func notes(lectureID: Lecture.ID, deckID: Deck.ID?, page: Int) async throws -> [Note] {
        try await store.database.read { db in
            try Note
                .where { $0.lectureID.eq(lectureID) && $0.pageNumber.eq(Int?.some(page)) }
                .order(by: \.createdAt)
                .fetchAll(db)
                .filter { deckID == nil || $0.deckID == nil || $0.deckID == deckID }
        }
    }

    /// Saves `note`; a blank note is deleted instead (returns nil).
    @discardableResult
    public func saveOrDeleteIfBlank(_ note: Note) async throws -> Note? {
        if note.isBlank {
            try await store.delete(Note.self, id: note.id)
            return nil
        }
        return try await store.save(note)
    }
}

public struct FilingRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Most recent filings first.
    public func recent(limit: Int = 20) async throws -> [Filing] {
        try await store.database.read { db in
            try Filing.order { $0.createdAt.desc() }.limit(limit).fetchAll(db)
        }
    }

    public func filings(lectureID: Lecture.ID) async throws -> [Filing] {
        try await store.database.read { db in
            try Filing.where { $0.lectureID.eq(lectureID) }.order(by: \.createdAt).fetchAll(db)
        }
    }

    /// The latest filing of a deck (how it reached its course and lecture).
    public func latest(deckID: Deck.ID) async throws -> Filing? {
        try await store.database.read { db in
            try Filing.where { $0.deckID.eq(deckID) }.order { $0.createdAt.desc() }.fetchOne(db)
        }
    }

    /// The latest filing of a recording.
    public func latest(recordingID: Recording.ID) async throws -> Filing? {
        try await store.database.read { db in
            try Filing.where { $0.recordingID.eq(recordingID) }.order { $0.createdAt.desc() }.fetchOne(db)
        }
    }
}
