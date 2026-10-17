import StudyCore
import os

/// Lecture review without UI: the player (one clock over a recording's segment files), the
/// slide ↔ time timeline, follow-playback, per-slide notes, manual anchors and review state
/// (PRD #9, #14, #15). See docs/plan-m1.md §5 and Packages/Review/README.md.
public enum ReviewModule {
    public static let moduleName = "Review"
}

enum ReviewLog {
    static let logger = Log.logger(category: "review")
}
