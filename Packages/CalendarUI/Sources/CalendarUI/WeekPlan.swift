import CalendarSync
import Foundation
import StudyCore
import StudyUI

/// The week grid's sizes (docs/DESIGN.md §3.3, mockup 06).
enum GridMetrics {
    static let gutter: CGFloat = 44
    static let headerHeight: CGFloat = 40
    static let allDayHeight: CGFloat = 28
    static let hourHeight: CGFloat = 56
    static let weekendWidth: CGFloat = 36
    /// Room above 00:00 and below 24:00, so the first and last hour labels are not cut.
    static let inset: CGFloat = 8
    /// The hour the grid opens at.
    static let openingHour = 8
    static let pillHeight: CGFloat = 19
    static let pillSpacing: CGFloat = 2

    /// The y of a wall-clock minute in the scrolling body.
    static func y(minute: Int) -> CGFloat {
        inset + CGFloat(minute) * hourHeight / 60
    }

    static var bodyHeight: CGFloat { inset * 2 + 24 * hourHeight }

    /// Where the body scrolls to when it opens: 08:00 sits `inset` below the all-day row.
    static var openingOffset: CGFloat { y(minute: openingHour * 60) - inset }

    /// The all-day row grows with the most pills on one day (28 for one).
    static func allDayHeight(pills: Int) -> CGFloat {
        guard pills > 1 else { return allDayHeight }
        return 4 + CGFloat(pills) * pillHeight + CGFloat(pills - 1) * pillSpacing + 5
    }
}

/// The columns at a width: the gutter, five weekdays sharing what is left, Saturday and Sunday
/// 36 pt each.
struct WeekColumns: Hashable {
    let width: CGFloat

    var dayWidth: CGFloat {
        max(0, (width - GridMetrics.gutter - 2 * GridMetrics.weekendWidth) / 5)
    }

    func x(_ index: Int) -> CGFloat {
        GridMetrics.gutter + CGFloat(min(index, 5)) * dayWidth + CGFloat(max(0, index - 5)) * GridMetrics.weekendWidth
    }

    func width(_ index: Int) -> CGFloat {
        index >= 5 ? GridMetrics.weekendWidth : dayWidth
    }
}

/// What is selected in the grid and the inspector.
enum CalendarSelection: Hashable, Sendable {
    case session(LectureSession.ID)
    case item(TrackedItem.ID)
}

/// What the grid draws where, for one week: pure, so it is tested without a view.
struct WeekPlan: Equatable {
    /// A timed block: a session, a timed event item that is no session (an exam review from the
    /// timetable), or an event of another calendar (read-only).
    struct Event: Identifiable, Hashable {
        var id: String
        var day: Int
        var startMinute: Int
        var endMinute: Int
        var lane = 0
        var lanes = 1
        /// "10:15–11:45".
        var time: String
        var title: String
        /// The room (course sub-text).
        var subtitle: String?
        /// A waiting room change or cancellation: "Room 5?".
        var proposalTag: String?
        var proposalID: TrackedItem.ID?
        /// `#rrggbb`; nil = the accent.
        var colorHex: String?
        var isCancelled = false
        var sessionID: LectureSession.ID?
        /// An event item drawn as a block.
        var itemID: TrackedItem.ID?
        var courseID: Course.ID?
        var lectureID: Lecture.ID?

        var isForeign: Bool { sessionID == nil && itemID == nil }

        /// What a click selects; nil for another calendar's event.
        var target: CalendarSelection? {
            if let sessionID { return .session(sessionID) }
            return itemID.map(CalendarSelection.item)
        }
    }

    /// An event item's block length: the hour the calendar mirror gives it (decisions: "Deadline
    /// events"), since `tracked_item` keeps no end.
    static let eventMinutes = 60

    /// A timed due item: a line at its time with a dot and a tag.
    struct Due: Identifiable, Hashable {
        var id: TrackedItem.ID
        var day: Int
        var minute: Int
        var title: String
        var colorHex: String?
    }

    /// An all-day pill: an item due on the day (all-day or at 23:59), or another calendar's
    /// all-day event.
    struct Pill: Identifiable, Hashable {
        var id: String
        var day: Int
        var title: String
        var colorHex: String?
        var itemID: TrackedItem.ID?
    }

    /// The composer's parse, drawn dashed.
    struct Preview: Hashable {
        var day: Int
        /// Nil: an all-day pill.
        var minute: Int?
        var title: String
        var colorHex: String?
    }

    var events: [Event] = []
    var dues: [Due] = []
    var pills: [Pill] = []
    var preview: Preview?

    /// The most pills on one day (the preview's included).
    var maxPills: Int {
        var counts = [Int](repeating: 0, count: 7)
        for pill in pills { counts[pill.day] += 1 }
        if let preview, preview.minute == nil { counts[preview.day] += 1 }
        return counts.max() ?? 0
    }

    /// 23:59: a deadline at the end of the day (mockup 06's Quiz 1 is an all-day pill).
    static let endOfDay = 23 * 60 + 59

    static func make(
        data: CalendarData,
        week: CalendarWeek,
        timeZone: TimeZone,
        showsStudyPortal: Bool = true,
        foreignEvents: [ForeignEvent] = [],
        foreignColors: [String: String] = [:],
        preview draft: DeadlineDraft? = nil
    ) -> WeekPlan {
        var plan = WeekPlan()
        func slot(_ date: Date) -> (day: Int, minute: Int)? {
            guard let day = week.index(of: CalendarDay(date, in: timeZone)) else { return nil }
            return (day, WallClock.minute(of: date, in: timeZone))
        }
        func range(_ start: Date, _ end: Date) -> String { DayText.timeRange(start, end, timeZone: timeZone) }

        if showsStudyPortal {
            var proposals: [LectureSession.ID: TrackedItem] = [:]
            for item in data.proposals {
                if let id = item.lectureSessionID, proposals[id] == nil { proposals[id] = item }
            }
            for session in data.sessions {
                guard let start = slot(session.startsAt) else { continue }
                let course = data.courses[session.courseID]
                let end = Self.endMinute(session.endsAt, startDay: start.day, week: week, timeZone: timeZone)
                let room = session.room.trimmingCharacters(in: .whitespaces)
                let proposal = proposals[session.id]
                plan.events.append(Event(
                    id: session.id.uuidString,
                    day: start.day,
                    startMinute: start.minute,
                    endMinute: max(end, start.minute + 15),
                    time: range(session.startsAt, session.endsAt),
                    title: CalendarText.eventTitle(session, course: course),
                    subtitle: room.isEmpty ? nil : room,
                    proposalTag: proposal.map(CalendarText.proposalTag),
                    proposalID: proposal?.id,
                    colorHex: course?.colorHex,
                    isCancelled: session.isCancelled,
                    sessionID: session.id,
                    courseID: session.courseID,
                    lectureID: data.lectures[session.id]
                ))
            }
            for item in data.weekItems {
                // An event tied to a session is that session in the grid (Today names its row).
                if item.kind == .event, item.lectureSessionID != nil { continue }
                guard let due = item.dueAt, let at = slot(due) else { continue }
                let color = item.courseID.flatMap { data.courses[$0]?.colorHex }
                if item.kind == .event, !item.isAllDay, at.minute != Self.endOfDay {
                    // A timed event that is no session (an exam review): a block like a session,
                    // labelled with its start alone (its end is not stored).
                    let rooms = CalendarText.rooms(item)
                    plan.events.append(Event(
                        id: item.id.uuidString,
                        day: at.day,
                        startMinute: at.minute,
                        endMinute: min(24 * 60, at.minute + Self.eventMinutes),
                        time: DayText.time(due, timeZone: timeZone),
                        title: CalendarText.blockTitle(item, course: item.courseID.flatMap { data.courses[$0] }),
                        subtitle: rooms.isEmpty ? nil : rooms,
                        colorHex: color,
                        itemID: item.id,
                        courseID: item.courseID
                    ))
                    continue
                }
                if item.isAllDay || at.minute == Self.endOfDay {
                    plan.pills.append(Pill(id: item.id.uuidString, day: at.day, title: item.title, colorHex: color, itemID: item.id))
                } else {
                    plan.dues.append(Due(id: item.id, day: at.day, minute: at.minute, title: item.title, colorHex: color))
                }
            }
        }

        for event in foreignEvents {
            let color = foreignColors[event.calendarID]
            if event.isAllDay {
                // One pill per day the event covers within the week.
                var day = CalendarDay(event.startsAt, in: timeZone)
                let last = CalendarDay(event.endsAt.addingTimeInterval(-1), in: timeZone)
                while day <= last {
                    if let index = week.index(of: day) {
                        plan.pills.append(Pill(id: "\(event.id)|\(index)", day: index, title: event.title, colorHex: color))
                    }
                    day = day.adding(days: 1)
                }
                continue
            }
            guard let start = slot(event.startsAt) else { continue }
            let end = Self.endMinute(event.endsAt, startDay: start.day, week: week, timeZone: timeZone)
            plan.events.append(Event(
                id: event.id, day: start.day, startMinute: start.minute, endMinute: max(end, start.minute + 15),
                time: range(event.startsAt, event.endsAt), title: event.title, colorHex: color
            ))
        }

        if let draft, let due = draft.dueAt, let at = slot(due) {
            let color = draft.courseID.flatMap { data.courses[$0]?.colorHex }
            let allDay = draft.isAllDay || at.minute == Self.endOfDay
            plan.preview = Preview(day: at.day, minute: allDay ? nil : at.minute, title: draft.title, colorHex: color)
        }

        plan.events = Self.laidOut(plan.events)
        plan.dues.sort { ($0.day, $0.minute) < ($1.day, $1.minute) }
        return plan
    }

    /// The end as minutes of the start's day (an end on a later day runs to midnight).
    static func endMinute(_ end: Date, startDay: Int, week: CalendarWeek, timeZone: TimeZone) -> Int {
        let endDay = week.monday.days(to: CalendarDay(end, in: timeZone))
        if endDay > startDay { return 24 * 60 }
        return WallClock.minute(of: end, in: timeZone)
    }

    /// Overlapping blocks of a day share its width in lanes.
    static func laidOut(_ events: [Event]) -> [Event] {
        var result: [Event] = []
        for day in 0..<7 {
            let sorted = events.filter { $0.day == day }.sorted { ($0.startMinute, $0.endMinute, $0.id) < ($1.startMinute, $1.endMinute, $1.id) }
            var cluster: [Event] = []
            var laneEnds: [Int] = []
            var clusterEnd = -1
            func flush() {
                let lanes = max(1, laneEnds.count)
                result += cluster.map { event in
                    var event = event
                    event.lanes = lanes
                    return event
                }
                cluster = []
                laneEnds = []
            }
            for var event in sorted {
                if event.startMinute >= clusterEnd { flush() }
                if let lane = laneEnds.firstIndex(where: { $0 <= event.startMinute }) {
                    event.lane = lane
                    laneEnds[lane] = event.endMinute
                } else {
                    event.lane = laneEnds.count
                    laneEnds.append(event.endMinute)
                }
                clusterEnd = max(clusterEnd, event.endMinute)
                cluster.append(event)
            }
            flush()
        }
        return result
    }
}
