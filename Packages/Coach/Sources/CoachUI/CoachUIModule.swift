import StudyCore
import StudyUI
import SwiftUI

/// The study coach's screens (docs/plan-coach.md §6, §5.2): `PlanHero` (Today and Study),
/// `StudyView`, `CourseProgressView`, `PracticeView`, `PracticeExamSheet`, `PracticeExamView`,
/// `PracticeExamResultsView`, `MasteryDots` and `PracticeCommands`. They read rows with `@Fetch`,
/// write a session's position, drafts, flags and pause through `StudySessionRepository`, and do
/// everything else through `\.studyCoach` (nil: the action is not offered, the rows still draw).
public enum CoachUIModule {
    public static let moduleName = "CoachUI"
}

enum CoachUILog {
    static let ui = Log.logger(category: "coach-ui")
}
