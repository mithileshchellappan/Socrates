import StudyCore

/// Course setup and session planning (PRD #1, #36): weekly slots × the semester's lecture days →
/// `lecture_session` rows, numbered per kind, never touching sessions the user edited.
/// Workstream A fills this in; see docs/plan-m1.md.
public enum CoursesModule {
    public static let moduleName = "Courses"
}
