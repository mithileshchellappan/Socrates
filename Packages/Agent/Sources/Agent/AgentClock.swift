import ClaudeKit
import Foundation
import StudyCore

/// The current time as the agent learns it (2026-10-23). A conversation's system prompt is fixed
/// when it starts and re-sent unchanged on every resume (the CLI's prompt cache needs that), so it
/// states only when the conversation started. Every user turn the runtime writes carries the
/// clock instead, as its last block before the student's words:
///
///     <now>Thu 22 Oct 2026, 23:30 · Example City (Europe/Lisbon)</now>
///
/// "Today", "tonight", whether a class has happened yet and every date the agent writes go by the
/// latest one. Readers of the student's words skip it (`isClock`).
public enum AgentClock {
    /// "Thu 22 Oct 2026, 23:30 · Example City (Europe/Lisbon)" in the university's time zone.
    public static func text(_ date: Date) -> String {
        "\(AgentDates.spoken(date)) · \(UniversityProfile.current.place)"
    }

    /// The `<now>` block of a user turn written at `date`.
    public static func block(_ date: Date) -> ContentBlock {
        .text(TextBlock(text: ClaudeCodeConfiguration.clockTag + text(date) + "</now>"))
    }

    /// Whether a text block is a clock block.
    public static func isClock(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(ClaudeCodeConfiguration.clockTag)
    }

    /// The system prompt's sentence about time: when the conversation started, and that the
    /// latest `<now>` block is the time now.
    public static func promptLine(startedAt: Date) -> String {
        """
        This conversation started \(AgentDates.spoken(startedAt)) in \(UniversityProfile.current.place). The current date \
        and time are in the latest <now> block: "today", "tonight", "tomorrow", whether a class has happened yet, and \
        every date you write go by it.
        """
    }
}
