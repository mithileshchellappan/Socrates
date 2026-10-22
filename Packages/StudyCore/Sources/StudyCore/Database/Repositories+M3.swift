import Foundation
import SQLiteData

// Repositories added with schema v6 (milestone 3).

// MARK: - Conversations (append-only)

/// Agent conversations and their turns. Turns are only ever appended: there is no update or
/// delete of a turn here, and nothing else in the app writes `agent_turn` (docs/plan-m3.md §2).
public struct ConversationRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Creates a conversation (`running`).
    @discardableResult
    public func start(_ conversation: AgentConversation) async throws -> AgentConversation {
        try await store.save(conversation)
    }

    /// Appends one turn at the next sequence number, in one transaction with the conversation's
    /// `updated_at`. `message` is the turn's JSON, verbatim. ma: `context` is what a user turn of
    /// an `app` conversation carried besides its words (`agent_turn.context`).
    @discardableResult
    public func append(
        to conversationID: AgentConversation.ID,
        role: AgentRole,
        message: String,
        stopReason: String? = nil,
        apiCallID: APICall.ID? = nil,
        context: AgentTurnContext? = nil
    ) async throws -> AgentTurn {
        let store = store
        return try await store.database.write { db in
            let last = try AgentTurn
                .where { $0.conversationID.eq(conversationID) }
                .select { $0.sequence.max() }
                .fetchOne(db) ?? nil
            let turn = store.stamp(AgentTurn(
                conversationID: conversationID, sequence: (last ?? -1) + 1, role: role, message: message,
                stopReason: stopReason, apiCallID: apiCallID, context: context, createdAt: store.currentDate
            ))
            try AgentTurn.insert { turn }.execute(db)
            let stamp = store.currentDate
            try AgentConversation.find(conversationID).update { $0.updatedAt = stamp }.execute(db)
            return turn
        }
    }

    /// The conversation's turns in order.
    public func turns(_ conversationID: AgentConversation.ID) async throws -> [AgentTurn] {
        try await store.database.read { db in
            try AgentTurn.where { $0.conversationID.eq(conversationID) }.order(by: \.sequence).fetchAll(db)
        }
    }

    /// Sets the conversation's state (column-only). `error` is kept readable and secret-free.
    @discardableResult
    public func setState(_ conversationID: AgentConversation.ID, _ state: ConversationState, error: String? = nil) async throws -> AgentConversation? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try AgentConversation.find(conversationID).update {
                $0.state = state
                $0.error = error
                $0.updatedAt = stamp
            }
            .execute(db)
            return try AgentConversation.find(conversationID).fetchOne(db)
        }
    }

    /// ma: the newest conversations of `kind` first (the panel's history menu, grouped by day of
    /// `updated_at`).
    public func conversations(kind: ConversationKind, limit: Int = 50) async throws -> [AgentConversation] {
        try await store.database.read { db in
            try AgentConversation
                .where { $0.kind.eq(kind) }
                .order { $0.updatedAt.desc() }
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Conversations a quit left `running` (launch recovery decides to resume or fail them).
    public func running() async throws -> [AgentConversation] {
        try await store.database.read { db in
            try AgentConversation.where { $0.state.eq(ConversationState.running) }.order(by: \.createdAt).fetchAll(db)
        }
    }
}

// MARK: - API calls

extension APICallRepository {
    /// The `api_call` row the ledger wrote for the response with `requestID` (the Anthropic
    /// `request-id` header) and `purpose`; how a caller links rows to the call that decided them.
    public func call(requestID: String?, purpose: String) async throws -> APICall.ID? {
        guard let requestID, !requestID.isEmpty else { return nil }
        return try await store.database.read { db in
            try APICall
                .where { $0.requestID.eq(String?.some(requestID)) && $0.purpose.eq(purpose) }
                .order { $0.createdAt.desc() }
                .select(\.id)
                .fetchOne(db)
        }
    }
}

// MARK: - Source trails

/// One source of a tracked item with what its popover row shows (docs/DESIGN.md §5.2): for a
/// recording the lecture (number, title, day, the course's lecturers, the slide shown at that
/// moment), for a mail its sender and time. Raw facts; StudyUI's `SourceTrailText` words them.
public struct SourceTrailEntry: Hashable, Sendable, Identifiable {
    public var source: TrackedItemSource
    /// Transcript sources: the lecture the recording belongs to (slide sources: the lecture
    /// showing the page, also set as `source.lectureID`).
    public var lectureNumber: Int?
    public var lectureTitle: String?
    public var lectureHeldAt: Date?
    /// The kind of the lecture's session (a lecture is named "Lecture 2, Example", a seminar
    /// meeting by its title).
    public var sessionKind: SessionKind?
    /// The lecture's course lecturers ("Prof. Dr. Ada Example").
    public var professors: [String]
    /// The slide on screen at `source.time` (from the aligned spans), or the page a slide source
    /// names, when known.
    public var page: Int?
    /// Mail sources: the sender and when the mail arrived.
    public var senderName: String?
    public var senderAddress: String?
    public var receivedAt: Date?

    public init(
        source: TrackedItemSource,
        lectureNumber: Int? = nil,
        lectureTitle: String? = nil,
        lectureHeldAt: Date? = nil,
        sessionKind: SessionKind? = nil,
        professors: [String] = [],
        page: Int? = nil,
        senderName: String? = nil,
        senderAddress: String? = nil,
        receivedAt: Date? = nil
    ) {
        self.source = source
        self.lectureNumber = lectureNumber
        self.lectureTitle = lectureTitle
        self.lectureHeldAt = lectureHeldAt
        self.sessionKind = sessionKind
        self.professors = professors
        self.page = page
        self.senderName = senderName
        self.senderAddress = senderAddress
        self.receivedAt = receivedAt
    }

    public var id: TrackedItemSource.ID { source.id }
    public var kind: SourceRef.Kind { source.kind }
    /// The source is still in effect (not undone).
    public var isActive: Bool { source.undoneAt == nil }
}

extension TrackedItemRepository {
    /// Every item's sources with their popover facts, oldest first.
    public func trails(itemIDs: [TrackedItem.ID]) async throws -> [TrackedItem.ID: [SourceTrailEntry]] {
        try await store.database.read { db in try Self.trails(itemIDs: itemIDs, in: db) }
    }

    /// `trails(itemIDs:)` inside a read (a `FetchKeyRequest`, so a screen follows changes).
    public static func trails(itemIDs: [TrackedItem.ID], in db: Database) throws -> [TrackedItem.ID: [SourceTrailEntry]] {
        guard !itemIDs.isEmpty else { return [:] }
        let sources = try TrackedItemSource
            .where { $0.trackedItemID.in(itemIDs) }
            .order(by: \.createdAt)
            .fetchAll(db)
        var lectures: [Lecture.ID: Lecture] = [:]
        var courses: [Course.ID: Course] = [:]
        var trails: [TrackedItem.ID: [SourceTrailEntry]] = [:]
        for source in sources {
            var entry = SourceTrailEntry(source: source)
            // A slide source names its deck page; its lecture is the one showing that page.
            if source.kind == .slide, let slide = SlideReference(source.rfcMessageID) {
                entry.page = slide.page
                if entry.source.lectureID == nil {
                    entry.source.lectureID = try LectureSlides.lecture(showing: slide.page, of: slide.deckID, in: db)
                }
            }
            if let lectureID = entry.source.lectureID {
                if lectures[lectureID] == nil { lectures[lectureID] = try Lecture.find(lectureID).fetchOne(db) }
                if let lecture = lectures[lectureID] {
                    entry.lectureNumber = lecture.number
                    entry.lectureTitle = lecture.title
                    entry.lectureHeldAt = lecture.heldAt
                    if let sessionID = lecture.lectureSessionID {
                        entry.sessionKind = try LectureSession.find(sessionID).fetchOne(db)?.kind
                    }
                    if courses[lecture.courseID] == nil { courses[lecture.courseID] = try Course.find(lecture.courseID).fetchOne(db) }
                    entry.professors = courses[lecture.courseID]?.professors ?? []
                }
                if let recordingID = source.recordingID, let time = source.time {
                    entry.page = try LectureDeckSpan
                        .where {
                            $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID)
                                && $0.startTime.lte(Double?.some(time)) && $0.endTime.gt(Double?.some(time))
                        }
                        .order(by: \.startTime)
                        .fetchOne(db)?
                        .firstPage
                }
            }
            if source.kind == .mail {
                let rfcID = source.rfcMessageID
                let message: MailMessage? = if let id = source.mailMessageID {
                    try MailMessage.find(id).fetchOne(db)
                } else if !rfcID.isEmpty {
                    try MailMessage.where { $0.rfcMessageID.eq(rfcID) }.fetchOne(db)
                } else {
                    nil
                }
                if let message {
                    entry.senderName = message.fromName
                    entry.senderAddress = message.fromAddress
                    entry.receivedAt = message.receivedAt
                }
            }
            trails[source.trackedItemID, default: []].append(entry)
        }
        return trails
    }
}
