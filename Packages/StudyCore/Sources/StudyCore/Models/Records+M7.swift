import Foundation
import SQLiteData

// Record types added in schema v13 (M7: the iPhone). docs/plan-m7.md §3–4, docs/schema.md.

// MARK: - The phone's questions to the agent

/// Where a question from another device is (`agent_request.state`).
public enum AgentRequestState: String, Hashable, Sendable, Codable, CaseIterable, QueryBindable {
    /// Written on the phone; waits for the Mac (it arrives through iCloud sync).
    case pending
    /// The Mac's agent is answering it.
    case running
    /// Answered: the answer is the conversation's next assistant turn.
    case answered
    /// The Mac could not answer it (`error` says why, readable, no secrets).
    case failed
}

/// A question the student asked the agent on the iPhone (the agent sheet, agent panel mockup §7).
/// AI runs on the Mac only (PRD), so the phone writes this row and the Mac's app agent answers it
/// through the same `app` conversation (`AppAgent.send`), once iCloud sync carries it over; the
/// answer comes back as that conversation's turns. The phone shows the student's bubble with a
/// skeleton line until then.
@Table("agent_request")
public struct AgentRequest: StudyRecord {
    public let id: UUID
    /// The `app` conversation it continues; nil: a new conversation (the Mac sets it when it
    /// answers). CASCADE: a deleted conversation takes its requests.
    @Column("conversation_id") public var conversationID: AgentConversation.ID?
    /// The student's words (may be empty when files go alone).
    public var text: String
    /// What the phone showed when the student sent it (the screen, the course, the plan's day).
    @Column(as: AgentContext?.JSONRepresentation.self) public var context: AgentContext?
    /// The device it was asked on (`AgentRequest.iPhone`); the Mac answers only other devices'.
    public var device: String
    public var state: AgentRequestState
    /// Why the Mac could not answer it.
    public var error: String?
    /// When the Mac's answer started and finished.
    @Column("started_at") public var startedAt: Date?
    @Column("answered_at") public var answeredAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    /// `device` of a question asked on the iPhone.
    public static let iPhone = "iphone"
    /// `device` of the Mac (never written by the Mac's own panel, which sends directly).
    public static let mac = "mac"

    public init(
        id: UUID = UUID(),
        conversationID: AgentConversation.ID? = nil,
        text: String,
        context: AgentContext? = nil,
        device: String = AgentRequest.iPhone,
        state: AgentRequestState = .pending,
        error: String? = nil,
        startedAt: Date? = nil,
        answeredAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.conversationID = conversationID
        self.text = text
        self.context = context
        self.device = device
        self.state = state
        self.error = error
        self.startedAt = startedAt
        self.answeredAt = answeredAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A file sent with a question from the phone (the sheet's paperclip: Photo Library, Take Photo,
/// Choose File…; the kinds and limits of `AgentAttachment`). The bytes live in the row, because
/// the BlobStore does not sync (M7) and CloudKit syncs a BLOB column as an asset; the Mac puts
/// them into its BlobStore (`AgentAttachment.make`) when it answers.
@Table("agent_request_file")
public struct AgentRequestFile: StudyRecord {
    public let id: UUID
    /// CASCADE: the files go with their request.
    @Column("request_id") public var requestID: AgentRequest.ID
    /// The student's order (0-based).
    @Column("sort_order") public var sortOrder: Int
    /// The name the student saw ("IMG_0412.jpeg", "Uebung01.pdf").
    @Column("file_name") public var fileName: String
    /// The uniform type identifier ("public.jpeg", "com.adobe.pdf").
    @Column("content_type") public var contentType: String
    @Column("byte_count") public var byteCount: Int
    public var data: Data
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        requestID: AgentRequest.ID,
        sortOrder: Int,
        fileName: String,
        contentType: String,
        data: Data,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.requestID = requestID
        self.sortOrder = sortOrder
        self.fileName = fileName
        self.contentType = contentType
        self.byteCount = data.count
        self.data = data
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
