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
/// Whether a class has happened yet goes by the latest one; the student's words are read against
/// the block of their own turn, which also says when they were asked when that was earlier (a
/// question from the iPhone the Mac picked up later, a sub-agent task that waited in the queue):
///
///     <now>Fri 23 Oct 2026, 07:00 · Example City (Europe/Lisbon); asked Thu 22 Oct 2026, 23:30</now>
///
/// Try again restates when the words were written in its `<retry>` block. Readers of the
/// student's words skip the clock (`isClock`).
public enum AgentClock {
    /// "Thu 22 Oct 2026, 23:30 · Example City (Europe/Lisbon)" in the university's time zone.
    public static func text(_ date: Date) -> String {
        "\(AgentDates.spoken(date)) · \(UniversityProfile.current.place)"
    }

    /// Words asked this long before the turn is written say so in its block.
    static let askedEarlier: TimeInterval = 5 * 60

    /// The `<now>` block of a user turn written at `date` with words the student wrote at
    /// `writtenAt` (nil or within a few minutes: then).
    public static func block(_ date: Date, writtenAt: Date? = nil) -> ContentBlock {
        var line = text(date)
        if let writtenAt, date.timeIntervalSince(writtenAt) > askedEarlier { line += "; asked \(AgentDates.spoken(writtenAt))" }
        return .text(TextBlock(text: ClaudeCodeConfiguration.clockTag + line + "</now>"))
    }

    /// Whether a text block is a clock block.
    public static func isClock(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(ClaudeCodeConfiguration.clockTag)
    }

    /// The system prompt's sentences about time: when the conversation started, that the student's
    /// words go by the `<now>` block of their own turn, and that the latest one is the time now.
    public static func promptLine(startedAt: Date) -> String {
        """
        This conversation started \(AgentDates.spoken(startedAt)) in \(UniversityProfile.current.place). Every user turn \
        carries a <now> block, when it was written. Read the student's words against the <now> block of their own \
        message, or its "asked" time when it has one ("today" in words written Thu 22 Oct at 23:30 is Thu 22 Oct, \
        even when you answer later); a <retry> block says when the words it restates were written. The latest \
        <now> block is the time now: whether a class has happened yet, and what is still ahead, go by it.
        """
    }
}
