import Foundation
import StudyCore

/// The part of the library smart import matches against, read in one transaction: courses,
/// sessions, lectures (with whether they have slides or a recording) and the footers of decks
/// already filed to each course.
struct FilingLibrary: Sendable {
    struct LectureInfo: Sendable, Hashable {
        var lecture: Lecture
        /// Decks linked by a coarse span.
        var deckIDs: Set<Deck.ID>
        var recordingCount: Int
        var hasDeck: Bool { !deckIDs.isEmpty }
        var hasRecording: Bool { recordingCount > 0 }
    }

    struct FiledDeck: Sendable, Hashable {
        var fileName: String
        var footerWords: Set<String>
    }

    var courses: [Course]
    /// Non-cancelled sessions of all courses, in time order.
    var sessions: [LectureSession]
    var lectures: [LectureInfo]
    var filedDecks: [Course.ID: [FiledDeck]]
    /// The semester's time zone (days of dates, "same day").
    var zone: TimeZone
    var now: Date

    func course(_ id: Course.ID) -> Course? { courses.first { $0.id == id } }
    func lecture(_ id: Lecture.ID) -> LectureInfo? { lectures.first { $0.lecture.id == id } }
    func session(_ id: LectureSession.ID) -> LectureSession? { sessions.first { $0.id == id } }
    func sessions(courseID: Course.ID) -> [LectureSession] { sessions.filter { $0.courseID == courseID } }
    func lectures(courseID: Course.ID) -> [LectureInfo] { lectures.filter { $0.lecture.courseID == courseID } }
    /// The lecture filed to the session; else a lecture of its course without a session that
    /// was held in it (filed before the slots existed), which an import into the session adopts.
    func lecture(sessionID: LectureSession.ID) -> LectureInfo? {
        if let linked = lectures.first(where: { $0.lecture.lectureSessionID == sessionID }) { return linked }
        guard let session = session(sessionID) else { return nil }
        let adopted = SessionLectures.adoptable(
            for: session, among: lectures(courseID: session.courseID).map(\.lecture),
            sessions: sessions(courseID: session.courseID), zone: zone
        )
        return adopted.flatMap { lecture($0.id) }
    }

    /// The session whose lecture holds what happened in `session`: itself, or the lecture an
    /// exercise, tutorial or seminar adjoins (one class meeting, `SessionLectures.meeting`).
    func meeting(of session: LectureSession) -> LectureSession {
        SessionLectures.meeting(of: session, among: sessions(courseID: session.courseID))
    }

    func day(_ date: Date) -> CalendarDay { CalendarDay(date, in: zone) }

    /// Where lecture `number` of a course is (2026-10-23: a lecture's number is its label, which
    /// moves with it when the plan changes).
    enum NumberedPlace {
        case lecture(LectureInfo)
        case session(LectureSession)
    }

    /// Where a file numbered `number` goes in a course: the lecture with that number (its class,
    /// when it was held there before it was linked: the import links it); else, when the numbers
    /// drifted from the classes' (lecture N−1 is held in a class numbered otherwise, after the
    /// student moved lectures), the first free numbered class after lecture N−1's; else the
    /// numbered class with that number. Nil: none (a new lecture).
    func place(forNumber number: Int, courseID: Course.ID) -> NumberedPlace? {
        let numbered = numberedSessions(courseID: courseID)
        let lectures = lectures(courseID: courseID)
        if let info = lectures.first(where: { $0.lecture.number == number }) {
            if info.lecture.lectureSessionID == nil, let session = numbered.first(where: { $0.number == number }),
               lecture(sessionID: session.id)?.lecture.id == info.lecture.id {
                return .session(session)
            }
            return .lecture(info)
        }
        if let previous = lectures.first(where: { $0.lecture.number == number - 1 }), let held = heldIn(previous.lecture),
           numbered.contains(where: { $0.id == held.id }), held.number != number - 1 {
            return numbered.first { $0.startsAt > held.startsAt && lecture(sessionID: $0.id) == nil }.map(NumberedPlace.session)
        }
        return numbered.first { $0.number == number }.map(NumberedPlace.session)
    }

    /// The class a lecture was held in: its own, else (joined to a class, or held in it before it
    /// was linked) the one it was held in.
    func heldIn(_ lecture: Lecture) -> LectureSession? {
        if let id = lecture.lectureSessionID { return session(id) }
        return SessionLectures.session(for: lecture, in: sessions(courseID: lecture.courseID), zone: zone)
    }

    /// Sessions that carry lecture numbers: lectures, or seminars for a course without lectures.
    func numberedSessions(courseID: Course.ID) -> [LectureSession] {
        let all = sessions(courseID: courseID)
        let lectures = all.filter { $0.kind == .lecture }
        return lectures.isEmpty ? all.filter { $0.kind == .seminar } : lectures
    }

    static func load(_ db: Database, now: Date) throws -> FilingLibrary {
        let courses = try Course.order(by: \.sortOrder).fetchAll(db)
        let sessions = try LectureSession.where { !$0.isCancelled }.order(by: \.startsAt).fetchAll(db)
        let lectures = try Lecture.order(by: \.createdAt).fetchAll(db)
        let coarse = try LectureDeckSpan.where { $0.startTime.is(nil) }.fetchAll(db)
        let recordings = try Recording.where { $0.lectureID.isNot(nil) }.fetchAll(db)
        var decksByLecture: [Lecture.ID: Set<Deck.ID>] = [:]
        for span in coarse { decksByLecture[span.lectureID, default: []].insert(span.deckID) }
        var recordingsByLecture: [Lecture.ID: Int] = [:]
        for recording in recordings { if let id = recording.lectureID { recordingsByLecture[id, default: 0] += 1 } }
        let infos = lectures.map {
            LectureInfo(lecture: $0, deckIDs: decksByLecture[$0.id] ?? [], recordingCount: recordingsByLecture[$0.id] ?? 0)
        }

        var filedDecks: [Course.ID: [FiledDeck]] = [:]
        for deck in try Deck.where({ $0.courseID.isNot(nil) }).fetchAll(db) {
            guard let courseID = deck.courseID else { continue }
            let numbers = DeckProbe.sample(pageCount: deck.pageCount, size: DeckProbe.sampleSize).map { $0 + 1 }
            let texts = try DeckPage
                .where { $0.deckID.eq(deck.id) && $0.pageNumber.in(numbers) }
                .order(by: \.pageNumber)
                .fetchAll(db)
                .map(\.text)
            let footer = Footer.lines(pages: texts)
            guard !footer.isEmpty else { continue }
            filedDecks[courseID, default: []].append(
                FiledDeck(fileName: deck.fileName, footerWords: TextMatch.wordSet(footer.joined(separator: " ")))
            )
        }

        let semesters = try Semester.order(by: \.lectureStart).fetchAll(db)
        let zone = semesters.first?.zone ?? UniversityProfile.current.zone
        return FilingLibrary(
            courses: courses, sessions: sessions, lectures: infos, filedDecks: filedDecks, zone: zone, now: now
        )
    }
}
