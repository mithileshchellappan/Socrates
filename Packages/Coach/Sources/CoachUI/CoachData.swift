import Foundation
import StudyCore
import StudyUI

// The rows the coach's overviews read (Study and a course's Progress) and the measures over them.
// Rows come in one transaction (`FetchKeyRequest`); measures are computed for the moment on
// screen with StudyCore's `CoachMeasures` only, so Today, Study, Progress, the plan and the agent
// never disagree.

/// What one course's measures need.
struct CourseRows: Hashable, Sendable {
    var course: Course
    var lectures: [Lecture] = []
    /// The study pass's topic rows (`annotation` ai · topic, not hidden) of its lectures.
    var topics: [Annotation] = []
    /// Its questions that are not retired.
    var questions: [StudyQuestion] = []
    /// Its exam items, and its open due items from the start of the day (a seminar's gate).
    var exams: [TrackedItem] = []
    var dueItems: [TrackedItem] = []
    /// Its class sessions (the budget subtracts class hours when no self-study figure is known).
    var sessions: [LectureSession] = []
}

/// A course's measures at a moment.
struct CourseMeasures {
    let rows: CourseRows
    let exams: CourseExams
    let budget: StudyBudget?
    /// Mastery per topic key (`TopicMastery.byTopic`).
    let mastery: [TopicKey: TopicMastery]
    /// The share of taught topics known solidly; nil before anything was taught.
    let ready: Double?
    /// A seminar (exam form `seminar`, or no exam item): no Ready, no weekly share unless the
    /// student asked for seminar hours.
    let isSeminar: Bool
    let plansHours: Bool
    /// Its next open due item that is not an exam (a seminar's gate: "Survey Mon 26 Oct, 12:00").
    let nextDue: TrackedItem?

    init(rows: CourseRows, semester: Semester?, rules: PlanRules, now: Date) {
        self.rows = rows
        let exams = CourseExams.resolve(courseID: rows.course.id, items: rows.exams, rules: rules)
        self.exams = exams
        let timeZone = semester.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        let examDay = exams.sat?.dueAt.map { CalendarDay($0, in: timeZone) }
        budget = semester.map {
            StudyBudget.make(course: rows.course, semester: $0, sessions: rows.sessions, examDay: examDay)
        }
        mastery = TopicMastery.byTopic(rows.questions, at: now)
        let held = Set(rows.lectures.filter { $0.heldAt.map { $0 <= now } ?? true }.map(\.id))
        let taught = rows.topics.filter { $0.lectureID.map(held.contains) ?? false }.compactMap(TopicKey.init(topic:))
        ready = Readiness.share(taught: taught, mastery: mastery)
        let seminarForm = rows.course.rules.contains { $0.kind == .examForm && $0.examForm == .seminar }
        isSeminar = seminarForm || exams.first == nil
        plansHours = !isSeminar || rules.plansSeminarHours(rows.course.id)
        nextDue = rows.dueItems.first { item in
            guard let due = item.dueAt, item.kind.isDue, item.kind != .exam else { return false }
            return item.isAllDay ? due >= Calendar.current.startOfDay(for: now) : due >= now
        }
    }

    /// The topic's mastery (unseen when it has no answered question).
    func mastery(of topic: Annotation) -> TopicMastery {
        TopicKey(topic: topic).flatMap { mastery[$0] } ?? .unseen
    }

    /// Seen, not solid, and due again (recall under the desired retention): what needs practice now.
    func isDue(_ mastery: TopicMastery) -> Bool {
        mastery.seen && (mastery.recall ?? 1) < CoachRules.desiredRetention
    }
}

/// Shared reads.
enum CoachRows {
    /// The semester a course plans in (its own, else the one around `day`, else the newest).
    static func semester(for course: Course?, day: CalendarDay, in semesters: [Semester]) -> Semester? {
        if let id = course?.semesterID, let own = semesters.first(where: { $0.id == id }) { return own }
        return semesters.first { $0.contains(day) } ?? semesters.max { $0.lectureStart < $1.lectureStart }
    }

    /// The plan rules in effect (`plan` memories).
    static func rules(_ db: Database) throws -> PlanRules {
        let plan = AgentMemoryKind.plan
        let memories = try AgentMemory.where { $0.kind.eq(plan) && $0.forgottenAt.is(nil) }.fetchAll(db)
        return PlanRules(memories: memories)
    }

    /// One course's rows; due items from `from` (the start of the day on screen).
    static func course(_ course: Course, from: Date, _ db: Database) throws -> CourseRows {
        var rows = CourseRows(course: course)
        let courseID = course.id
        rows.lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let lectureIDs = rows.lectures.map { Lecture.ID?.some($0.id) }
        if !lectureIDs.isEmpty {
            rows.topics = try Annotation
                .where { $0.lectureID.in(lectureIDs) && $0.kind.eq(AnnotationKind.topic) && $0.hiddenAt.is(nil) }
                .order { ($0.pageNumber, $0.startTime) }
                .fetchAll(db)
        }
        rows.questions = try StudyQuestion.where { $0.courseID.eq(courseID) && $0.retiredAt.is(nil) }.fetchAll(db)
        let course = Course.ID?.some(courseID)
        let exam = TrackedItemKind.exam
        rows.exams = try TrackedItem.where { $0.courseID.eq(course) && $0.kind.eq(exam) }.fetchAll(db)
        let open = TrackedItemStatus.open
        let start = Date?.some(from)
        rows.dueItems = try TrackedItem
            .where { $0.courseID.eq(course) && $0.status.eq(open) && $0.dueAt.gte(start) }
            .order(by: \.dueAt)
            .limit(12)
            .fetchAll(db)
        rows.sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
        return rows
    }
}
