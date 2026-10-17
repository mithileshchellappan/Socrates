import CalendarSync
import Courses
import StudyCore
import StudyUI
import SwiftUI

extension EnvironmentValues {
    /// The calendar mirror the app installs; screens ask it to sync after they change sessions.
    @Entry public var calendarMirror: CalendarMirror?
}

/// File ▸ New Course… (⌥⌘N).
public struct CourseCommands: Commands {
    private let newCourse: () -> Void

    public init(newCourse: @escaping () -> Void) {
        self.newCourse = newCourse
    }

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Course…", action: newCourse)
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
    }
}

enum CoursesUILog {
    static let ui = Log.logger(category: "courses-ui")
}

/// Writes from the course screens: each runs the change in one transaction, then lets the
/// calendar catch up. Failures are logged; the screens observe the database and show what landed.
@MainActor
struct ScheduleActions {
    let services: StudyServices?
    let mirror: CalendarMirror?

    func run(_ label: String, syncCalendar: Bool = true, _ work: @escaping @Sendable (StudyServices) async throws -> Void) {
        guard let services else { return }
        let mirror = mirror
        Task {
            do {
                try await work(services)
                if syncCalendar { try await mirror?.sync() }
            } catch {
                CoursesUILog.ui.error("\(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func save(_ slot: WeeklySlot) {
        run("Saving a slot") { try await CourseSchedule(services: $0).save(slot) }
    }

    func deleteSlot(_ id: WeeklySlot.ID) {
        run("Deleting a slot") { try await CourseSchedule(services: $0).deleteSlot(id) }
    }

    func save(_ slots: [WeeklySlot]) {
        run("Importing slots") { try await CourseSchedule(services: $0).save(slots) }
    }

    func deleteSlots(_ ids: [WeeklySlot.ID]) {
        run("Removing imported slots") { try await CourseSchedule(services: $0).deleteSlots(ids) }
    }

    /// A slot made from one-off sessions, which become its sessions.
    func adopt(_ slot: WeeklySlot) {
        run("Saving a slot") { try await CourseSchedule(services: $0).saveAdoptingSessions(slot) }
    }

    func save(_ rule: MailRule) {
        run("Saving a mail rule", syncCalendar: false) { try await $0.records.save(rule) }
    }

    func delete(_ rule: MailRule) {
        run("Deleting a mail rule", syncCalendar: false) { try await $0.records.delete(MailRule.self, id: rule.id) }
    }

    func cancel(_ id: LectureSession.ID) {
        run("Cancelling a session") { try await CourseSchedule(services: $0).cancel(id) }
    }

    func restore(_ id: LectureSession.ID) {
        run("Restoring a session") { try await CourseSchedule(services: $0).restore(id) }
    }

    func save(_ course: Course) {
        run("Saving a course") { try await CourseLibrary(services: $0).save(course) }
    }

    func save(_ semester: Semester) {
        run("Saving the semester") { try await CourseSchedule(services: $0).save(semester) }
    }
}
