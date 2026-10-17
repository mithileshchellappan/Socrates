import Foundation
import os
import StudyCore

/// The deadline & exercise memory (PRD #37): `DeadlineMemory` (the one write path for tracked
/// items and their sources), `DateMentions` (the deterministic DE/EN date parser) and
/// `DeadlineParser` (the composer's local parse). Logs through `Log.logger(category: "deadlines")`.
public enum DeadlinesModule {
    public static let moduleName = "Deadlines"

    /// The university's time zone: dates said or written are read in it.
    public static let timeZone = TimeZone(identifier: "Europe/Lisbon") ?? .current

    /// Never log titles, quotes, mail or transcript text at `.public` privacy.
    static let log = Log.logger(category: "deadlines")
}
