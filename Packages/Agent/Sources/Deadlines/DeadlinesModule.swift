import Foundation
import os
import StudyCore

/// The deadline & exercise memory (PRD #37): `DeadlineMemory` (the one write path for tracked
/// items and their sources), `DateMentions` (the deterministic DE/EN date parser) and
/// `DeadlineParser` (the composer's local parse). Logs through `Log.logger(category: "deadlines")`.
public enum DeadlinesModule {
    public static let moduleName = "Deadlines"

    /// The university's time zone (the profile's, else the system's): dates said or written are
    /// read in it.
    public static var timeZone: TimeZone { UniversityProfile.current.zone }

    /// Never log titles, quotes, mail or transcript text at `.public` privacy.
    static let log = Log.logger(category: "deadlines")
}
