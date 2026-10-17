import StudyCore

/// Mirrors lecture sessions into the app-owned "Study Portal" calendar with EventKit (PRD #36).
/// The app writes only to its own calendar. Workstream A fills this in; see docs/plan-m1.md.
public enum CalendarSyncModule {
    public static let moduleName = "CalendarSync"
}
