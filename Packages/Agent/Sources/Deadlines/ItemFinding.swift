import Foundation
import StudyCore

/// Something a source says about a deadline, exercise, exam, event, room change, cancellation or
/// announcement, before the deadline memory matches and writes it. The caller has verified the
/// quote against its source (mail body, transcript lines, the student's words).
public struct ItemFinding: Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// A mail row and its Message-ID (survives a re-sync that recreates the row).
        case mail(MailMessage.ID, rfcMessageID: String)
        /// A moment of a lecture recording (seconds on its clock).
        case transcript(lectureID: Lecture.ID?, recordingID: Recording.ID, time: Double)
        /// What the student said: in an agent conversation, or (nil) the composer's local parse.
        case chat(AgentConversation.ID?)
    }

    public var draft: DeadlineDraft
    public var source: Source
    /// Exact; verified by the caller against its source.
    public var quote: String
    public var confidence: Double
    /// `DateMentions` found the due day (and the stated time) in the quote.
    public var dateVerified: Bool
    /// False: the source talked to the model (an injection attempt) → never added on its own.
    public var trusted: Bool
    public var createdBy: Author
    public var apiCallID: APICall.ID?
    /// The quote's mentions relative to when it was written or said (session proposals use its
    /// times and weeks); nil: the times are read from the quote.
    public var mentions: DateMentions?

    public init(
        draft: DeadlineDraft,
        source: Source,
        quote: String,
        confidence: Double = 1,
        dateVerified: Bool = false,
        trusted: Bool = true,
        createdBy: Author = .agent,
        apiCallID: APICall.ID? = nil,
        mentions: DateMentions? = nil
    ) {
        self.draft = draft
        self.source = source
        self.quote = quote
        self.confidence = confidence
        self.dateVerified = dateVerified
        self.trusted = trusted
        self.createdBy = createdBy
        self.apiCallID = apiCallID
        self.mentions = mentions
    }

    /// Goes into the app's calendar on its own (PRD trust rule): a due kind with a date the
    /// source's own words confirm, from a source that did not talk to the model.
    public var addsToCalendar: Bool {
        trusted && dateVerified && draft.kind.addsToCalendarAutomatically && draft.dueAt != nil
    }

    /// The student's own words (the composer, an agent conversation).
    var isChat: Bool {
        if case .chat = source { return true }
        return false
    }
}

/// What recording one finding wrote.
public struct RecordResult: Sendable, Hashable {
    /// The item the finding created or merged into.
    public var item: TrackedItem
    /// The new source row; nil when this very source already said it (same source and quote).
    public var source: TrackedItemSource?
    /// A new item (else a repeat of `item`).
    public var created: Bool

    public init(item: TrackedItem, source: TrackedItemSource?, created: Bool) {
        self.item = item
        self.source = source
        self.created = created
    }

    /// This finding put the item into the calendar.
    public var calendarAdded: Bool { source?.calendarAdded ?? false }
}
