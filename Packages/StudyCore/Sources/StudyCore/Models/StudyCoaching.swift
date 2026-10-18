import Foundation

/// The study coach's engine as the screens use it (docs/plan-coach.md §3): workstream A's
/// `Coach.CoachEngine` implements it; the app installs it in `\.studyCoach` (StudyUI). Screens read
/// every row themselves (`@Fetch`) and write an exam's drafts, flags, position and pause through
/// `StudySessionRepository`; everything that grades, schedules, assembles or plans goes through
/// here. Nil (iOS until M7, previews): the screens show the rows and offer no action that needs it.
///
/// Nothing here waits for a model: choices and labels are graded in code at once; a written
/// answer is recorded `pending` and graded in the background (the row updates when it is).
public protocol StudyCoaching: Sendable {
    /// Start pressed on a plan block (Today's hero, Study's current block): marks it started and
    /// says where it opens: a round's new session, a lecture at the block's first slide, the item,
    /// a URL (an LMS quiz, a reading), the practice exam sheet.
    func start(block: StudyBlock.ID) async throws -> StudyStart

    /// What a round of `scope` would ask (Progress's "12 questions · 10 min").
    func previewRound(_ scope: StudyScope) async throws -> StudyRoundPreview

    /// A round outside the plan: Practice (a course), Practice This Topic, Review misses (an exam's).
    func startRound(_ scope: StudyScope) async throws -> StudySession.ID

    /// Records the answer to the session's current question and updates its card: a choice or
    /// label is graded at once; a written answer is `pending` until Claude grades it. A miss of a
    /// new or learning question is asked again later in the same round. `seconds`: time on it.
    @discardableResult
    func answer(_ response: StudyResponse, to question: StudyQuestion.ID, in session: StudySession.ID, seconds: Double) async throws -> StudyAnswer

    /// The student's grade wins: Count as wrong (score 0) in a round, Change Points… on a
    /// practice exam's results (`score` = points / the question's points). The card follows.
    func override(_ answer: StudyAnswer.ID, score: Double) async throws

    /// Ends a round (End, or after its last question); its plan block is done.
    func end(_ session: StudySession.ID) async throws

    /// What a practice exam of `source` would be (the sheet's "8 questions · 90 points").
    /// `minutes` nil: untimed.
    func previewExam(course: Course.ID, source: StudyScope, minutes: Int?) async throws -> StudyExamPreview

    /// Assembles a practice exam (code, no model) and starts its clock.
    func startExam(course: Course.ID, source: StudyScope, minutes: Int?) async throws -> StudySession.ID

    /// Hands an exam in (Submit, or its clock at 0:00): its drafts become answers, choices and
    /// labels are graded at once, written ones in one background call.
    func submitExam(_ session: StudySession.ID) async throws

    /// A new exam with the same settings (other questions first).
    func retake(_ session: StudySession.ID) async throws -> StudySession.ID

    /// Add Old Exam… (or a PDF dropped on the sheet): stores the file and queues reading its
    /// questions and writing model answers (Opus, background); its questions appear in the
    /// sheet's menu under its title when they are ready.
    func addOldExam(course: Course.ID, file: URL) async throws
}
