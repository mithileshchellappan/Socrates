import Foundation
import StudyCore

/// The deadline & exercise memory (PRD #37): workstream A fills this in (docs/plan-m3.md §3).
/// Logs through `Log.logger(category: "deadlines")`.
public enum DeadlinesModule {
    public static let moduleName = "Deadlines"

    /// The university's time zone: dates said or written are read in it.
    public static let timeZone = TimeZone(identifier: "Europe/Lisbon") ?? .current
}
