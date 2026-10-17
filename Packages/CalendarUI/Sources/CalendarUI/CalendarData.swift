import Foundation
import StudyCore

/// What the Calendar screen shows for one week, read in one transaction: the grid's sessions and
/// items, and the inspector's proposals and due items (from today on) with their source trails.
/// The "Study Portal" EventKit calendar is never read back: it is the mirror of these rows.
struct CalendarData: Hashable, Sendable {
    /// The week these rows are for (nil before the first read): the grid keeps drawing it until
    /// the next week's rows land, so a week switch never shows an empty frame.
    var week: CalendarWeek?
    var courses: [Course.ID: Course] = [:]
    /// Sessions overlapping the week (cancelled included).
    var sessions: [LectureSession] = []
    /// The lecture filed for a session of the week (double-click opens it).
    var lectures: [LectureSession.ID: Lecture.ID] = [:]
    /// Open items due in the week that the grid draws: due kinds and events.
    var weekItems: [TrackedItem] = []
    /// Open room changes and cancellations of sessions from today on, soonest first.
    var proposals: [TrackedItem] = []
    /// Open due items (deadlines, exercises, exams) from today on, soonest first.
    var upcoming: [TrackedItem] = []
    /// The sessions proposals and listed items are tied to (any week).
    var linkedSessions: [LectureSession.ID: LectureSession] = [:]
    var trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]

    /// Every item of the screen by id.
    var item: [TrackedItem.ID: TrackedItem] {
        Dictionary((weekItems + proposals + upcoming).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
}

struct CalendarRequest: FetchKeyRequest {
    let week: CalendarWeek
    let today: CalendarDay
    let timeZone: TimeZone

    static let dueKinds: [TrackedItemKind] = [.deadline, .exercise, .exam]
    static let gridKinds: [TrackedItemKind] = dueKinds + [.event]
    static let proposalKinds: [TrackedItemKind] = [.roomChange, .cancellation]

    func fetch(_ db: Database) throws -> CalendarData {
        var data = CalendarData(week: week)
        let courses = try Course.all.fetchAll(db)
        data.courses = Dictionary(courses.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let start = week.start(in: timeZone)
        let end = week.end(in: timeZone)
        data.sessions = try LectureSession
            .where { $0.startsAt.lt(end) && $0.endsAt.gt(start) }
            .order(by: \.startsAt)
            .fetchAll(db)
        let sessionIDs = data.sessions.map { LectureSession.ID?.some($0.id) }
        if !sessionIDs.isEmpty {
            for lecture in try Lecture.where({ $0.lectureSessionID.in(sessionIDs) }).fetchAll(db) {
                if let sessionID = lecture.lectureSessionID, data.lectures[sessionID] == nil { data.lectures[sessionID] = lecture.id }
            }
        }

        let open = TrackedItemStatus.open
        let gridKinds = Self.gridKinds
        data.weekItems = try TrackedItem
            .where { $0.status.eq(open) && $0.kind.in(gridKinds) && $0.dueAt.gte(Date?.some(start)) && $0.dueAt.lt(Date?.some(end)) }
            .order(by: \.dueAt)
            .fetchAll(db)

        let todayStart = today.start(in: timeZone)
        let dueKinds = Self.dueKinds
        data.upcoming = try TrackedItem
            .where { $0.status.eq(open) && $0.kind.in(dueKinds) && $0.dueAt.gte(Date?.some(todayStart)) }
            .order(by: \.dueAt)
            .fetchAll(db)
        let proposalKinds = Self.proposalKinds
        data.proposals = try TrackedItem
            .where { $0.status.eq(open) && $0.kind.in(proposalKinds) }
            .order(by: \.dueAt)
            .fetchAll(db)
            .filter { ($0.dueAt ?? .distantFuture) >= todayStart }

        let linked = Array(Set((data.proposals + data.upcoming).compactMap(\.lectureSessionID)))
        if !linked.isEmpty {
            let sessions = try LectureSession.where { $0.id.in(linked) }.fetchAll(db)
            data.linkedSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        let itemIDs = Array(Set((data.weekItems + data.proposals + data.upcoming).map(\.id)))
        data.trails = try TrackedItemRepository.trails(itemIDs: itemIDs, in: db)
        return data
    }
}
