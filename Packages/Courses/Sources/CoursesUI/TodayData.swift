import Courses
import Foundation
import StudyCore

/// What Today shows, read in one transaction: the newest lecture waiting for review and the
/// sessions around the day.
struct TodayData: Hashable, Sendable {
    var courses: [Course.ID: Course] = [:]
    var review: ReviewCandidate?
    /// Sessions overlapping the day before through eight days after (cancelled included).
    var sessions: [LectureSession] = []
    /// Upcoming non-cancelled lecture sessions of the review lecture's course.
    var nextLectures: [LectureSession] = []
}

/// The newest unreviewed lecture with what the hero says about it.
struct ReviewCandidate: Hashable, Sendable {
    var lecture: Lecture
    var recordedAt: Date?
    /// Seconds of the first recording.
    var duration: Double?
    var firstPage: Int?
    var lastPage: Int?
    var pageCount: Int?
}

struct TodayRequest: FetchKeyRequest {
    let day: CalendarDay
    let timeZone: TimeZone

    func fetch(_ db: Database) throws -> TodayData {
        var data = TodayData()
        let courses = try Course.all.fetchAll(db)
        data.courses = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let windowStart = day.adding(days: -1).start(in: timeZone)
        let windowEnd = day.adding(days: 9).start(in: timeZone)
        data.sessions = try LectureSession
            .where { $0.startsAt.lt(windowEnd) && $0.endsAt.gt(windowStart) }
            .order(by: \.startsAt)
            .fetchAll(db)

        let candidates = try Lecture
            .where { $0.reviewedAt.is(nil) }
            .order { ($0.heldAt.desc(), $0.createdAt.desc()) }
            .fetchAll(db)
        for lecture in candidates where data.courses[lecture.courseID] != nil {
            let lectureID = lecture.id
            guard try TranscriptSegment.where({ $0.lectureID.eq(lectureID) }).fetchCount(db) > 0 else { continue }
            data.review = try candidate(lecture, db: db)
            let courseID = lecture.courseID
            data.nextLectures = try LectureSession
                .where { $0.courseID.eq(courseID) && $0.startsAt.gte(windowStart) && !$0.isCancelled && $0.kind.eq(SessionKind.lecture) }
                .order(by: \.startsAt)
                .limit(8)
                .fetchAll(db)
            break
        }
        return data
    }

    private func candidate(_ lecture: Lecture, db: Database) throws -> ReviewCandidate {
        let lectureID = lecture.id
        let recording = try Recording.where { $0.lectureID.eq(lectureID) }.order(by: \.startedAt).fetchOne(db)
        let spans = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchAll(db)
        // The slides that were discussed (aligned visits); before alignment, the deck's link.
        let visits = spans.filter { $0.startTime != nil && $0.firstPage != nil }
        let coarse = spans.filter { $0.startTime == nil && $0.firstPage != nil }
        let pageSpans = visits.isEmpty ? coarse : visits
        let deckID = pageSpans.first?.deckID
        let deck = try deckID.flatMap { id in try Deck.find(id).fetchOne(db) }
        let first = pageSpans.filter { $0.deckID == deckID }.compactMap(\.firstPage).min()
        let last = pageSpans.filter { $0.deckID == deckID }.compactMap(\.lastPage).max()
        return ReviewCandidate(
            lecture: lecture,
            recordedAt: recording?.startedAt ?? lecture.heldAt,
            duration: recording.map(\.duration).flatMap { $0 > 0 ? $0 : nil },
            firstPage: first,
            lastPage: last,
            pageCount: deck?.pageCount
        )
    }
}
