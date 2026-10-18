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
    /// The weekly slots the week's sessions come from (the detail popover's "weekly").
    var slots: [WeeklySlot.ID: WeeklySlot] = [:]
    /// What the detail popover says about the lectures of the week's sessions.
    var lectureInfo: [Lecture.ID: LectureInfo] = [:]
    /// Items tied to the week's sessions, open or settled (not dismissed): room changes,
    /// cancellations, an event that is the session. The session's detail popover lists them with
    /// their sources.
    var sessionItems: [LectureSession.ID: [TrackedItem]] = [:]

    /// Every item of the screen by id.
    var item: [TrackedItem.ID: TrackedItem] {
        Dictionary(
            (weekItems + proposals + upcoming + sessionItems.values.flatMap(\.self)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// A session's lecture as its detail popover shows it: "L2 · Virtualization & IaaS", the
/// recording's length and the study pass's "5 highlights, 3 not on the slides".
struct LectureInfo: Hashable, Sendable {
    var lecture: Lecture
    /// Seconds of the first recording.
    var duration: Double?
    /// The professor's items the study pass found (exam hints and highlights), hidden ones left out.
    var highlights = 0
    /// What was said in class but is not on the slides, hidden ones left out.
    var notOnSlides = 0
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
                if let sessionID = lecture.lectureSessionID, data.lectures[sessionID] == nil {
                    data.lectures[sessionID] = lecture.id
                    data.lectureInfo[lecture.id] = try Self.info(lecture, db: db)
                }
            }
            let dismissed = TrackedItemStatus.dismissed
            let tied = try TrackedItem
                .where { $0.lectureSessionID.in(sessionIDs) && !$0.status.eq(dismissed) }
                .order(by: \.createdAt)
                .fetchAll(db)
            for item in tied {
                if let sessionID = item.lectureSessionID { data.sessionItems[sessionID, default: []].append(item) }
            }
        }
        let slotIDs = Array(Set(data.sessions.compactMap(\.weeklySlotID)))
        if !slotIDs.isEmpty {
            let slots = try WeeklySlot.where { $0.id.in(slotIDs) }.fetchAll(db)
            data.slots = Dictionary(slots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

        let linked = Array(Set((data.proposals + data.upcoming + data.weekItems).compactMap(\.lectureSessionID)))
        if !linked.isEmpty {
            let sessions = try LectureSession.where { $0.id.in(linked) }.fetchAll(db)
            data.linkedSessions = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        let tied = data.sessionItems.values.flatMap(\.self)
        let itemIDs = Array(Set((data.weekItems + data.proposals + data.upcoming + tied).map(\.id)))
        data.trails = try TrackedItemRepository.trails(itemIDs: itemIDs, in: db)
        return data
    }

    /// The lecture's first recording's length and the study pass's counts (as Today's hero).
    static func info(_ lecture: Lecture, db: Database) throws -> LectureInfo {
        let lectureID = lecture.id
        let recording = try Recording.where { $0.lectureID.eq(lectureID) }.order(by: \.startedAt).fetchOne(db)
        let professorKinds = [AnnotationKind.examHint, AnnotationKind.highlight]
        let highlights = try Annotation
            .where { $0.lectureID.eq(lectureID) && $0.hiddenAt.is(nil) && $0.layer.eq(AnnotationLayer.professor) && $0.kind.in(professorKinds) }
            .fetchCount(db)
        let notOnSlides = try Annotation
            .where { $0.lectureID.eq(lectureID) && $0.hiddenAt.is(nil) && $0.layer.eq(AnnotationLayer.ai) && $0.kind.eq(AnnotationKind.notOnSlides) }
            .fetchCount(db)
        return LectureInfo(
            lecture: lecture,
            duration: recording.map(\.duration).flatMap { $0 > 0 ? $0 : nil },
            highlights: highlights,
            notOnSlides: notOnSlides
        )
    }
}
