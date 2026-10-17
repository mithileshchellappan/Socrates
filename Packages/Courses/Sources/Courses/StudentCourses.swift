import Foundation
import StudyCore

/// Example courses of WS 2026/27 (an invented demo world), created on the first launch of an empty
/// library (`CourseLibrary.seedIfEmpty`). All three lecturers approved recording (consent dated
/// 5 Oct 2026, lecturer only). Weekly slots are left out: the student enters them in Course
/// Settings.
public enum StudentCourses {
    /// The day the lecturers' approval was recorded.
    public static let consentDay = CalendarDay(year: 2026, month: 10, day: 5)

    public static let winter2026: [CourseDraft] = [
        CourseDraft(
            name: "Data Centers", lecturers: "Prof. Dr. Ada Example", language: "en", adminLanguage: "en",
            semesterID: Semester.winter2026ID, records: true,
            rules: [
                CourseRule(kind: .examAdmission, title: "Exam admission", text: "Take part in the online quizzes.", provenance: .professor),
                CourseRule(kind: .bonus, title: "Bonus points", text: "Present solutions in the exercise session.", provenance: .professor),
                CourseRule(kind: .examForm, title: "Exam form"),
            ]
        ),
        CourseDraft(
            name: "Computational Linguistics", lecturers: "Prof. Dr. Bo Sample", language: "en", adminLanguage: "en",
            semesterID: Semester.winter2026ID, records: true
        ),
        CourseDraft(
            name: "Sensor Networks", lecturers: "Dr. Cy Demo", language: "en", adminLanguage: "en",
            semesterID: Semester.winter2026ID, records: true
        ),
    ]

    /// Creates the three courses when the library has none. Returns what was created.
    @discardableResult
    public static func seedIfEmpty(services: StudyServices, now: Date = Date()) async throws -> [Course] {
        let zone = Semester.winter2026.zone
        return try await CourseLibrary(services: services)
            .seedIfEmpty(winter2026, consentAt: consentDay.start(in: zone), now: now)
    }
}
