import StudyCore
import SwiftUI

// The study coach's hooks for screens (mc, docs/plan-coach.md §3): the engine (`\.studyCoach`) and
// how durations read ("5 h 15 min"). Today (CoursesUI) and the coach's screens (CoachUI) use them
// without depending on the engine's package.

extension EnvironmentValues {
    /// The coach's engine (`Coach.CoachEngine`), installed by the app on the Mac. Nil (iOS until
    /// M7, previews, renders without it): screens read rows only and offer no action that needs it.
    @Entry public var studyCoach: (any StudyCoaching)?
}

/// Durations as the coach writes them: "20 min", "1 h 30 min", "5 h", "6 h 10 min" (research
/// mockups: digits in SF Mono, units in the text font).
public enum DurationText {
    /// Whole minutes of `seconds`, rounded to `step` minutes (≥ 1; the budget's shares use 5).
    public static func minutes(_ seconds: Double, step: Int = 1) -> Int {
        let step = max(1, step)
        let minutes = max(0, seconds / 60)
        return Int((minutes / Double(step)).rounded()) * step
    }

    /// "1 h 30 min" as plain text.
    public static func string(minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        switch (hours, rest) {
        case (0, _): return String(localized: "\(rest) min")
        case (_, 0): return String(localized: "\(hours) h")
        default: return String(localized: "\(hours) h \(rest) min")
        }
    }

    /// "1 h 30 min" with the digits in SF Mono.
    public static func text(minutes: Int) -> Text {
        let hours = minutes / 60
        let rest = minutes % 60
        let h = Text(verbatim: "\(hours)").monospaced()
        let m = Text(verbatim: "\(rest)").monospaced()
        switch (hours, rest) {
        case (0, _): return Text("\(m) min")
        case (_, 0): return Text("\(h) h")
        default: return Text("\(h) h \(m) min")
        }
    }

    /// `seconds` rounded to `step` minutes, digits in SF Mono.
    public static func text(seconds: Double, step: Int = 1) -> Text {
        text(minutes: minutes(seconds, step: step))
    }
}
