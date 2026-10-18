import Foundation
import SQLiteData

// Record types added in schema v6 (milestone 3): agent conversations and their append-only turns,
// and the transcript extraction state per recording.

// MARK: - Agent conversations

/// One Claude conversation of a fixed kind (`ConversationKind` → one tool set). Its turns are
/// `AgentTurn` rows, appended and never edited.
@Table("agent_conversation")
public struct AgentConversation: StudyRecord {
    public let id: UUID
    public var kind: ConversationKind
    /// The course it is about, when one is known.
    @Column("course_id") public var courseID: Course.ID?
    /// v9 (M5): the lecture a `tutor` conversation is about (Review's Tutor tab); nil for a course's
    /// tutor (`course_id` set) and Search's (both nil). See `ChatSubject`.
    @Column("lecture_id") public var lectureID: Lecture.ID?
    /// A short label for logs and lists (the student's first words); never shown as copy.
    public var title: String
    /// `claude-haiku-5-5`, `claude-opus-5-5`: the model the conversation runs on.
    public var model: String
    public var state: ConversationState
    /// Why it failed (readable, no secrets).
    public var error: String?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: ConversationKind,
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        title: String = "",
        model: String = "",
        state: ConversationState = .running,
        error: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.courseID = courseID
        self.lectureID = lectureID
        self.title = title
        self.model = model
        self.state = state
        self.error = error
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// One turn of a conversation, stored exactly as sent or received: `message` is the Messages API
/// turn as JSON (`role`, every content block verbatim — thinking blocks and signatures,
/// tool_use, tool_result — so the history can be sent again byte for byte). Append-only:
/// `ConversationRepository.append` is the only writer; nothing updates or deletes a turn (the
/// conversation's deletion cascades).
@Table("agent_turn")
public struct AgentTurn: StudyRecord {
    public let id: UUID
    @Column("conversation_id") public var conversationID: AgentConversation.ID
    /// 0, 1, 2, … in the conversation (assigned by `append`).
    public var sequence: Int
    public var role: AgentRole
    /// The turn's JSON (ClaudeKit `MessageParam.json`, serialized with sorted keys).
    public var message: String
    /// The assistant turn's stop reason (`end_turn`, `tool_use`, …); nil for user turns.
    @Column("stop_reason") public var stopReason: String?
    /// The call that produced an assistant turn.
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: AgentConversation.ID,
        sequence: Int = 0,
        role: AgentRole,
        message: String,
        stopReason: String? = nil,
        apiCallID: APICall.ID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.sequence = sequence
        self.role = role
        self.message = message
        self.stopReason = stopReason
        self.apiCallID = apiCallID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Transcript extraction

/// Whether a recording's transcript has been read for deadlines and announcements said in class
/// (#32). One row per recording, written only by the transcript item pipeline (package `Agent`),
/// so the busy `recording` row is never touched for it.
@Table("transcript_extraction")
public struct TranscriptExtraction: StudyRecord {
    public let id: UUID
    @Column("recording_id") public var recordingID: Recording.ID
    public var state: ExtractionState
    /// Failed attempts so far (service trouble — no key, rate limits — does not count).
    public var attempts: Int
    /// The newest `transcript_segment.updated_at` the pass read: a transcript replaced later
    /// (re-transcription, correction) is read again.
    @Column("source_updated_at") public var sourceUpdatedAt: Date?
    @Column("extracted_at") public var extractedAt: Date?
    public var error: String?
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        recordingID: Recording.ID,
        state: ExtractionState = .pending,
        attempts: Int = 0,
        sourceUpdatedAt: Date? = nil,
        extractedAt: Date? = nil,
        error: String? = nil,
        apiCallID: APICall.ID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.recordingID = recordingID
        self.state = state
        self.attempts = attempts
        self.sourceUpdatedAt = sourceUpdatedAt
        self.extractedAt = extractedAt
        self.error = error
        self.apiCallID = apiCallID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// After this many failed attempts a transcript is not read again until it changes.
    public static let maximumAttempts = 3
}
