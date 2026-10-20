import Foundation
import StudyCore

/// The weekly slot a course's one-off sessions suggest (a seminar entered session by session):
/// the most common kind, weekday, start and length among them, in `timeZone`. Ties go to the
/// earliest session. Nil without one-off sessions.
public enum SlotGuess {
    public static func slot(
        courseID: Course.ID,
        sessions: [LectureSession],
        timeZone: TimeZone = UniversityProfile.current.zone
    ) -> WeeklySlot? {
        struct Key: Hashable {
            var kind: SessionKind
            var weekday: Int
            var startMinute: Int
            var minutes: Int
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var counts: [Key: (count: Int, first: Date, room: String)] = [:]
        for session in sessions where session.courseID == courseID && session.weeklySlotID == nil && !session.isCancelled {
            let parts = calendar.dateComponents([.weekday, .hour, .minute], from: session.startsAt)
            guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { continue }
            let minutes = Int((session.endsAt.timeIntervalSince(session.startsAt) / 60).rounded())
            guard minutes > 0 else { continue }
            let key = Key(kind: session.kind, weekday: weekday == 1 ? 7 : weekday - 1, startMinute: hour * 60 + minute, minutes: minutes)
            if let entry = counts[key] {
                counts[key] = (entry.count + 1, min(entry.first, session.startsAt), entry.room.isEmpty ? session.room : entry.room)
            } else {
                counts[key] = (1, session.startsAt, session.room)
            }
        }
        guard let best = counts.max(by: { lhs, rhs in
            lhs.value.count == rhs.value.count ? lhs.value.first > rhs.value.first : lhs.value.count < rhs.value.count
        }) else { return nil }
        return WeeklySlot(
            courseID: courseID, kind: best.key.kind, weekday: best.key.weekday, startMinute: best.key.startMinute,
            durationMinutes: best.key.minutes, room: best.value.room, timeZone: timeZone.identifier
        )
    }
}
