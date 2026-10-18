import Foundation
import os
import StudyCore

/// The study coach's engine (docs/plan-coach.md §4, §5.1): workstream A builds `CoachEngine`
/// (`StudyCoaching`), `PlanEngine`, `Scheduler`, `RoundBuilder`, `PracticeExamBuilder`,
/// `QuestionDrafter`, `AnswerGrader`, `OldExamReader`, `ProfileItems` and `CoachCatalog` here.
public enum CoachModule {
    public static let moduleName = "Coach"
    static let log = Log.logger(category: "coach")

    /// `api_call.purpose` of the coach's calls (billing `subscription`).
    public enum Purpose {
        /// Haiku 5.5 drafts a lecture's questions and readings (`question_draft` tasks).
        public static let draft = "coach.draft"
        /// Opus 5.5, effort medium, grades written answers.
        public static let grade = "coach.grade"
        /// Opus 5.5, effort medium, reads an old exam and writes its model answers.
        public static let oldExam = "coach.old_exam"
    }
}
