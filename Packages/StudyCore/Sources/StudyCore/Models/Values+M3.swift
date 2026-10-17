import Foundation
import SQLiteData

// Values added with schema v6 (milestone 3: deadlines, the agent tool runtime, Today, Calendar).

// MARK: - Agent conversations

/// What a Claude conversation is for. Each kind has ONE fixed tool set (defined next to the
/// runtime, package `Agent`), chosen when the conversation starts and never changed: changing
/// tools mid-conversation breaks the prompt cache and preserved thinking.
public struct ConversationKind: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// What the student tells the agent in Calendar's "New deadline" composer: the agent keeps
    /// the deadline & exercise memory (#37) with its deadline tools. No mail, web or file content
    /// enters it, so it may write deadlines (added on their own, with Undo); other changes are
    /// staged proposals.
    public static let deadlines: Self = "deadlines"
}

/// Where a conversation is.
public enum ConversationState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// The agent is working (a turn streams or tools run); the composer's dashed preview stays.
    case running
    /// The agent ended its turn.
    case finished
    /// It stopped with an error (`error`), was refused, or the app quit while it ran.
    case failed
}

/// Who wrote a stored turn. Tool results travel in `user` turns, as the Messages API wants.
public enum AgentRole: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    case user
    case assistant
}

// MARK: - Extraction

/// Where a source is in an extraction pass (transcripts in M3; mail keeps `MailExtractionState`).
public enum ExtractionState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Waits for a pass (also while there is no API key, or the cost guard pauses calls).
    case pending
    /// Nothing to read (no cue in the transcript): no call was made.
    case skipped
    /// Read (possibly nothing found).
    case done
    /// Gave up after the attempt limit.
    case failed
}

// MARK: - Tracked items

/// Why an item matters for the course, beyond its date (v6 `tracked_item.relevance`): Today's
/// amber star on the gloss line, Calendar's "Exam admission" chip.
public struct ItemRelevance: StringKind {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// Required for exam admission ("Teilnahme … Voraussetzung für die Prüfungszulassung").
    public static let examAdmission: Self = "exam_admission"
    /// Earns bonus points.
    public static let bonus: Self = "bonus"
}

/// The fields of a tracked item a source can change, as they were before it changed them
/// (v6 `tracked_item_source.previous`, JSON). Undo of that source puts them back; a source that
/// created its item has none (Undo dismisses the item instead).
public struct TrackedItemSnapshot: Hashable, Sendable, Codable {
    public var kind: TrackedItemKind
    public var title: String
    public var details: String
    public var courseID: Course.ID?
    public var dueAt: Date?
    public var isAllDay: Bool
    public var status: TrackedItemStatus
    public var inCalendar: Bool
    public var lectureSessionID: LectureSession.ID?
    public var room: String?
    public var relevance: ItemRelevance?

    public init(
        kind: TrackedItemKind,
        title: String,
        details: String = "",
        courseID: Course.ID? = nil,
        dueAt: Date? = nil,
        isAllDay: Bool = false,
        status: TrackedItemStatus = .open,
        inCalendar: Bool = false,
        lectureSessionID: LectureSession.ID? = nil,
        room: String? = nil,
        relevance: ItemRelevance? = nil
    ) {
        self.kind = kind
        self.title = title
        self.details = details
        self.courseID = courseID
        self.dueAt = dueAt
        self.isAllDay = isAllDay
        self.status = status
        self.inCalendar = inCalendar
        self.lectureSessionID = lectureSessionID
        self.room = room
        self.relevance = relevance
    }

    public init(_ item: TrackedItem) {
        self.init(
            kind: item.kind, title: item.title, details: item.details, courseID: item.courseID, dueAt: item.dueAt,
            isAllDay: item.isAllDay, status: item.status, inCalendar: item.inCalendar,
            lectureSessionID: item.lectureSessionID, room: item.room, relevance: item.relevance
        )
    }

    /// `item` with these fields put back (id, sources, calendar state and stamps kept).
    public func applied(to item: TrackedItem) -> TrackedItem {
        var restored = item
        restored.kind = kind
        restored.title = title
        restored.details = details
        restored.courseID = courseID
        restored.dueAt = dueAt
        restored.isAllDay = isAllDay
        restored.status = status
        restored.inCalendar = inCalendar
        restored.lectureSessionID = lectureSessionID
        restored.room = room
        restored.relevance = relevance
        return restored
    }
}

/// A tracked item before it is written: what the composer's local parse previews (dashed in the
/// Calendar grid), what an extractor or an agent tool hands to the deadline memory. Not a row.
public struct DeadlineDraft: Hashable, Sendable, Codable {
    public var kind: TrackedItemKind
    /// "Sheet 1 due", "Seminar registration": names the thing, primary text.
    public var title: String
    /// One short grey line about why it matters ("Weekly from then on"), or empty.
    public var details: String
    public var courseID: Course.ID?
    /// The due moment; for an all-day item the day's start in the university's time zone.
    public var dueAt: Date?
    public var isAllDay: Bool
    public var relevance: ItemRelevance?
    /// Where an exam or event takes place; the new room of a room change.
    public var room: String?
    /// The session it is tied to (an event that is a session, a room change's session).
    public var lectureSessionID: LectureSession.ID?

    public init(
        kind: TrackedItemKind = .deadline,
        title: String,
        details: String = "",
        courseID: Course.ID? = nil,
        dueAt: Date? = nil,
        isAllDay: Bool = false,
        relevance: ItemRelevance? = nil,
        room: String? = nil,
        lectureSessionID: LectureSession.ID? = nil
    ) {
        self.kind = kind
        self.title = title
        self.details = details
        self.courseID = courseID
        self.dueAt = dueAt
        self.isAllDay = isAllDay
        self.relevance = relevance
        self.room = room
        self.lectureSessionID = lectureSessionID
    }
}

/// What ↩ in the composer did (`DeadlineActions.submit`). The field clears unless the text was
/// not understood.
public enum DeadlineSubmission: Hashable, Sendable {
    /// Added (or merged into) this item at once: the local parse, without an API key.
    case added(TrackedItem.ID)
    /// Handed to the agent (`ConversationKind.deadlines`); what it writes lands in the rows. The
    /// composer keeps its dashed preview while this conversation is `running`.
    case agent(AgentConversation.ID)
    /// Nothing to add (no date found and no agent): the text stays in the field.
    case notUnderstood
}

extension TrackedItemKind {
    /// Something due: listed in Calendar's "Deadlines" inspector and drawn as a due line, tag or
    /// all-day pill; on Today with the open ring (`DueRing`).
    public var isDue: Bool { self == .deadline || self == .exercise || self == .exam }
}
