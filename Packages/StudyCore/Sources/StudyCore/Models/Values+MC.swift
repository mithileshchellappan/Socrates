import Foundation
import SQLiteData

// Values added with schema v12 (milestone mc: the study coach). docs/plan-coach.md §3–4,
// docs/schema.md.

// MARK: - The plan

/// What a plan block asks the student to do (`study_block.kind`). docs/research/study-coach.md §6.2.
public struct StudyBlockKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Review a lecture: Start opens it at the first slide not yet reviewed (`first_page`).
    public static let review: Self = "review"
    /// A round of questions (due and missed first, then new), across one or more courses.
    public static let round: Self = "round"
    /// An exercise sheet or an exam-admission item (`tracked_item_id`, maybe `url`).
    public static let exercise: Self = "exercise"
    /// One section of a book or paper (`reading_id`), ending in 2–3 recall questions.
    public static let read: Self = "read"
    /// A timed practice exam in the exam's form (runway only).
    public static let practiceExam: Self = "practice_exam"
    /// The next seminar milestone (read the paper, design, slides, rehearsal, paper draft).
    public static let seminarStep: Self = "seminar_step"
}

/// Where a plan block is (`study_block.state`).
public enum StudyBlockState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case planned
    /// Start was pressed (a round's session exists, the lecture was opened).
    case started
    case done
    /// The student skipped it (through the agent) or the day passed without it.
    case skipped

    /// Planned or started: the hero picks the first of these.
    public var isOpen: Bool { self == .planned || self == .started }
}

// MARK: - Questions

/// How a question is answered (`study_question.format`).
public struct StudyQuestionFormat: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Four options, one right (`choices`, `correct_choice`); graded in code.
    public static let choice: Self = "choice"
    /// A few words or a sentence; graded by Claude against `model_answer`.
    public static let short: Self = "short"
    /// A "why" or an explanation; graded by Claude.
    public static let explain: Self = "explain"
    /// A calculation with its working; graded by Claude.
    public static let calculation: Self = "calculation"
    /// A diagram to label (`diagram`); graded in code (one point per box).
    public static let label: Self = "label"

    /// Answered in writing and graded by Claude.
    public var isWritten: Bool { self == .short || self == .explain || self == .calculation }
}

/// Which draws a question (`study_question.pool`): rounds ask short retrieval questions; practice
/// exams ask the exam's forms with points (and may add `round` choices for 2 points).
public struct StudyQuestionPool: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let round: Self = "round"
    public static let exam: Self = "exam"
}

/// Where a question came from (`study_question.origin`).
public struct StudyQuestionOrigin: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Drafted by Haiku from the student's own lectures (M4 study pass outputs).
    public static let generated: Self = "generated"
    /// The examiner's own question from an old exam the student added (`source_title`); drawn with
    /// the amber quote bar; Claude wrote its model answer from the lectures.
    public static let oldExam: Self = "old_exam"
}

/// An FSRS card's phase (`study_question.card_state`).
public enum StudyCardState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Never answered.
    case new
    /// Answered, not yet right once (successive relearning keeps it in the round).
    case learning
    case review
    /// Missed after it was known.
    case relearning
}

/// How an answer went (`study_answer.result`).
public enum StudyAnswerResult: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case correct
    case partial
    case wrong
    /// A written answer waiting for Claude's grade.
    case pending
}

/// Who graded an answer (`study_answer.graded_by`).
public enum StudyGrader: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// A choice or a label, in code.
    case code
    /// Claude (Opus 5.5, effort medium).
    case model
    /// The student overrode it (Count as wrong, Change Points…).
    case user
}

/// Whether a written answer still waits for Claude (`study_answer.grading`).
public enum StudyGrading: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Nothing to grade by a model (choice, label).
    case none
    case pending
    case done
    /// Gave up after `StudyAnswer.maximumGradingAttempts`; the student can still grade it.
    case failed
}

/// What the student answered: stored in `study_answer.response` and an exam's drafts (JSON).
public enum StudyResponse: Hashable, Sendable, Codable {
    /// The picked option (0-based index into `choices`).
    case choice(Int)
    /// A written answer.
    case text(String)
    /// A label diagram: box id → the term placed on it.
    case labels([String: String])

    /// Nothing given yet (an empty text, no labels).
    public var isEmpty: Bool {
        switch self {
        case .choice: false
        case .text(let text): text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .labels(let labels): labels.isEmpty
        }
    }
}

/// An exam answer while it is being written (`study_session.drafts`).
public struct StudyDraft: Hashable, Sendable, Codable {
    public var questionID: StudyQuestion.ID
    public var response: StudyResponse

    public init(questionID: StudyQuestion.ID, response: StudyResponse) {
        self.questionID = questionID
        self.response = response
    }
}

/// A diagram to label (`study_question.diagram`, format `label`): stacks of boxes side by side,
/// each stack top to bottom; a blank box's text is hidden and placed from `terms` (its own text
/// plus distractors). Mockup 18's question 8: two stacks, "Virtual machines" and "Containers".
public struct LabelDiagram: Hashable, Sendable, Codable {
    public struct Box: Hashable, Sendable, Codable, Identifiable {
        /// Stable within the question ("s0r2b1"): the key of `StudyResponse.labels`.
        public var id: String
        public var text: String
        /// Hidden: the student places a term here.
        public var blank: Bool

        public init(id: String, text: String, blank: Bool = false) {
            self.id = id
            self.text = text
            self.blank = blank
        }
    }

    public struct Stack: Hashable, Sendable, Codable {
        /// The caption under the stack.
        public var title: String
        /// Rows top to bottom; a row's boxes sit side by side.
        public var rows: [[Box]]

        public init(title: String, rows: [[Box]]) {
            self.title = title
            self.rows = rows
        }
    }

    public var stacks: [Stack]
    /// The terms to place, in display order (the blanks' texts and distractors).
    public var terms: [String]

    public init(stacks: [Stack], terms: [String]) {
        self.stacks = stacks
        self.terms = terms
    }

    /// The boxes to fill.
    public var blanks: [Box] { stacks.flatMap { $0.rows.flatMap { $0 } }.filter(\.blank) }
}

// MARK: - Rounds and practice exams

/// A round of questions or a practice exam (`study_session.kind`).
public struct StudySessionKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let round: Self = "round"
    public static let exam: Self = "exam"
}

/// Where a round or exam is (`study_session.state`).
public enum StudySessionState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Running (an exam's clock runs from `resumed_at`).
    case active
    /// An exam paused (Pause, or the student left it); a round is never paused.
    case paused
    /// An exam handed in (results; grading may still stream in).
    case submitted
    /// A round ended (End, or its last question answered).
    case ended

    public var isOpen: Bool { self == .active || self == .paused }
}

/// What a round or a practice exam draws its questions from (`study_session.scope`, JSON; the
/// practice exam sheet's "Questions from").
public struct StudyScope: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// A plan block's round: due and missed questions of `courseIDs`, then new ones.
        public static let plan: Self = "plan"
        /// One course (Practice on Progress).
        public static let course: Self = "course"
        /// One topic (Practice This Topic): `topic`.
        public static let topic: Self = "topic"
        /// The misses of a practice exam (Review misses): `sessionID`.
        public static let misses: Self = "misses"
        /// A reading's recall questions (a Read block): `readingID`.
        public static let reading: Self = "reading"
        /// Practice exam: every taught topic of the course, weighted to the weak ones.
        public static let allLectures: Self = "all_lectures"
        /// Practice exam: the weakest topics.
        public static let weakest: Self = "weakest"
        /// Practice exam: one old exam's own questions (`oldExamTitle`).
        public static let oldExam: Self = "old_exam"
    }

    public var kind: Kind
    public var courseIDs: [Course.ID]
    public var topic: TopicKey?
    public var sessionID: StudySession.ID?
    public var readingID: StudyReading.ID?
    public var oldExamTitle: String?

    public init(
        kind: Kind,
        courseIDs: [Course.ID] = [],
        topic: TopicKey? = nil,
        sessionID: StudySession.ID? = nil,
        readingID: StudyReading.ID? = nil,
        oldExamTitle: String? = nil
    ) {
        self.kind = kind
        self.courseIDs = courseIDs
        self.topic = topic
        self.sessionID = sessionID
        self.readingID = readingID
        self.oldExamTitle = oldExamTitle
    }

    public static func course(_ id: Course.ID) -> StudyScope { StudyScope(kind: .course, courseIDs: [id]) }
}

/// Where Start takes the student (`StudyCoaching.start(block:)`); the screen maps it to a
/// destination.
public enum StudyStart: Hashable, Sendable {
    /// A round or exam session: the Practice screen.
    case session(StudySession.ID)
    /// A lecture's review at a slide and/or second.
    case lecture(Lecture.ID, page: Int?, time: Double?)
    /// An item (its source mail, else its course).
    case item(TrackedItem.ID)
    /// Outside the app (an LMS quiz, a reading's URL).
    case url(URL)
    /// The practice exam sheet of a course.
    case examSheet(Course.ID)
    /// Nothing to open (the block was only marked started).
    case none
}

/// What a round would ask (Progress's "12 questions · 10 min").
public struct StudyRoundPreview: Hashable, Sendable {
    public var questions: Int
    public var minutes: Int

    public init(questions: Int, minutes: Int) {
        self.questions = questions
        self.minutes = minutes
    }
}

/// What a practice exam would be (the sheet's "8 questions · 90 points").
public struct StudyExamPreview: Hashable, Sendable {
    public var questions: Int
    public var points: Int
    /// Nil: untimed.
    public var minutes: Int?

    public init(questions: Int, points: Int, minutes: Int?) {
        self.questions = questions
        self.points = points
        self.minutes = minutes
    }
}

// MARK: - Reading list

/// Why a reading is on a course's list (`study_reading.reason`). docs/research/study-coach.md §2.4.
public struct ReadingReason: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// The slides assume background the student may lack (CL slides 28–41): offered first.
    public static let gap: Self = "gap"
    /// The lecturer named it in class.
    public static let lecturer: Self = "lecturer"
    /// The module handbook lists it.
    public static let handbook: Self = "handbook"
    /// Optional depth (a verified further-reading source of the study pass).
    public static let depth: Self = "depth"
    /// The student added it (through the agent).
    public static let user: Self = "user"
}

// MARK: - Plan rules (situational choices, kept in agent memory)

/// A situational choice the student told the agent, which the planner follows
/// (`agent_memory.plan_rule`, JSON, on a memory of kind `plan`). PRD "Manage it through the agent,
/// not UI": no settings screen; forgetting the memory drops the rule.
public struct PlanRule: Hashable, Sendable, Codable {
    public struct Kind: StringKind {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// Away days (travel): `weekdays` every week and/or `first`…`last`; at most `minutes` a day
        /// (default `PlanRule.awayMinutes`), phone-sized blocks only.
        public static let away: Self = "away"
        /// No block of `blockKind` (or none at all) for `courseID` (or any course) on `first`…`last`
        /// ("skip CL exercise this Friday").
        public static let skip: Self = "skip"
        /// At most `minutes` of study a day (`weekdays` / `first`…`last` when given).
        public static let cap: Self = "cap"
        /// Which exam date of `courseID` the student sits: `sitting` 1 (first, the default) or 2.
        public static let sitting: Self = "sitting"
        /// Weekly hours for a seminar `courseID` (`enabled`); off by default (seminar steps only).
        public static let seminarHours: Self = "seminar_hours"
        /// The student does not attend `slotID` (every week) or `sessionID` (once): its time is
        /// free and its lecture is reviewed from the recording (`enabled` true: attends after all).
        public static let attend: Self = "attend"
    }

    public var kind: Kind
    /// ISO weekdays, 1 = Monday … 7 = Sunday.
    public var weekdays: [Int]?
    public var first: CalendarDay?
    public var last: CalendarDay?
    public var minutes: Int?
    public var courseID: Course.ID?
    public var blockKind: StudyBlockKind?
    public var sitting: Int?
    public var enabled: Bool?
    public var slotID: WeeklySlot.ID?
    public var sessionID: LectureSession.ID?

    public init(
        kind: Kind,
        weekdays: [Int]? = nil,
        first: CalendarDay? = nil,
        last: CalendarDay? = nil,
        minutes: Int? = nil,
        courseID: Course.ID? = nil,
        blockKind: StudyBlockKind? = nil,
        sitting: Int? = nil,
        enabled: Bool? = nil,
        slotID: WeeklySlot.ID? = nil,
        sessionID: LectureSession.ID? = nil
    ) {
        self.kind = kind
        self.weekdays = weekdays
        self.first = first
        self.last = last
        self.minutes = minutes
        self.courseID = courseID
        self.blockKind = blockKind
        self.sitting = sitting
        self.enabled = enabled
        self.slotID = slotID
        self.sessionID = sessionID
    }

    /// An away day's cap when the rule names none (research §6.4: "about 30 min").
    public static let awayMinutes = 30

    /// True when the rule speaks for `day` (its weekdays and/or its range; neither: every day).
    public func applies(to day: CalendarDay) -> Bool {
        if let first, day < first { return false }
        if let last, day > last { return false }
        if let weekdays, !weekdays.isEmpty { return weekdays.contains(day.weekday) }
        return true
    }

    /// A one-off rule whose last day is before `day` (the planner forgets it).
    public func hasExpired(before day: CalendarDay) -> Bool {
        guard let last else { return false }
        return last < day
    }
}

// MARK: - Exam form (a course fact)

/// The exam's form once announced (`CourseRule.examForm` of an `exam_form` rule): the practice
/// exam copies it (format consistency, research §3).
public struct ExamForm: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let written: Self = "written"
    public static let oral: Self = "oral"
    /// A seminar: talk + written paper (no exam date; seminar steps).
    public static let seminar: Self = "seminar"
}

// MARK: - New values of existing columns

extension AgentTaskKind {
    /// Draft a lecture's questions and readings (Haiku 5.5, batched, `study_unit` stage `quiz`):
    /// run in code by the task queue (`Coach.QuestionDrafter`), like `study_pass`.
    public static let questionDraft: Self = "question_draft"
}

extension AgentToolGroup {
    /// plan_query (the plan, budgets, readiness); the plan's writes are the app agent's own tools.
    public static let plan: Self = "plan"
}

extension AgentChangeKind {
    /// A course's credits or self-study hours set (`set_course_credits`).
    public static let courseCredits: Self = "course_credits"
}

extension AgentMemoryKind {
    /// A situational choice for the planner (away days, skips, caps, which date to sit, seminar
    /// hours, classes not attended): `plan_rule` holds it typed.
    public static let plan: Self = "plan"
}

extension StudyStage {
    /// The coach's drafting of a lecture's questions and readings (Haiku), one unit per topic
    /// group ("t1-4"). The study pass plans, runs and resets only its own three stages.
    public static let quiz: Self = "quiz"
}

extension ItemRelevance {
    /// An exam registration window (from the university profile): reminded the day before it closes.
    public static let registration: Self = "registration"
}

extension SourceRef.Kind {
    /// The university profile (`UniversityProfile`): a registration window, an exam period.
    public static let profile: Self = "profile"
}

extension AgentContext.Screen {
    /// The Study screen (the coach across courses). A course's Progress is `.course` with
    /// `courseScreen` "progress".
    public static let study: Self = "study"
}
