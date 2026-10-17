import Foundation
import StudyCore

/// What a replan changes. Rows are not stamped yet: `CourseSchedule` stamps and writes them in one
/// transaction.
public struct SessionPlan: Hashable, Sendable {
    /// New generated sessions (numbered).
    public var inserted: [LectureSession]
    /// Existing sessions whose time, room, kind, slot or number changed. Ids, lecture links and
    /// calendar event ids are kept.
    public var updated: [LectureSession]
    /// Generated sessions no slot plans any more: future ones that no lecture or filing points to.
    public var deleted: [LectureSession]

    public init(inserted: [LectureSession] = [], updated: [LectureSession] = [], deleted: [LectureSession] = []) {
        self.inserted = inserted
        self.updated = updated
        self.deleted = deleted
    }

    public static let empty = SessionPlan()

    /// Nothing to write.
    public var isEmpty: Bool { inserted.isEmpty && updated.isEmpty && deleted.isEmpty }
}

/// Turns weekly slots into lecture sessions for a semester and reconciles them with the sessions
/// already in the library (PRD #36). Pure: no database, no clock.
///
/// Rules (docs/plan-m1.md §3):
/// - A slot meets on every day with its weekday from `max(lectureStart, validFrom)` to
///   `min(lectureEnd, validUntil)` that is a lecture day (breaks skipped) and fits the week parity
///   of `weekInterval`, counted from the first slot weekday on or after `validFrom` (else the
///   lecture start).
/// - Times are wall-clock in the slot's time zone, so 10:15 stays 10:15 across a DST change.
/// - Generated sessions (`editedAt == nil`) are matched by (slot, day) and updated in place. A
///   generated session left over after that (its slot moved to another weekday, or was deleted and
///   replaced) is updated in place onto a still-free planned day of the same course and kind in
///   the same week, so ids, lecture links and calendar events survive a timetable correction.
/// - Edited sessions are never changed (except `number`); each one holds on to the free planned
///   day of its slot nearest to it (within three weeks), so a cancelled or moved session is not
///   planned again.
/// - Planned days nobody holds get a new session. Generated sessions that are still unplanned are
///   deleted only when they lie in the future and no lecture (or filing) points to them.
/// - Numbers: per course and kind, the non-cancelled sessions in start order are 1…n; cancelled
///   sessions have none.
public struct SessionPlanner: Sendable {
    /// How far an edited session may be from the planned day it stands in for.
    public static let editedReach = 21

    public init() {}

    /// The days a slot meets in `semester`, in order.
    public func days(for slot: WeeklySlot, in semester: Semester) -> [CalendarDay] {
        guard (1...7).contains(slot.weekday) else { return [] }
        let interval = max(1, slot.weekInterval)
        let first = max(semester.lectureStart, slot.validFrom ?? semester.lectureStart)
        let last = min(semester.lectureEnd, slot.validUntil ?? semester.lectureEnd)
        guard first <= last else { return [] }
        let parityBase = slot.validFrom ?? semester.lectureStart
        let anchor = parityBase.adding(days: Self.offset(from: parityBase.weekday, to: slot.weekday))
        var day = first.adding(days: Self.offset(from: first.weekday, to: slot.weekday))
        var days: [CalendarDay] = []
        while day <= last {
            let weeks = anchor.days(to: day) / 7
            if weeks % interval == 0, semester.isLectureDay(day) {
                days.append(day)
            }
            day = day.adding(days: 7)
        }
        return days
    }

    /// The session a slot plans on `day` (new id, not stamped).
    public func session(for slot: WeeklySlot, on day: CalendarDay, semester: Semester) -> LectureSession {
        var session = LectureSession(courseID: slot.courseID, startsAt: Date(), endsAt: Date())
        apply(slot, day: day, zone: zone(of: slot, semester: semester), to: &session)
        return session
    }

    /// Reconciles `existing` (all sessions of the courses the slots belong to) with what `slots`
    /// plan in `semester`. `filed` lists sessions a lecture or filing points to; they are never
    /// deleted. `now` decides what counts as the future.
    public func plan(
        slots: [WeeklySlot],
        semester: Semester,
        existing: [LectureSession],
        now: Date,
        filed: Set<LectureSession.ID> = []
    ) -> SessionPlan {
        let slotsByID = Dictionary(slots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var plannedDays: [WeeklySlot.ID: [CalendarDay]] = [:]
        for slot in slotsByID.values {
            plannedDays[slot.id] = days(for: slot, in: semester)
        }

        let ordered = existing.sorted(by: Self.timeOrder)
        var holder: [Occurrence: LectureSession.ID] = [:]
        var assignment: [LectureSession.ID: Occurrence] = [:]
        func hold(_ occurrence: Occurrence, by session: LectureSession) {
            holder[occurrence] = session.id
            assignment[session.id] = occurrence
        }
        func isPlannedAndFree(_ occurrence: Occurrence) -> Bool {
            holder[occurrence] == nil && plannedDays[occurrence.slotID]?.contains(occurrence.day) == true
        }

        // 1. Generated sessions on their own (slot, day).
        var leftovers: [LectureSession] = []
        for session in ordered where session.editedAt == nil {
            guard let slotID = session.weeklySlotID, let slot = slotsByID[slotID] else {
                leftovers.append(session)
                continue
            }
            let occurrence = Occurrence(slotID: slotID, day: CalendarDay(session.startsAt, in: zone(of: slot, semester: semester)))
            if isPlannedAndFree(occurrence) {
                hold(occurrence, by: session)
            } else {
                leftovers.append(session)
            }
        }

        // 2. Edited sessions hold the nearest free planned day of their slot.
        for session in ordered where session.editedAt != nil {
            guard let slotID = session.weeklySlotID, let slot = slotsByID[slotID], let days = plannedDays[slotID] else { continue }
            let day = CalendarDay(session.startsAt, in: zone(of: slot, semester: semester))
            let nearest = days
                .filter { holder[Occurrence(slotID: slotID, day: $0)] == nil && abs($0.days(to: day)) <= Self.editedReach }
                .min { abs($0.days(to: day)) < abs($1.days(to: day)) }
            if let nearest {
                hold(Occurrence(slotID: slotID, day: nearest), by: session)
            }
        }

        // 3. Leftover generated sessions move onto a free planned day of the same course and kind
        //    in their week (a slot moved to another weekday, or replaced by a new slot).
        var unplanned: [LectureSession] = []
        for session in leftovers {
            let reference = session.weeklySlotID.flatMap { slotsByID[$0] }
            let day = CalendarDay(session.startsAt, in: reference.map { zone(of: $0, semester: semester) } ?? semester.zone)
            let monday = day.adding(days: 1 - day.weekday)
            let candidates = slotsByID.values
                .filter { $0.courseID == session.courseID && $0.kind == session.kind }
                .flatMap { slot in
                    (plannedDays[slot.id] ?? [])
                        .filter { $0 >= monday && $0 < monday.adding(days: 7) }
                        .map { Occurrence(slotID: slot.id, day: $0) }
                }
                .filter { holder[$0] == nil }
                .sorted { lhs, rhs in
                    let lhsSame = lhs.slotID == session.weeklySlotID
                    let rhsSame = rhs.slotID == session.weeklySlotID
                    if lhsSame != rhsSame { return lhsSame }
                    let lhsDistance = abs(lhs.day.days(to: day))
                    let rhsDistance = abs(rhs.day.days(to: day))
                    if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
                    return (lhs.day, lhs.slotID.uuidString) < (rhs.day, rhs.slotID.uuidString)
                }
            if let target = candidates.first {
                hold(target, by: session)
            } else {
                unplanned.append(session)
            }
        }

        // 4. Updates in place for generated sessions that hold a planned day.
        var final: [LectureSession.ID: LectureSession] = [:]
        var original: [LectureSession.ID: LectureSession] = [:]
        for session in existing {
            original[session.id] = session
            final[session.id] = session
        }
        for (sessionID, occurrence) in assignment {
            guard var session = final[sessionID], session.editedAt == nil, let slot = slotsByID[occurrence.slotID] else { continue }
            apply(slot, day: occurrence.day, zone: zone(of: slot, semester: semester), to: &session)
            final[sessionID] = session
        }

        // 5. New sessions for free planned days.
        var inserted: [LectureSession] = []
        for slot in slotsByID.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            for day in plannedDays[slot.id] ?? [] where holder[Occurrence(slotID: slot.id, day: day)] == nil {
                let session = session(for: slot, on: day, semester: semester)
                inserted.append(session)
                final[session.id] = session
            }
        }

        // 6. Unplanned generated sessions: delete future ones nothing points to; keep the rest.
        var deleted: [LectureSession] = []
        for session in unplanned where session.editedAt == nil && session.startsAt > now && !filed.contains(session.id) {
            deleted.append(session)
            final[session.id] = nil
        }

        // 7. Numbers per course and kind.
        renumber(&final)

        let insertedIDs = Set(inserted.map(\.id))
        let updated = final.values
            .filter { !insertedIDs.contains($0.id) && original[$0.id] != $0 }
            .sorted(by: Self.timeOrder)
        return SessionPlan(
            inserted: inserted.compactMap { final[$0.id] }.sorted(by: Self.timeOrder),
            updated: updated,
            deleted: deleted.sorted(by: Self.timeOrder)
        )
    }

    /// Sessions with `number` recomputed: per course and kind, non-cancelled sessions in start
    /// order are 1…n, cancelled ones nil.
    public func renumbered(_ sessions: [LectureSession]) -> [LectureSession] {
        var byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        renumber(&byID)
        return sessions.compactMap { byID[$0.id] }
    }

    // MARK: - Helpers

    private struct Occurrence: Hashable {
        var slotID: WeeklySlot.ID
        var day: CalendarDay
    }

    private struct NumberGroup: Hashable {
        var courseID: Course.ID
        var kind: SessionKind
    }

    private func renumber(_ sessions: inout [LectureSession.ID: LectureSession]) {
        var groups: [NumberGroup: [LectureSession]] = [:]
        for session in sessions.values {
            if session.isCancelled {
                sessions[session.id]?.number = nil
            } else {
                groups[NumberGroup(courseID: session.courseID, kind: session.kind), default: []].append(session)
            }
        }
        for members in groups.values {
            for (index, session) in members.sorted(by: Self.timeOrder).enumerated() {
                sessions[session.id]?.number = index + 1
            }
        }
    }

    private func apply(_ slot: WeeklySlot, day: CalendarDay, zone: TimeZone, to session: inout LectureSession) {
        let starts = day.date(minute: slot.startMinute, in: zone)
        session.courseID = slot.courseID
        session.weeklySlotID = slot.id
        session.kind = slot.kind
        session.startsAt = starts
        session.endsAt = starts.addingTimeInterval(Double(max(0, slot.durationMinutes)) * 60)
        session.room = slot.room
    }

    private func zone(of slot: WeeklySlot, semester: Semester) -> TimeZone {
        TimeZone(identifier: slot.timeZone) ?? semester.zone
    }

    private static func offset(from weekday: Int, to target: Int) -> Int {
        ((target - weekday) % 7 + 7) % 7
    }

    static func timeOrder(_ lhs: LectureSession, _ rhs: LectureSession) -> Bool {
        if lhs.startsAt != rhs.startsAt { return lhs.startsAt < rhs.startsAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
