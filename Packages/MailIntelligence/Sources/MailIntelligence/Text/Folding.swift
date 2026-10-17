import Deadlines
import Foundation

// The folding helpers and the date parser moved to `Deadlines` in M3 (the deadline memory matches
// titles and verifies dates for every source); MailIntelligence keeps its names for them.

/// Case-, diacritic- and typography-insensitive text comparisons (`Deadlines.TextFolding`).
typealias Folding = TextFolding

/// The DE/EN date parser extraction verifies quotes with.
public typealias DateMentions = Deadlines.DateMentions
