import Courses
import Foundation
import StudyCore

/// What Today shows, read in one transaction: the newest lecture waiting for review, the
/// sessions around the day, the open items coming up with their sources, and the unread mail.
struct TodayData: Hashable, Sendable {
    var courses: [Course.ID: Course] = [:]
    var review: ReviewCandidate?
    /// Sessions overlapping the day before through eight days after (cancelled included).
    var sessions: [LectureSession] = []
    /// Upcoming non-cancelled lecture sessions of the review lecture's course.
    var nextLectures: [LectureSession] = []
    /// Open items due from the start of the day through `TodayPlan.itemDays` days on, the open
    /// items tied to `sessions`, and later events of the same course and title as one of those
    /// (Project Days "and Fri 13 Nov").
    var items: [TrackedItem] = []
    /// Their sources with what the popover shows (`TrackedItemRepository.trails(itemIDs:in:)`).
    var trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]
    /// Unread inbox mail per course and category; the mail line shows only with an account.
    var unread = MailUnreadCounts()
    var hasMailAccount = false
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

        data.items = try items(sessionIDs: data.sessions.map(\.id), db: db)
        data.trails = try TrackedItemRepository.trails(itemIDs: data.items.map(\.id), in: db)
        data.hasMailAccount = try MailAccount.all.fetchCount(db) > 0
        if data.hasMailAccount {
            data.unread = try MailRepository.unreadCounts(in: db)
        }

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

    /// The open items Coming up may show (`TodayData.items`); the plan decides which.
    private func items(sessionIDs: [LectureSession.ID], db: Database) throws -> [TrackedItem] {
        let open = TrackedItemStatus.open
        let start = Date?.some(day.start(in: timeZone))
        let horizon = Date?.some(day.adding(days: TodayPlan.itemDays + 1).start(in: timeZone))
        var items = try TrackedItem
            .where { $0.status.eq(open) && $0.dueAt.gte(start) && $0.dueAt.lt(horizon) }
            .order(by: \.dueAt)
            .fetchAll(db)
        var seen = Set(items.map(\.id))
        if !sessionIDs.isEmpty {
            let ids = sessionIDs.map { Optional.some($0) }
            let tied = try TrackedItem
                .where { $0.status.eq(open) && $0.lectureSessionID.in(ids) }
                .fetchAll(db)
            for item in tied where seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        // Later days of an event in the window, for its "and Fri 13 Nov".
        let event = TrackedItemKind.event
        let repeated = Set(items.filter { $0.kind == event && $0.lectureSessionID == nil }.map(TodayPlan.EventKey.init))
        if !repeated.isEmpty {
            let later = try TrackedItem
                .where { $0.status.eq(open) && $0.kind.eq(event) && $0.dueAt.gte(horizon) }
                .order(by: \.dueAt)
                .fetchAll(db)
            for item in later where repeated.contains(TodayPlan.EventKey(item)) && seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        return items
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
