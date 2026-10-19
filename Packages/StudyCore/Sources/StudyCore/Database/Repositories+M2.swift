import Foundation
import SQLiteData

// Repositories shared by milestone-2 modules (mail sync, mail intelligence, mail UI, the calendar
// mirror). Module-private queries live in the modules; these are the reads and writes more than
// one module relies on. Writes that touch a few columns of a busy row are column-only updates,
// so concurrent writers (sync, routing, the reader marking a message seen) never revert each other.

// MARK: - Account and mailboxes

public struct MailAccountRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Every account, oldest first.
    public func all() async throws -> [MailAccount] {
        try await store.database.read { db in
            try MailAccount.order(by: \.createdAt).fetchAll(db)
        }
    }

    /// The account mail syncs from: the oldest enabled one (M2 has one).
    public func current() async throws -> MailAccount? {
        try await store.database.read { db in
            try MailAccount.where { $0.isEnabled }.order(by: \.createdAt).fetchOne(db)
        }
    }

    /// Records how a sync attempt ended (`error` nil = it reached the server). Writes only
    /// `last_sync_at`, `last_error` and `updated_at`, never settings the student is editing.
    @discardableResult
    public func recordSync(_ accountID: MailAccount.ID, at date: Date, error: String?) async throws -> MailAccount? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            if let error {
                try MailAccount.find(accountID).update { $0.lastError = String?.some(error); $0.updatedAt = stamp }.execute(db)
            } else {
                try MailAccount.find(accountID).update { $0.lastSyncAt = Date?.some(date); $0.lastError = String?.none; $0.updatedAt = stamp }.execute(db)
            }
            return try MailAccount.find(accountID).fetchOne(db)
        }
    }
}

public struct MailboxRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// An account's mailboxes by path.
    public func mailboxes(accountID: MailAccount.ID) async throws -> [Mailbox] {
        try await store.database.read { db in
            try Mailbox.where { $0.accountID.eq(accountID) }.order(by: \.path).fetchAll(db)
        }
    }

    /// The mailbox with `role` (INBOX, Sent, Archive, …), if the account has one.
    public func mailbox(role: MailboxRole, accountID: MailAccount.ID) async throws -> Mailbox? {
        try await store.database.read { db in
            try Mailbox
                .where { $0.accountID.eq(accountID) && $0.role.eq(MailboxRole?.some(role)) }
                .order(by: \.path)
                .fetchOne(db)
        }
    }
}

// MARK: - Messages

/// Unread messages in the Inbox, by where they belong (sidebar badges, the digest).
public struct MailUnreadCounts: Hashable, Sendable {
    /// Unread messages in INBOX mailboxes.
    public var inbox: Int
    /// Of those, per course.
    public var byCourse: [Course.ID: Int]
    /// Of those, per category other than `course` (University, Newsletters, …).
    public var byCategory: [MailCategory: Int]

    public init(inbox: Int = 0, byCourse: [Course.ID: Int] = [:], byCategory: [MailCategory: Int] = [:]) {
        self.inbox = inbox
        self.byCourse = byCourse
        self.byCategory = byCategory
    }
}

public struct MailRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func message(_ id: MailMessage.ID) async throws -> MailMessage? {
        try await store.fetch(MailMessage.self, id: id)
    }

    /// Every copy of a message (one per mailbox) by its Message-ID (without angle brackets).
    public func messages(rfcMessageID: String) async throws -> [MailMessage] {
        guard !rfcMessageID.isEmpty else { return [] }
        return try await store.database.read { db in
            try MailMessage.where { $0.rfcMessageID.eq(rfcMessageID) }.order(by: \.receivedAt).fetchAll(db)
        }
    }

    /// A thread's messages (all mailboxes, Sent included), oldest first.
    public func thread(_ threadID: String) async throws -> [MailMessage] {
        guard !threadID.isEmpty else { return [] }
        return try await store.database.read { db in
            try MailMessage.where { $0.threadID.eq(threadID) }.order(by: \.receivedAt).fetchAll(db)
        }
    }

    public func attachments(messageID: MailMessage.ID) async throws -> [MailAttachment] {
        try await store.database.read { db in
            try MailAttachment.where { $0.mailMessageID.eq(messageID) }.order(by: \.part).fetchAll(db)
        }
    }

    /// Messages not routed yet (no category), oldest first.
    public func unrouted(limit: Int = 50) async throws -> [MailMessage] {
        try await store.database.read { db in
            try MailMessage
                .where { $0.category.is(nil) }
                .order(by: \.receivedAt)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Routed messages waiting for extraction, oldest first.
    public func pendingExtraction(limit: Int = 20) async throws -> [MailMessage] {
        try await store.database.read { db in
            try MailMessage
                .where { $0.category.isNot(nil) && $0.extractionState.eq(MailExtractionState.pending) }
                .order(by: \.receivedAt)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Writes a message's route (`nil` clears it, e.g. after the course was deleted). A route the
    /// student chose is only replaced by another `.user` route: returns false (and writes nothing)
    /// otherwise. Column-only.
    @discardableResult
    public func setRoute(
        _ id: MailMessage.ID,
        _ route: MailRoute?,
        source: MailRoutingSource,
        ruleID: MailRule.ID? = nil,
        confidence: Double? = nil,
        apiCallID: APICall.ID? = nil,
        at date: Date
    ) async throws -> Bool {
        let stamp = store.currentDate
        return try await store.database.write { db in
            guard let message = try MailMessage.find(id).fetchOne(db) else { return false }
            if message.routingSource == .user, source != .user { return false }
            try MailMessage.find(id).update {
                $0.courseID = route?.courseID
                $0.category = route?.category
                $0.routingSource = route == nil ? nil : source
                $0.routingRuleID = ruleID
                $0.routingConfidence = confidence
                $0.routedAt = route == nil ? nil : date
                $0.routingAPICallID = apiCallID
                $0.updatedAt = stamp
            }
            .execute(db)
            return true
        }
    }

    /// Records an extraction pass. `.failed` below the attempt limit counts the attempt and keeps
    /// the message pending; at the limit it is marked failed. Column-only.
    @discardableResult
    public func recordExtraction(
        _ id: MailMessage.ID,
        _ state: MailExtractionState,
        apiCallID: APICall.ID? = nil,
        at date: Date
    ) async throws -> MailMessage? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            guard let message = try MailMessage.find(id).fetchOne(db) else { return nil }
            let attempts = message.extractionAttempts + (state == .failed ? 1 : 0)
            let final: MailExtractionState = state == .failed && attempts < MailMessage.maximumExtractionAttempts ? .pending : state
            try MailMessage.find(id).update {
                $0.extractionState = final
                $0.extractionAttempts = attempts
                $0.extractedAt = final == .pending ? nil : date
                $0.extractionAPICallID = apiCallID
                $0.updatedAt = stamp
            }
            .execute(db)
            return try MailMessage.find(id).fetchOne(db)
        }
    }

    /// Marks messages read or unread here; the sync stores it on the server (`flags_changed_at`).
    public func setSeen(_ ids: [MailMessage.ID], _ seen: Bool, at date: Date) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try MailMessage
                .where { $0.id.in(ids) && $0.isSeen.neq(seen) }
                .update { $0.isSeen = seen; $0.flagsChangedAt = Date?.some(date); $0.updatedAt = stamp }
                .execute(db)
        }
    }

    /// Flags or unflags a message here; the sync stores it on the server.
    public func setFlagged(_ id: MailMessage.ID, _ flagged: Bool, at date: Date) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try MailMessage
                .where { $0.id.eq(id) && $0.isFlagged.neq(flagged) }
                .update { $0.isFlagged = flagged; $0.flagsChangedAt = Date?.some(date); $0.updatedAt = stamp }
                .execute(db)
        }
    }

    /// Unread messages in INBOX mailboxes, in total and by course and category.
    public func unreadCounts() async throws -> MailUnreadCounts {
        try await store.database.read { db in try Self.unreadCounts(in: db) }
    }

    /// `unreadCounts()` inside a read (M3: Today's mail line in its one `FetchKeyRequest`).
    public static func unreadCounts(in db: Database) throws -> MailUnreadCounts {
        let inboxes = try Mailbox.where { $0.role.eq(MailboxRole?.some(.inbox)) }.select(\.id).fetchAll(db)
        guard !inboxes.isEmpty else { return MailUnreadCounts() }
        let unread = try MailMessage
            .where { $0.mailboxID.in(inboxes) && !$0.isSeen && $0.moveToMailboxID.is(nil) }
            .select { ($0.courseID, $0.category) }
            .fetchAll(db)
        var counts = MailUnreadCounts(inbox: unread.count)
        for (courseID, category) in unread {
            if let courseID {
                counts.byCourse[courseID, default: 0] += 1
            } else if let category, category != .course {
                counts.byCategory[category, default: 0] += 1
            }
        }
        return counts
    }
}

// MARK: - Rules

public struct MailRuleRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Every rule in the order the router tries them: user rules before learned ones, then by
    /// course order and `sort_order`.
    public func rules() async throws -> [MailRule] {
        try await store.database.read { db in
            let order = try Course.order { ($0.sortOrder, $0.name) }.select(\.id).fetchAll(db)
            let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            return try MailRule.all.fetchAll(db).sorted { lhs, rhs in
                let left = (lhs.origin == .user ? 0 : 1, lhs.courseID.flatMap { rank[$0] } ?? Int.max, lhs.sortOrder, lhs.createdAt)
                let right = (rhs.origin == .user ? 0 : 1, rhs.courseID.flatMap { rank[$0] } ?? Int.max, rhs.sortOrder, rhs.createdAt)
                return left < right
            }
        }
    }

    /// A course's rules in display order (Course Settings ▸ Mail).
    public func rules(courseID: Course.ID) async throws -> [MailRule] {
        try await store.database.read { db in
            try MailRule
                .where { $0.courseID.eq(courseID) }
                .order { ($0.sortOrder, $0.createdAt) }
                .fetchAll(db)
        }
    }
}

// MARK: - Drafts

public struct MailDraftRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Drafts in `states`, newest first.
    public func drafts(in states: Set<MailDraftState>) async throws -> [MailDraft] {
        let states = Array(states)
        return try await store.database.read { db in
            try MailDraft.where { $0.state.in(states) }.order { $0.updatedAt.desc() }.fetchAll(db)
        }
    }

    /// The open draft (generating, draft or failed) replying to `messageID`, newest first.
    public func openDraft(replyingTo messageID: MailMessage.ID) async throws -> MailDraft? {
        let open: [MailDraftState] = [.generating, .draft, .failed]
        return try await store.database.read { db in
            try MailDraft
                .where { $0.mailMessageID.eq(messageID) && $0.state.in(open) }
                .order { $0.updatedAt.desc() }
                .fetchOne(db)
        }
    }

    /// Moves a draft from one of `states` to `state`, applying `change`, in one transaction.
    /// Returns nil (and writes nothing) when the draft is gone or in another state, e.g. Send
    /// pressed twice, or a crash recovery racing a send.
    @discardableResult
    public func transition(
        _ id: MailDraft.ID,
        from states: Set<MailDraftState>,
        to state: MailDraftState,
        _ change: @escaping @Sendable (inout MailDraft) -> Void = { _ in }
    ) async throws -> MailDraft? {
        let store = store
        return try await store.database.write { db in
            guard var draft = try MailDraft.find(id).fetchOne(db), states.contains(draft.state) else { return nil }
            change(&draft)
            draft.state = state
            let stamped = store.stamp(draft)
            try MailDraft.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// The agent's text so far. Replaces `generated_body`, and `body` too while the student has not
    /// edited it (body still equals the previous agent text); after the first edit the student's
    /// text is never overwritten. Only while the draft is `generating`. Returns the draft.
    @discardableResult
    public func streamGenerated(_ id: MailDraft.ID, text: String) async throws -> MailDraft? {
        let store = store
        return try await store.database.write { db in
            guard var draft = try MailDraft.find(id).fetchOne(db), draft.state == .generating else { return nil }
            if draft.body == (draft.generatedBody ?? "") { draft.body = text }
            draft.generatedBody = text
            let stamped = store.stamp(draft)
            try MailDraft.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// The student's text (column-only: `body`), while the draft is not sending or sent.
    @discardableResult
    public func editBody(_ id: MailDraft.ID, _ body: String) async throws -> Bool {
        let stamp = store.currentDate
        let editable: [MailDraftState] = [.generating, .draft, .failed]
        return try await store.database.write { db in
            try MailDraft.where { $0.id.eq(id) && $0.state.in(editable) }
                .update { $0.body = body; $0.updatedAt = stamp }
                .execute(db)
            return db.changesCount > 0
        }
    }

    /// Recipients and subject (column-only), while the draft is not sending or sent.
    @discardableResult
    public func editHeaders(
        _ id: MailDraft.ID,
        to: [MailAddress],
        cc: [MailAddress],
        bcc: [MailAddress],
        subject: String
    ) async throws -> Bool {
        let store = store
        let editable: Set<MailDraftState> = [.generating, .draft, .failed]
        return try await store.database.write { db in
            guard var draft = try MailDraft.find(id).fetchOne(db), editable.contains(draft.state) else { return false }
            draft.to = to
            draft.cc = cc
            draft.bcc = bcc
            draft.subject = subject
            let stamped = store.stamp(draft)
            try MailDraft.upsert { stamped }.execute(db)
            return true
        }
    }
}

// MARK: - Tracked items: provenance, Undo, calendar

/// A tracked item with one of its sources (the reader's "found" rows: what this mail added).
public struct SourcedItem: Hashable, Sendable, Identifiable {
    public var item: TrackedItem
    public var source: TrackedItemSource

    public init(item: TrackedItem, source: TrackedItemSource) {
        self.item = item
        self.source = source
    }

    public var id: TrackedItemSource.ID { source.id }
}

extension TrackedItemRepository {
    /// Items read from a mail message (by row, or by Message-ID for a copy in another mailbox),
    /// with that source, in due order.
    public func items(mailMessageID: MailMessage.ID) async throws -> [SourcedItem] {
        try await store.database.read { db in
            guard let message = try MailMessage.find(mailMessageID).fetchOne(db) else { return [] }
            let rfcID = message.rfcMessageID
            let sources = try TrackedItemSource
                .where { $0.mailMessageID.eq(mailMessageID) || ($0.rfcMessageID.eq(rfcID) && $0.rfcMessageID.neq("")) }
                .order(by: \.createdAt)
                .fetchAll(db)
            var seen: Set<TrackedItem.ID> = []
            var pairs: [SourcedItem] = []
            for source in sources where seen.insert(source.trackedItemID).inserted {
                if let item = try TrackedItem.find(source.trackedItemID).fetchOne(db) {
                    pairs.append(SourcedItem(item: item, source: source))
                }
            }
            return pairs.sorted { ($0.item.dueAt ?? .distantFuture, $0.item.createdAt) < ($1.item.dueAt ?? .distantFuture, $1.item.createdAt) }
        }
    }

    /// Every source of an item, oldest first.
    public func sources(itemID: TrackedItem.ID) async throws -> [TrackedItemSource] {
        try await store.database.read { db in
            try TrackedItemSource.where { $0.trackedItemID.eq(itemID) }.order(by: \.createdAt).fetchAll(db)
        }
    }

    /// Open session proposals (room changes, cancellations) waiting for Confirm, soonest first.
    public func openProposals() async throws -> [TrackedItem] {
        let kinds: [TrackedItemKind] = [.roomChange, .cancellation]
        return try await store.database.read { db in
            try TrackedItem
                .where { $0.status.eq(TrackedItemStatus.open) && $0.kind.in(kinds) }
                .order(by: \.dueAt)
                .fetchAll(db)
        }
    }

    /// Items whose calendar event must be written or removed (new, changed, undone).
    public func needingCalendarSync() async throws -> [TrackedItem] {
        try await store.database.read { db in
            try TrackedItem
                .where { $0.inCalendar || $0.calendarEventID.isNot(nil) }
                .order(by: \.dueAt)
                .fetchAll(db)
                .filter(\.needsCalendarSync)
        }
    }

    /// Records that the calendar matches the item (`eventID` nil: no event any more), stamping
    /// `updated_at` = `calendar_synced_at` in one write, but only while the item is unchanged
    /// since `ifUpdatedAt` (an edit that lands while the event was written stays dirty). Returns
    /// nil when the item is gone or changed.
    @discardableResult
    public func markCalendarSynced(_ itemID: TrackedItem.ID, eventID: String?, ifUpdatedAt version: Date) async throws -> TrackedItem? {
        let store = store
        return try await store.database.write { db in
            guard var item = try TrackedItem.find(itemID).fetchOne(db), item.updatedAt == version else { return nil }
            item.calendarEventID = eventID
            item = store.stamp(item)
            item.calendarSyncedAt = item.updatedAt
            let synced = item
            try TrackedItem.upsert { synced }.execute(db)
            return synced
        }
    }

    /// Undo of what one source added: the item is dismissed and leaves the calendar, the source
    /// is marked undone, in one transaction. A later source repeating the same item does not bring
    /// it back (extraction matches dismissed items too). Returns the item.
    @discardableResult
    public func undo(sourceID: TrackedItemSource.ID, at date: Date) async throws -> TrackedItem? {
        let store = store
        return try await store.database.write { db in
            guard var source = try TrackedItemSource.find(sourceID).fetchOne(db),
                  var item = try TrackedItem.find(source.trackedItemID).fetchOne(db) else { return nil }
            source.undoneAt = date
            let undone = store.stamp(source)
            try TrackedItemSource.upsert { undone }.execute(db)
            item.status = .dismissed
            item.inCalendar = false
            let dismissed = store.stamp(item)
            try TrackedItem.upsert { dismissed }.execute(db)
            return dismissed
        }
    }

    /// Takes back an Undo: the item is open again, in the calendar when that source had put it
    /// there. Returns the item.
    @discardableResult
    public func restore(sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        let store = store
        return try await store.database.write { db in
            guard var source = try TrackedItemSource.find(sourceID).fetchOne(db),
                  var item = try TrackedItem.find(source.trackedItemID).fetchOne(db) else { return nil }
            source.undoneAt = nil
            let restored = store.stamp(source)
            try TrackedItemSource.upsert { restored }.execute(db)
            item.status = .open
            if source.calendarAdded { item.inCalendar = true }
            let open = store.stamp(item)
            try TrackedItem.upsert { open }.execute(db)
            return open
        }
    }

    /// Puts an item in the calendar or takes it out (Add to Calendar). Column-only.
    @discardableResult
    public func setInCalendar(_ itemID: TrackedItem.ID, _ inCalendar: Bool) async throws -> TrackedItem? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try TrackedItem.find(itemID).update { $0.inCalendar = inCalendar; $0.updatedAt = stamp }.execute(db)
            return try TrackedItem.find(itemID).fetchOne(db)
        }
    }

    /// Settles a session proposal: Confirm (`done`; the app has applied the room change or
    /// cancellation to the session through Courses first) or Discard (`dismissed`). Only an open
    /// proposal changes; returns nil otherwise.
    @discardableResult
    public func resolveProposal(_ itemID: TrackedItem.ID, confirmed: Bool) async throws -> TrackedItem? {
        let store = store
        return try await store.database.write { db in
            guard var item = try TrackedItem.find(itemID).fetchOne(db), item.status == .open, item.kind.isSessionProposal else {
                return nil
            }
            item.status = confirmed ? .done : .dismissed
            let settled = store.stamp(item)
            try TrackedItem.upsert { settled }.execute(db)
            return settled
        }
    }
}

extension SessionRepository {
    /// `markCalendarSynced(_:eventID:)`, but only while the session is unchanged since
    /// `ifUpdatedAt`; returns nil when it is gone or changed (it stays dirty for the next pass).
    @discardableResult
    public func markCalendarSynced(_ sessionID: LectureSession.ID, eventID: String?, ifUpdatedAt version: Date) async throws -> LectureSession? {
        let store = store
        return try await store.database.write { db in
            guard var session = try LectureSession.find(sessionID).fetchOne(db), session.updatedAt == version else { return nil }
            session.calendarEventID = eventID
            session = store.stamp(session)
            session.calendarSyncedAt = session.updatedAt
            let synced = session
            try LectureSession.upsert { synced }.execute(db)
            return synced
        }
    }
}

// MARK: - Search index writes

/// One chunk to write into `search_chunk` (a public, `Sendable` stand-in for the macro's internal
/// `SearchChunk.Draft`).
public struct SearchChunkInput: Hashable, Sendable {
    public var kind: SearchChunkKind
    public var sourceID: UUID
    public var courseID: Course.ID?
    public var lectureID: Lecture.ID?
    public var deckID: Deck.ID?
    public var pageNumber: Int?
    public var recordingID: Recording.ID?
    public var noteID: Note.ID?
    public var mailMessageID: MailMessage.ID?
    /// v14: a `document` chunk's document.
    public var documentID: StudyDocument.ID?
    public var startTime: Double?
    public var endTime: Double?
    public var lang: String
    public var text: String
    public var lemmaText: String
    public var sourceUpdatedAt: Date?

    public init(
        kind: SearchChunkKind,
        sourceID: UUID,
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        deckID: Deck.ID? = nil,
        pageNumber: Int? = nil,
        recordingID: Recording.ID? = nil,
        noteID: Note.ID? = nil,
        mailMessageID: MailMessage.ID? = nil,
        documentID: StudyDocument.ID? = nil,
        startTime: Double? = nil,
        endTime: Double? = nil,
        lang: String = "",
        text: String,
        lemmaText: String = "",
        sourceUpdatedAt: Date? = nil
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.courseID = courseID
        self.lectureID = lectureID
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.recordingID = recordingID
        self.noteID = noteID
        self.mailMessageID = mailMessageID
        self.documentID = documentID
        self.startTime = startTime
        self.endTime = endTime
        self.lang = lang
        self.text = text
        self.lemmaText = lemmaText
        self.sourceUpdatedAt = sourceUpdatedAt
    }
}

public struct SearchIndexRepository: Sendable {
    public let database: any DatabaseWriter
    private let now: @Sendable () -> Date

    public init(database: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    /// Replaces every chunk of one source (`kind` + `source_id`) with `chunks` in one transaction:
    /// delete + insert, never INSERT OR REPLACE (the FTS triggers follow).
    public func replaceChunks(kind: SearchChunkKind, sourceID: UUID, with chunks: [SearchChunkInput]) async throws {
        let stamp = now()
        try await database.write { db in
            try SearchChunk.where { $0.kind.eq(kind) && $0.sourceID.eq(sourceID) }.delete().execute(db)
            for chunk in chunks {
                try SearchChunk.insert {
                    SearchChunk.Draft(
                        kind: chunk.kind, sourceID: chunk.sourceID, courseID: chunk.courseID, lectureID: chunk.lectureID,
                        deckID: chunk.deckID, pageNumber: chunk.pageNumber, recordingID: chunk.recordingID,
                        noteID: chunk.noteID, mailMessageID: chunk.mailMessageID, documentID: chunk.documentID, startTime: chunk.startTime,
                        endTime: chunk.endTime, lang: chunk.lang, text: chunk.text, lemmaText: chunk.lemmaText,
                        sourceUpdatedAt: chunk.sourceUpdatedAt, updatedAt: stamp
                    )
                }
                .execute(db)
            }
        }
    }

    /// Chunks of one kind (tests, catch-up checks).
    public func count(kind: SearchChunkKind) async throws -> Int {
        try await database.read { db in
            try SearchChunk.where { $0.kind.eq(kind) }.fetchCount(db)
        }
    }
}
