import Courses
import Foundation
import StudyCore

/// What Today puts where, for one moment (pure: tested without a view).
///
/// Three zones (mockup 01, docs/DESIGN.md §8.1): the hero, Coming up (one dated list of sessions
/// and items, each fact once) and the mail line (it only counts; what mail said is in the rows).
struct TodayPlan: Equatable {
    enum Hero: Equatable {
        case review(ReviewCandidate)
        case session(LectureSession)
    }

    var hero: Hero?
    /// The review course's next lecture (the hero's aside).
    var nextLecture: LectureSession?
    var comingUp: [ComingUpEntry]
    var mail: MailLine?
    var hasClassesToday: Bool

    /// A class this close lets the hero offer Record.
    static let recordLead: TimeInterval = 30 * 60
    /// Sessions are listed for the day and the next seven days.
    static let sessionDays = 8
    /// Dated items are listed through this many days after today.
    static let itemDays = 21

    /// Nothing at all to show: the screen is the `sun.max` glyph.
    var isEmpty: Bool { hero == nil && comingUp.isEmpty && mail == nil }

    init(data: TodayData, now: Date, timeZone: TimeZone) {
        let today = CalendarDay(now, in: timeZone)
        let horizon = today.adding(days: Self.sessionDays).start(in: timeZone)
        let known = data.sessions.filter { data.courses[$0.courseID] != nil }
        hasClassesToday = known.contains { !$0.isCancelled && CalendarDay($0.startsAt, in: timeZone) == today }

        var shown: Set<LectureSession.ID> = []
        if let review = data.review {
            hero = .review(review)
            nextLecture = data.nextLectures.first { $0.startsAt > now }
            if let nextLecture { shown.insert(nextLecture.id) }
        } else if let next = known.first(where: { !$0.isCancelled && $0.endsAt > now }) {
            hero = .session(next)
            shown.insert(next.id)
        }
        // Everything but the weekly lectures (mockup 01): exercises, tutorials, seminars and
        // one-off sessions; a cancelled lecture stays, struck through, so it can be restored.
        let sessions = known.filter {
            $0.endsAt > now && $0.startsAt < horizon && !shown.contains($0.id) && ($0.kind != .lecture || $0.isCancelled)
        }
        comingUp = Self.comingUp(sessions: sessions, data: data, now: now, timeZone: timeZone)
        mail = MailLine(data: data)
    }

    func canRecord(_ session: LectureSession, courses: [Course.ID: Course], now: Date) -> Bool {
        guard let course = courses[session.courseID], course.recordsLectures, !session.isCancelled else { return false }
        return session.startsAt.addingTimeInterval(-Self.recordLead) <= now && now < session.endsAt
    }

    // MARK: Coming up

    /// Events of one course with the same title are one row ("Project Days", two days).
    struct EventKey: Hashable {
        var courseID: Course.ID?
        var title: String

        init(_ item: TrackedItem) {
            courseID = item.courseID
            title = item.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    /// Sessions and items in one list, soonest first. An item tied to a listed session folds into
    /// that session's row (an event names it and gives the gloss, an announcement gives the gloss,
    /// both add their sources); items tied to sessions that are not listed are left out, except
    /// due items, which always have their own row. Proposals (Calendar's), undated items and items
    /// already past are not shown.
    static func comingUp(sessions: [LectureSession], data: TodayData, now: Date, timeZone: TimeZone) -> [ComingUpEntry] {
        let today = CalendarDay(now, in: timeZone)
        let itemHorizon = today.adding(days: itemDays + 1).start(in: timeZone)
        let listed = Set(sessions.map(\.id))

        var folded: [LectureSession.ID: [TrackedItem]] = [:]
        var due: [TrackedItem] = []
        var events: [EventKey: [TrackedItem]] = [:]
        for item in data.items where item.status == .open && !item.kind.isSessionProposal {
            if !item.kind.isDue, let sessionID = item.lectureSessionID {
                if listed.contains(sessionID) { folded[sessionID, default: []].append(item) }
                continue
            }
            guard let dueAt = item.dueAt else { continue }
            let upcoming = item.isAllDay ? CalendarDay(dueAt, in: timeZone) >= today : dueAt > now
            guard upcoming else { continue }
            if item.kind.isDue {
                if dueAt < itemHorizon { due.append(item) }
            } else {
                events[EventKey(item), default: []].append(item)
            }
        }

        var entries: [ComingUpEntry] = []
        for session in sessions {
            let course = data.courses[session.courseID]
            // The event first (it names the row), then announcements, oldest first.
            let items = (folded[session.id] ?? []).sorted {
                ($0.kind == .event ? 0 : 1, $0.createdAt) < ($1.kind == .event ? 0 : 1, $1.createdAt)
            }
            let event = items.first { $0.kind == .event }
            let glosses = items.compactMap { item -> String? in
                let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
                if item.kind == .event { return details.isEmpty ? nil : details }
                return details.isEmpty ? item.title : details
            }
            var entry = ComingUpEntry(
                id: session.id, session: session, items: items, courseID: session.courseID, marker: .bar,
                title: event?.title ?? SessionText.title(of: session, courseName: course?.name ?? "", shortName: course?.shortName ?? ""),
                date: session.startsAt, end: session.endsAt, isAllDay: false, gloss: glosses.first
            )
            entry.attachSources(data.trails)
            entries.append(entry)
        }
        for item in due {
            var entry = ComingUpEntry(
                id: item.id, items: [item], courseID: item.courseID, marker: .ring, title: item.title,
                date: item.dueAt ?? now, isAllDay: item.isAllDay, gloss: Self.gloss(item)
            )
            entry.attachSources(data.trails)
            entries.append(entry)
        }
        for group in events.values {
            let days = group.sorted { ($0.dueAt ?? now) < ($1.dueAt ?? now) }
            guard let first = days.first, let dueAt = first.dueAt, dueAt < itemHorizon else { continue }
            var entry = ComingUpEntry(
                id: first.id, items: days, courseID: first.courseID, marker: .bar, title: first.title,
                date: dueAt, isAllDay: first.isAllDay, gloss: days.lazy.compactMap(Self.gloss).first,
                laterDays: days.dropFirst().compactMap(\.dueAt)
            )
            entry.attachSources(data.trails)
            entries.append(entry)
        }
        return entries.sorted {
            ($0.date, $0.session == nil ? 1 : 0, $0.title) < ($1.date, $1.session == nil ? 1 : 0, $1.title)
        }
    }

    private static func gloss(_ item: TrackedItem) -> String? {
        let details = item.details.trimmingCharacters(in: .whitespacesAndNewlines)
        return details.isEmpty ? nil : details
    }
}

/// One row of Coming up: a session with the items folded into it, a due item, or one event on
/// one or more days.
struct ComingUpEntry: Identifiable, Equatable {
    enum Marker: Equatable {
        /// A class or event: the course bar.
        case bar
        /// Something due: `DueRing`.
        case ring
    }

    /// The session's id, else the (first) item's.
    var id: UUID
    var session: LectureSession?
    /// The row's own items (a due item, an event's days) or the items folded into the session.
    var items: [TrackedItem]
    var courseID: Course.ID?
    var marker: Marker
    var title: String
    /// The session's start or the item's due time (its day when all-day).
    var date: Date
    /// The session's end.
    var end: Date?
    var isAllDay: Bool
    /// One grey line: an item's details, or what an announcement says about the session.
    var gloss: String?
    /// The same event on later days ("and Fri 13 Nov").
    var laterDays: [Date] = []
    /// The items' sources, oldest first (one row per recording moment or mail).
    var trail: [SourceTrailEntry] = []
    /// An item of the row is in the calendar (the popover's green check).
    var inCalendar = false
    /// The newest source still in effect that added an item on its own or changed it: Undo.
    var undoSourceID: TrackedItemSource.ID?
    /// An item is required for exam admission (the amber star before the gloss).
    var isExamAdmission = false

    var isCancelled: Bool { session?.isCancelled ?? false }

    /// Item rows offer Add to Calendar for days that are not in the calendar yet.
    var itemsOutsideCalendar: [TrackedItem] { session == nil ? items.filter { !$0.inCalendar && $0.dueAt != nil } : [] }

    mutating func attachSources(_ trails: [TrackedItem.ID: [SourceTrailEntry]]) {
        var seen: Set<String> = []
        trail = items
            .flatMap { trails[$0.id] ?? [] }
            .sorted { $0.source.createdAt < $1.source.createdAt }
            .filter { seen.insert(Self.key($0)).inserted }
        inCalendar = items.contains(where: \.inCalendar)
        undoSourceID = items
            .flatMap { trails[$0.id] ?? [] }
            .filter { $0.isActive && ($0.source.calendarAdded || $0.source.previous != nil) }
            .max { $0.source.createdAt < $1.source.createdAt }?
            .id
        isExamAdmission = items.contains { $0.relevance == .examAdmission }
        if isExamAdmission, gloss == nil {
            gloss = String(localized: "Exam admission")
        }
    }

    /// One popover row per recording moment or mail: the days of one event share their source.
    private static func key(_ entry: SourceTrailEntry) -> String {
        let source = entry.source
        switch source.kind {
        case .mail:
            return "mail \(source.mailMessageID?.uuidString ?? source.rfcMessageID) \(entry.isActive)"
        case .transcript:
            let time = source.time.map { String(Int($0.rounded())) } ?? ""
            return "said \(source.recordingID?.uuidString ?? "") \(time) \(entry.isActive)"
        default:
            return "source \(source.id.uuidString)"
        }
    }
}

/// The mail line: "5 unread · ● 3 ● 1 · 1 newsletter" + Open Mail. Only with an account and
/// unread mail.
struct MailLine: Equatable {
    struct CourseCount: Equatable {
        var courseID: Course.ID
        var count: Int
    }

    var unread: Int
    /// Per course with unread mail, in course order.
    var courses: [CourseCount]
    var newsletters: Int

    init(unread: Int, courses: [CourseCount], newsletters: Int) {
        self.unread = unread
        self.courses = courses
        self.newsletters = newsletters
    }

    init?(data: TodayData) {
        guard data.hasMailAccount, data.unread.inbox > 0 else { return nil }
        unread = data.unread.inbox
        courses = data.courses.values
            .sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
            .compactMap { course in
                guard let count = data.unread.byCourse[course.id], count > 0 else { return nil }
                return CourseCount(courseID: course.id, count: count)
            }
        newsletters = data.unread.byCategory[.newsletter] ?? 0
    }
}
