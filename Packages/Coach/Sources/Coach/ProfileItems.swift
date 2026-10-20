import Foundation
import StudyCore

/// The university profile's own items (plan §4 "Profile items"): while the student has a course
/// with an exam, each registration window of the semester the profile knows becomes ONE "Register
/// for exams" deadline: no course, due the window's last day at 23:59, details "Exam office · 18–29 Jan",
/// relevance `registration`, source `profile` with the window's `rule` as the quote. The second
/// sitting's window only once the student sits a second date. AppAgent writes them through its
/// change log (listed, undoable; never twice: a window whose key has a change row is never added
/// again, even after Undo); ReminderCenter's registration reminder follows on its own.
public enum ProfileItems {
    public struct Item: Sendable, Hashable {
        /// The change log's source reference: "registration:WS 2026/27:1".
        public var key: String
        public var draft: DeadlineDraft
        /// The window's rule (the item's source quote).
        public var quote: String
    }

    /// The items the profile asks for now.
    public static func wanted(_ rows: CoachRows) -> [Item] {
        let statuses = rows.statuses
        guard statuses.contains(where: { !$0.isSeminar && $0.exams.first != nil }) else { return [] }
        guard let term = rows.profile.term(named: rows.semester.name) else { return [] }
        let secondDate = statuses.contains { $0.exams.sitting == 2 }
        let zone = rows.timeZone
        return term.registrations.compactMap { window in
            guard window.sitting == 1 || secondDate, window.last >= rows.today else { return nil }
            let due = window.last.date(minute: 23 * 60 + 59, in: zone)
            let draft = DeadlineDraft(
                kind: .deadline, title: "Register for exams", details: "\(window.system) · \(CoachText.range(window.first, window.last))",
                dueAt: due, isAllDay: false, relevance: .registration
            )
            return Item(key: "registration:\(term.name):\(window.sitting)", draft: draft, quote: window.rule)
        }
    }

    /// Reads the rows and returns the wanted items.
    public static func wanted(db: Database, now: Date) throws -> [Item] {
        wanted(try CoachRows.load(db, now: now))
    }
}
