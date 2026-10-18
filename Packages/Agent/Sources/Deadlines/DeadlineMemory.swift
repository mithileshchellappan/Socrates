import Foundation
import StudyCore

/// The deadline & exercise memory (PRD #37): the ONE place that writes `tracked_item` and
/// `tracked_item_source` rows, whatever the source (mail, lecture transcript, the student's words
/// to the agent or the composer). Every write is one transaction, then `onChange()` (the app
/// syncs the calendar).
///
/// Rules (docs/plan-m3.md §3.1):
/// - **Match** (dismissed and done items included, so Undo sticks): (1) the same source and quote
///   (the same mail row or Message-ID; the same recording within ±30 s; the same conversation,
///   or the composer, and then only for the same course, title and due day) → nothing new; (2) a session proposal: the same session and kind (and room); (3) an event
///   or announcement tied to the same session and kind; (3b) an undated task (M3.5, its own kind
///   group): same course and session, similar titles; (4) a dated item: same course, kind
///   group (deadline/exercise/exam together), same day in Exampleton, times within an hour unless
///   one is all-day, similar titles. A match gets a new source row; otherwise a new item. A task
///   with a due date is recorded as a deadline.
/// - **Calendar**: in on its own only for deadline/exercise/exam with a due date, a verified date
///   and a trusted source (`ItemFinding.addsToCalendar`); a qualifying repeat puts an open item
///   in. Everything else waits for Add to Calendar.
/// - **Merging**: a verified time upgrades an all-day item of the same day; empty details and
///   relevance are filled in; a repeat never changes the title or date of an item the student
///   created. Those changes store the item's fields before them on the new source (`previous`).
///   The student's own words (chat) bring back an item they had dismissed.
/// - **Proposals** (M2): a room change or cancellation that repeats an existing proposal row adds a
///   source to it (Confirm / Discard still work). ma: no new proposals are made: a session change
///   is applied on its own through AppAgent's change log (`recordSessionChange`, status `done`),
///   and a room change or cancellation finding without an existing proposal is an announcement.
///   An event or announcement with a time 15 minutes around a session start is tied to that
///   session.
/// - **Undo** puts back `previous` when the source changed the item, else dismisses it and takes
///   it out of the calendar; Restore takes the Undo back. Nothing is ever deleted.
public struct DeadlineMemory: Sendable {
    let services: StudyServices
    let now: @Sendable () -> Date
    let onChange: @Sendable () async -> Void

    public init(
        services: StudyServices,
        now: @escaping @Sendable () -> Date = { Date() },
        onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.services = services
        self.now = now
        self.onChange = onChange
    }

    // MARK: - Recording findings

    /// Adds the finding as a new item or merges it into the item it repeats (dedup across sources).
    @discardableResult
    public func record(_ finding: ItemFinding) async throws -> RecordResult {
        let store = services.records
        let date = now()
        let result = try await services.database.write { db in
            try Self.record(finding, in: db, store: store, now: date)
        }
        await onChange()
        return result
    }

    /// `record(_:)` inside the caller's transaction (MailExtractor writes a message's items and its
    /// extraction state together). Does not call `onChange`.
    public static func record(_ finding: ItemFinding, in db: Database, store: RecordStore, now: Date) throws -> RecordResult {
        try MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone).record(finding)
    }

    /// Tells the app the rows changed after the caller's own transaction with
    /// `record(_:in:store:now:)` (calls `onChange`).
    public func didChange() async {
        await onChange()
    }

    // MARK: - ma: inside the caller's transaction (AppAgent's change log)

    /// `update(_:to:by:)` inside the caller's transaction; no `onChange`. Returns the item and the
    /// source written (nil: nothing changed).
    public static func update(
        _ itemID: TrackedItem.ID, to draft: DeadlineDraft, by finding: ItemFinding, in db: Database, store: RecordStore, now: Date
    ) throws -> (item: TrackedItem, source: TrackedItemSource?)? {
        try MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone).updateWithSource(itemID, to: draft, by: finding)
    }

    /// `complete(_:by:)` inside the caller's transaction; the source written with the fields before.
    public static func complete(
        _ itemID: TrackedItem.ID, by finding: ItemFinding, in db: Database, store: RecordStore, now: Date
    ) throws -> (item: TrackedItem, source: TrackedItemSource?)? {
        try MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone).completeWithSource(itemID, by: finding)
    }

    /// `undo(_:)` inside the caller's transaction.
    @discardableResult
    public static func undo(_ sourceID: TrackedItemSource.ID, in db: Database, store: RecordStore, now: Date) throws -> TrackedItem? {
        try MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone).undo(sourceID)
    }

    /// ma: Undo of a source whose change a newer one of the same field replaced: only the source
    /// is stamped `undone_at`, the item keeps the newer change. `made` (what the source had made
    /// of the item) is kept as its `previous`, so Restore puts it back as with `undo`.
    public static func retire(
        _ sourceID: TrackedItemSource.ID, made: TrackedItemSnapshot?, in db: Database, store: RecordStore, now: Date
    ) throws {
        guard var source = try TrackedItemSource.find(sourceID).fetchOne(db), source.undoneAt == nil else { return }
        source.undoneAt = now
        if let made { source.previous = made }
        let stamped = store.stamp(source)
        try TrackedItemSource.upsert { stamped }.execute(db)
    }

    /// `restore(_:)` inside the caller's transaction.
    @discardableResult
    public static func restore(_ sourceID: TrackedItemSource.ID, in db: Database, store: RecordStore, now: Date) throws -> TrackedItem? {
        try MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone).restore(sourceID)
    }

    /// ma: a session change applied on its own (room change, cancellation, time change, extra
    /// session): a tracked item of that kind tied to the session, settled at once (status `done`,
    /// never in the calendar: the session's own event moves), with its source row (the exact
    /// quote). The session row itself is changed by the caller in the same transaction. `title`
    /// is what the item's popover shows ("Moved to Room 5"); `room` the new room (room changes,
    /// extra sessions).
    public static func recordSessionChange(
        kind: TrackedItemKind, session: LectureSession, title: String, room: String?, finding: ItemFinding,
        in db: Database, store: RecordStore, now: Date
    ) throws -> RecordResult {
        let writer = MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone)
        let item = store.stamp(TrackedItem(
            courseID: session.courseID, kind: kind, title: String(title.prefix(120)), dueAt: session.startsAt, isAllDay: false,
            status: .done, sourceQuote: finding.quote, createdBy: finding.createdBy, lectureSessionID: session.id,
            room: room?.trimmingCharacters(in: .whitespacesAndNewlines), inCalendar: false, createdAt: now
        ))
        try TrackedItem.upsert { item }.execute(db)
        let source = try writer.insertSource(itemID: item.id, finding: finding, calendarAdded: false)
        return RecordResult(item: item, source: source, created: true)
    }

    /// ma: another source of an existing item (a second mail or the lecture saying a session
    /// change that is already applied): only the source row, the item stays as it is.
    @discardableResult
    public static func addSource(
        _ finding: ItemFinding, to itemID: TrackedItem.ID, in db: Database, store: RecordStore, now: Date
    ) throws -> TrackedItemSource {
        try MemoryWriter(db: db, store: store, now: now, timeZone: DeadlinesModule.timeZone)
            .insertSource(itemID: itemID, finding: finding, calendarAdded: false)
    }

    // MARK: - Changes

    /// Changes an item to `draft` (an agent's `update_item`); the item's fields before go on the
    /// finding's new source (`previous`), so Undo puts them back. A changed date stays in the
    /// calendar only when the finding verifies it; a newly verified due date goes in.
    @discardableResult
    public func update(_ itemID: TrackedItem.ID, to draft: DeadlineDraft, by finding: ItemFinding) async throws -> TrackedItem? {
        try await write { writer in try writer.update(itemID, to: draft, by: finding) }
    }

    /// Mark as Done. With a finding (the agent's `complete_item`) the fields before go on its new
    /// source, so Undo reopens the item.
    @discardableResult
    public func complete(_ itemID: TrackedItem.ID, by finding: ItemFinding? = nil) async throws -> TrackedItem? {
        try await write { writer in try writer.complete(itemID, by: finding) }
    }

    /// Delete: the item is dismissed and leaves the calendar; a later repeat does not bring it back.
    @discardableResult
    public func remove(_ itemID: TrackedItem.ID) async throws -> TrackedItem? {
        try await write { writer in try writer.remove(itemID) }
    }

    /// Undo of what one source did: its `previous` fields are put back, or (a source that added
    /// the item) the item is dismissed and leaves the calendar. The source is stamped `undone_at`.
    @discardableResult
    public func undo(_ sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        try await write { writer in try writer.undo(sourceID) }
    }

    /// Takes an Undo back. Through a source that was not undone, a dismissed item comes back.
    @discardableResult
    public func restore(_ sourceID: TrackedItemSource.ID) async throws -> TrackedItem? {
        try await write { writer in try writer.restore(sourceID) }
    }

    /// Add to Calendar: only an open, dated item that is not a session proposal; nil otherwise.
    @discardableResult
    public func addToCalendar(_ itemID: TrackedItem.ID) async throws -> TrackedItem? {
        try await write { writer in try writer.addToCalendar(itemID) }
    }

    private func write(_ body: @escaping @Sendable (MemoryWriter) throws -> TrackedItem?) async throws -> TrackedItem? {
        let store = services.records
        let date = now()
        let item = try await services.database.write { db in
            try body(MemoryWriter(db: db, store: store, now: date, timeZone: DeadlinesModule.timeZone))
        }
        await onChange()
        return item
    }
}

// MARK: - Writing

/// One transaction's worth of memory writes.
struct MemoryWriter {
    let db: Database
    let store: RecordStore
    let now: Date
    let timeZone: TimeZone

    enum Match {
        /// This very source already said it.
        case sameSource(TrackedItem)
        case item(TrackedItem)
    }

    func record(_ original: ItemFinding) throws -> RecordResult {
        var finding = original
        var draft = finding.draft
        draft.title = String(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        draft.details = String(draft.details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        // M3.5: a task is an action without a date of its own; with one it is a deadline.
        if draft.kind == .task, draft.dueAt != nil { draft.kind = .deadline }
        if draft.dueAt == nil, draft.kind != .announcement, draft.kind != .task { draft.kind = .announcement }
        finding.confidence = min(max(finding.confidence.isFinite ? finding.confidence : 0, 0), 1)

        var sessionID: LectureSession.ID?
        if draft.kind.isSessionProposal {
            if let session = try proposalSession(for: finding, draft: draft) {
                sessionID = session.id
                draft.dueAt = session.startsAt
                draft.isAllDay = false
                if draft.kind == .roomChange, let room = draft.room {
                    draft.title = "Move to \(room)?"
                } else if draft.kind == .cancellation {
                    draft.title = "Cancel \(ItemMatching.sessionName(session.kind)) on \(ItemMatching.dayText(session.startsAt, timeZone: timeZone))?"
                }
            } else {
                draft.kind = .announcement
            }
        } else if let given = draft.lectureSessionID {
            sessionID = try LectureSession.find(given).fetchOne(db)?.id
        } else if draft.kind == .event || draft.kind == .announcement, finding.dateVerified, !draft.isAllDay, let due = draft.dueAt {
            sessionID = try session(startingNear: due, courseID: draft.courseID)
        }
        draft.lectureSessionID = sessionID
        if !draft.kind.isSessionProposal {
            draft.room = draft.kind == .event || draft.kind == .exam ? draft.room?.trimmingCharacters(in: .whitespaces) : nil
            if draft.room?.isEmpty == true { draft.room = nil }
        }
        finding.draft = draft

        if let match = try existing(for: finding) {
            switch match {
            case .sameSource(let item) where !(finding.isChat && item.status != .open):
                return RecordResult(item: item, source: nil, created: false)
            case .sameSource(let item), .item(let item):
                return try merge(finding, into: item)
            }
        }
        // ma: no new session proposals. A room change or cancellation that repeats no existing
        // proposal is an announcement (session changes are applied by AppAgent's change log).
        if draft.kind.isSessionProposal {
            var announcement = original
            announcement.draft.kind = .announcement
            announcement.draft.lectureSessionID = sessionID
            announcement.draft.room = nil
            return try record(announcement)
        }

        let adds = finding.addsToCalendar
        let item = store.stamp(TrackedItem(
            courseID: draft.courseID, kind: draft.kind, title: draft.title, details: draft.details, dueAt: draft.dueAt,
            isAllDay: draft.isAllDay, status: .open, sourceQuote: finding.quote, createdBy: finding.createdBy,
            lectureSessionID: sessionID, room: draft.room, inCalendar: adds, relevance: draft.relevance, createdAt: now
        ))
        try TrackedItem.upsert { item }.execute(db)
        let source = try insertSource(itemID: item.id, finding: finding, calendarAdded: adds)
        return RecordResult(item: item, source: source, created: true)
    }

    /// A repeat: a new source row, and what it may change on the item.
    func merge(_ finding: ItemFinding, into found: TrackedItem) throws -> RecordResult {
        let draft = finding.draft
        var item = found
        let before = TrackedItemSnapshot(found)
        let studentsItem = item.createdBy == .user
        // The student's own words bring back what they had dismissed or done.
        if finding.isChat, item.status != .open { item.status = .open }
        // A verified date (a time on an all-day item of that day; a confirmed date for an
        // unconfirmed one) wins over the item's, except on what the student wrote.
        if !studentsItem, finding.trusted, finding.dateVerified, let due = draft.dueAt, let itemDue = item.dueAt,
           !(draft.isAllDay && !item.isAllDay), due != itemDue || draft.isAllDay != item.isAllDay,
           item.isAllDay || !item.inCalendar {
            item.dueAt = due
            item.isAllDay = draft.isAllDay
        }
        if item.details.isEmpty, !draft.details.isEmpty { item.details = draft.details }
        if item.relevance == nil, let relevance = draft.relevance { item.relevance = relevance }
        if item.room == nil, let room = draft.room, item.kind == .event || item.kind == .exam { item.room = room }
        let changed = TrackedItemSnapshot(item) != before
        var calendarAdded = false
        if item.status == .open, !item.inCalendar, finding.addsToCalendar, item.kind.addsToCalendarAutomatically, item.dueAt != nil {
            item.inCalendar = true
            calendarAdded = true
        }
        if changed || calendarAdded {
            let updated = store.stamp(item)
            try TrackedItem.upsert { updated }.execute(db)
            item = updated
        }
        let source = try insertSource(itemID: item.id, finding: finding, calendarAdded: calendarAdded, previous: changed ? before : nil)
        return RecordResult(item: item, source: source, created: false)
    }

    func insertSource(itemID: TrackedItem.ID, finding: ItemFinding, calendarAdded: Bool, previous: TrackedItemSnapshot? = nil) throws -> TrackedItemSource {
        var source = TrackedItemSource(
            trackedItemID: itemID, kind: .chat, quote: finding.quote, confidence: finding.confidence,
            calendarAdded: calendarAdded, apiCallID: finding.apiCallID, previous: previous, createdAt: now
        )
        switch finding.source {
        case .mail(let messageID, let rfcMessageID):
            source.kind = .mail
            source.mailMessageID = messageID
            source.rfcMessageID = rfcMessageID
        case .transcript(let lectureID, let recordingID, let time):
            source.kind = .transcript
            source.lectureID = lectureID
            source.recordingID = recordingID
            source.time = time
        case .chat(let conversationID):
            source.conversationID = conversationID
        case .external(let kind, let reference):
            source.kind = kind
            source.rfcMessageID = reference
        }
        let stamped = store.stamp(source)
        try TrackedItemSource.upsert { stamped }.execute(db)
        return stamped
    }

    // MARK: Matching

    /// The item this finding repeats.
    func existing(for finding: ItemFinding) throws -> Match? {
        let draft = finding.draft
        let group = ItemMatching.group(draft.kind)
        let quote = finding.quote

        // (1) The same source and quote.
        let sameSource: [TrackedItemSource]
        switch finding.source {
        case .mail(let messageID, let rfcID):
            sameSource = try TrackedItemSource
                .where { $0.quote.eq(quote) && ($0.mailMessageID.eq(MailMessage.ID?.some(messageID)) || ($0.rfcMessageID.eq(rfcID) && $0.rfcMessageID.neq(""))) }
                .fetchAll(db)
        case .transcript(_, let recordingID, let time):
            let folded = TextFolding.fold(quote)
            sameSource = try TrackedItemSource
                .where {
                    $0.recordingID.eq(Recording.ID?.some(recordingID))
                        && $0.time.gte(Double?.some(time - 30)) && $0.time.lte(Double?.some(time + 30))
                }
                .fetchAll(db)
                .filter { source in
                    if TextFolding.fold(source.quote) == folded { return true }
                    // A replaced transcript words it differently: the same item said at that moment.
                    guard let item = try? TrackedItem.find(source.trackedItemID).fetchOne(db) else { return false }
                    return ItemMatching.similarTitles(item.title, draft.title)
                }
        case .chat(let conversationID):
            if let conversationID {
                sameSource = try TrackedItemSource
                    .where { $0.conversationID.eq(AgentConversation.ID?.some(conversationID)) && $0.quote.eq(quote) }
                    .fetchAll(db)
            } else {
                sameSource = try TrackedItemSource
                    .where { $0.kind.eq(SourceRef.Kind.chat) && $0.conversationID.is(nil) && $0.quote.eq(quote) }
                    .fetchAll(db)
            }
        case .external(let kind, let reference):
            sameSource = try TrackedItemSource
                .where { $0.kind.eq(kind) && $0.rfcMessageID.eq(reference) && $0.quote.eq(quote) }
                .fetchAll(db)
        }
        for source in sameSource {
            guard let item = try TrackedItem.find(source.trackedItemID).fetchOne(db), ItemMatching.group(item.kind) == group else { continue }
            // The student's words quote a whole turn, which can name several items (and a
            // completion quotes them too); the composer's sentence typed again on another day
            // means another date. A chat source repeats only the same item.
            if finding.isChat, !ItemMatching.sameItem(item, draft, timeZone: timeZone) { continue }
            return .sameSource(item)
        }

        // (2) The same session proposal.
        if draft.kind.isSessionProposal, let sessionID = draft.lectureSessionID {
            let kind = draft.kind
            let proposals = try TrackedItem
                .where { $0.lectureSessionID.eq(LectureSession.ID?.some(sessionID)) && $0.kind.eq(kind) }
                .order(by: \.createdAt)
                .fetchAll(db)
            return proposals
                .first { kind == .cancellation || TextFolding.fold($0.room ?? "") == TextFolding.fold(draft.room ?? "") }
                .map(Match.item)
        }

        // (3) An event or announcement tied to the same session.
        if let sessionID = draft.lectureSessionID, draft.kind == .event || draft.kind == .announcement {
            let kind = draft.kind
            let tied = try TrackedItem
                .where { $0.lectureSessionID.eq(LectureSession.ID?.some(sessionID)) && $0.kind.eq(kind) }
                .order(by: \.createdAt)
                .fetchAll(db)
            // One event per session ("First CL tutorial"); announcements about it only when they say the same.
            if let match = tied.first(where: { kind == .event || ItemMatching.similarTitles($0.title, draft.title) }) {
                return .item(match)
            }
        }

        // (3b) An undated task (its own kind group): the same course and session, a similar title.
        if draft.kind == .task, draft.dueAt == nil {
            let kind = TrackedItemKind.task
            let tasks = try TrackedItem
                .where { $0.kind.eq(kind) && $0.dueAt.is(nil) }
                .order(by: \.createdAt)
                .fetchAll(db)
            return tasks.first { item in
                item.courseID == draft.courseID && item.lectureSessionID == draft.lectureSessionID
                    && ItemMatching.similarTitles(item.title, draft.title)
            }
            .map(Match.item)
        }

        // (4) The same dated item: course, kind group, day (time within an hour), similar title.
        guard let due = draft.dueAt else { return nil }
        let day = CalendarDay(due, in: timeZone)
        let from = day.adding(days: -1).start(in: timeZone)
        let until = day.adding(days: 2).start(in: timeZone)
        let kinds: [TrackedItemKind] = group == "due" ? [.deadline, .exercise, .exam] : [draft.kind]
        let nearby = try TrackedItem
            .where { $0.kind.in(kinds) && $0.dueAt.gte(Date?.some(from)) && $0.dueAt.lt(Date?.some(until)) }
            .order(by: \.createdAt)
            .fetchAll(db)
        return nearby.first { item in
            guard item.courseID == draft.courseID, let itemDue = item.dueAt, CalendarDay(itemDue, in: timeZone) == day else { return false }
            if !item.isAllDay, !draft.isAllDay, abs(itemDue.timeIntervalSince(due)) > 3_600 { return false }
            return ItemMatching.similarTitles(item.title, draft.title)
        }
        .map(Match.item)
    }

    // MARK: Sessions

    /// The one non-cancelled session of the course a room change or cancellation is about: the
    /// quoted day (and time), or the one session of a quoted week ("next week's lecture"); an
    /// explicit session (the agent's) when it exists and is not cancelled. Nil when none or
    /// several match, or the room is the session's already.
    func proposalSession(for finding: ItemFinding, draft: DeadlineDraft) throws -> LectureSession? {
        let room = draft.room?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if draft.kind == .roomChange, room.isEmpty { return nil }
        if let given = draft.lectureSessionID {
            guard let session = try LectureSession.find(given).fetchOne(db), !session.isCancelled else { return nil }
            if draft.kind == .roomChange, TextFolding.fold(room) == TextFolding.fold(session.room) { return nil }
            return session
        }
        guard let courseID = draft.courseID else { return nil }
        if draft.kind == .roomChange, !TextFolding.fold(finding.quote).contains(TextFolding.fold(room)) { return nil }
        let mentions = finding.mentions ?? DateMentions.parse(finding.quote, reference: now, timeZone: timeZone)
        let sessions = try LectureSession
            .where { $0.courseID.eq(courseID) && !$0.isCancelled }
            .order(by: \.startsAt)
            .fetchAll(db)
        var matches: [LectureSession]
        if finding.dateVerified, let due = draft.dueAt {
            let day = CalendarDay(due, in: timeZone)
            matches = sessions.filter { CalendarDay($0.startsAt, in: timeZone) == day }
        } else if !mentions.weeks.isEmpty {
            matches = sessions.filter { session in
                let day = CalendarDay(session.startsAt, in: timeZone)
                return mentions.weeks.contains(day.adding(days: 1 - day.weekday))
            }
        } else {
            return nil
        }
        if !mentions.minutes.isEmpty {
            matches = matches.filter { session in
                let minute = DateMentions.minute(of: session.startsAt, timeZone: timeZone)
                return mentions.minutes.contains { abs($0 - minute) <= 20 }
            }
        }
        if matches.count > 1, let kind = ItemMatching.sessionKind(in: finding.quote) {
            matches = matches.filter { $0.kind == kind }
        }
        guard matches.count == 1, let session = matches.first else { return nil }
        if draft.kind == .roomChange, TextFolding.fold(room) == TextFolding.fold(session.room) { return nil }
        return session
    }

    /// The one session of the course starting within 15 minutes of `date` (an event the calendar
    /// already shows, e.g. the first tutorial).
    func session(startingNear date: Date, courseID: Course.ID?) throws -> LectureSession.ID? {
        guard let courseID else { return nil }
        let from = date.addingTimeInterval(-15 * 60)
        let until = date.addingTimeInterval(15 * 60)
        let sessions = try LectureSession
            .where { $0.courseID.eq(courseID) && !$0.isCancelled && $0.startsAt.gte(from) && $0.startsAt.lte(until) }
            .fetchAll(db)
        return sessions.count == 1 ? sessions.first?.id : nil
    }

    // MARK: Changes

    func update(_ itemID: TrackedItem.ID, to draft: DeadlineDraft, by finding: ItemFinding) throws -> TrackedItem? {
        try updateWithSource(itemID, to: draft, by: finding)?.item
    }

    func updateWithSource(_ itemID: TrackedItem.ID, to draft: DeadlineDraft, by finding: ItemFinding) throws -> (item: TrackedItem, source: TrackedItemSource?)? {
        guard var item = try TrackedItem.find(itemID).fetchOne(db) else { return nil }
        let before = TrackedItemSnapshot(item)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        item.kind = draft.dueAt == nil && draft.kind.isDue ? .announcement : draft.kind
        if item.kind == .task, draft.dueAt != nil { item.kind = .deadline }
        item.title = title.isEmpty ? item.title : String(title.prefix(120))
        item.details = String(draft.details.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        item.courseID = draft.courseID
        item.dueAt = draft.dueAt
        item.isAllDay = draft.dueAt == nil ? false : draft.isAllDay
        item.relevance = draft.relevance
        item.room = draft.room
        item.lectureSessionID = draft.lectureSessionID
        var calendarAdded = false
        if before.dueAt != item.dueAt || before.isAllDay != item.isAllDay || before.kind != item.kind {
            var check = finding
            check.draft = DeadlineDraft(kind: item.kind, title: item.title, dueAt: item.dueAt, isAllDay: item.isAllDay)
            if item.status == .open, check.addsToCalendar {
                calendarAdded = !item.inCalendar
                item.inCalendar = true
            } else if item.dueAt == nil || !(finding.trusted && finding.dateVerified) {
                // A date its source does not confirm never stays in the calendar.
                item.inCalendar = false
            }
        }
        if item.kind.isSessionProposal { item.inCalendar = false }
        guard TrackedItemSnapshot(item) != before else { return (item, nil) }
        let updated = store.stamp(item)
        try TrackedItem.upsert { updated }.execute(db)
        let source = try insertSource(itemID: itemID, finding: finding, calendarAdded: calendarAdded, previous: before)
        return (updated, source)
    }

    func complete(_ itemID: TrackedItem.ID, by finding: ItemFinding?) throws -> TrackedItem? {
        if let finding { return try completeWithSource(itemID, by: finding)?.item }
        guard var item = try TrackedItem.find(itemID).fetchOne(db) else { return nil }
        guard item.status != .done else { return item }
        item.status = .done
        let done = store.stamp(item)
        try TrackedItem.upsert { done }.execute(db)
        return done
    }

    func completeWithSource(_ itemID: TrackedItem.ID, by finding: ItemFinding) throws -> (item: TrackedItem, source: TrackedItemSource?)? {
        guard var item = try TrackedItem.find(itemID).fetchOne(db) else { return nil }
        guard item.status != .done else { return (item, nil) }
        let before = TrackedItemSnapshot(item)
        item.status = .done
        let done = store.stamp(item)
        try TrackedItem.upsert { done }.execute(db)
        let source = try insertSource(itemID: itemID, finding: finding, calendarAdded: false, previous: before)
        return (done, source)
    }

    func remove(_ itemID: TrackedItem.ID) throws -> TrackedItem? {
        guard var item = try TrackedItem.find(itemID).fetchOne(db) else { return nil }
        guard item.status != .dismissed || item.inCalendar else { return item }
        item.status = .dismissed
        item.inCalendar = false
        let dismissed = store.stamp(item)
        try TrackedItem.upsert { dismissed }.execute(db)
        return dismissed
    }

    /// While a source with `previous` is undone, its `previous` holds what the source had made of
    /// the item, so Restore can put that back (the two states swap).
    func undo(_ sourceID: TrackedItemSource.ID) throws -> TrackedItem? {
        guard var source = try TrackedItemSource.find(sourceID).fetchOne(db),
              var item = try TrackedItem.find(source.trackedItemID).fetchOne(db) else { return nil }
        guard source.undoneAt == nil else { return item }
        if let previous = source.previous {
            source.previous = TrackedItemSnapshot(item)
            item = previous.applied(to: item)
        } else {
            item.status = .dismissed
            item.inCalendar = false
        }
        source.undoneAt = now
        return try save(item, source)
    }

    func restore(_ sourceID: TrackedItemSource.ID) throws -> TrackedItem? {
        guard var source = try TrackedItemSource.find(sourceID).fetchOne(db),
              var item = try TrackedItem.find(source.trackedItemID).fetchOne(db) else { return nil }
        guard source.undoneAt != nil else { return try reopen(item) }
        if let made = source.previous {
            source.previous = TrackedItemSnapshot(item)
            item = made.applied(to: item)
        } else {
            item.status = .open
            if source.calendarAdded { item.inCalendar = true }
        }
        source.undoneAt = nil
        return try save(item, source)
    }

    /// Restore through a source that was not undone (Mail's row of an item deleted in Calendar or
    /// Today, or dismissed by another source's Undo): the item comes back, as in M2. The Undo that
    /// dismissed it is taken back when there is one; else the item reopens, in the calendar when
    /// a standing source had put it there.
    private func reopen(_ found: TrackedItem) throws -> TrackedItem {
        guard found.status == .dismissed, !found.kind.isSessionProposal else { return found }
        let itemID = found.id
        let sources = try TrackedItemSource.where { $0.trackedItemID.eq(itemID) }.fetchAll(db)
        let dismissing = sources
            .filter { $0.undoneAt != nil && $0.previous == nil }
            .max { ($0.undoneAt ?? .distantPast) < ($1.undoneAt ?? .distantPast) }
        if let dismissing { return try restore(dismissing.id) ?? found }
        var item = found
        item.status = .open
        if item.dueAt != nil, sources.contains(where: { $0.undoneAt == nil && $0.calendarAdded }) { item.inCalendar = true }
        let open = store.stamp(item)
        try TrackedItem.upsert { open }.execute(db)
        return open
    }

    func addToCalendar(_ itemID: TrackedItem.ID) throws -> TrackedItem? {
        guard var item = try TrackedItem.find(itemID).fetchOne(db),
              item.status == .open, item.dueAt != nil, !item.kind.isSessionProposal
        else { return nil }
        if item.inCalendar { return item }
        item.inCalendar = true
        let added = store.stamp(item)
        try TrackedItem.upsert { added }.execute(db)
        return added
    }

    private func save(_ item: TrackedItem, _ source: TrackedItemSource) throws -> TrackedItem {
        let stampedSource = store.stamp(source)
        try TrackedItemSource.upsert { stampedSource }.execute(db)
        let stampedItem = store.stamp(item)
        try TrackedItem.upsert { stampedItem }.execute(db)
        return stampedItem
    }
}

// MARK: - Matching helpers

enum ItemMatching {
    /// Kinds that count as the same thing when deduplicating.
    static func group(_ kind: TrackedItemKind) -> String {
        kind.isDue ? "due" : kind.rawValue
    }

    /// The same item as `draft` describes: course, similar title, the due day in Exampleton (or both
    /// undated) and, for a proposal, the session.
    static func sameItem(_ item: TrackedItem, _ draft: DeadlineDraft, timeZone: TimeZone) -> Bool {
        guard item.courseID == draft.courseID, similarTitles(item.title, draft.title) else { return false }
        if draft.kind.isSessionProposal, item.lectureSessionID != draft.lectureSessionID { return false }
        switch (item.dueAt, draft.dueAt) {
        case (nil, nil): return true
        case let (itemDue?, due?): return CalendarDay(itemDue, in: timeZone) == CalendarDay(due, in: timeZone)
        default: return false
        }
    }

    /// Word overlap of at least half the shorter title, and no contradicting numbers ("Sheet 1" ≠ "Sheet 2").
    static func similarTitles(_ lhs: String, _ rhs: String) -> Bool {
        let left = TextFolding.titleWords(lhs)
        let right = TextFolding.titleWords(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        let leftNumbers = left.filter { $0.allSatisfy(\.isNumber) }
        let rightNumbers = right.filter { $0.allSatisfy(\.isNumber) }
        if !leftNumbers.isEmpty, !rightNumbers.isEmpty, leftNumbers.isDisjoint(with: rightNumbers) { return false }
        let overlap = Double(left.intersection(right).count) / Double(min(left.count, right.count))
        return overlap >= 0.5
    }

    /// The session kind a quote names ("lecture", "Übung", "Tutorium", …).
    static func sessionKind(in quote: String) -> SessionKind? {
        let words = Set(TextFolding.words(quote))
        if !words.isDisjoint(with: ["lecture", "lectures", "vorlesung", "vl"]) { return .lecture }
        if !words.isDisjoint(with: ["exercise", "ubung", "uebung", "ubungen"]) { return .exercise }
        if !words.isDisjoint(with: ["tutorial", "tutorium", "tutorien", "tutorials"]) { return .tutorial }
        if words.contains("seminar") { return .seminar }
        return nil
    }

    static func sessionName(_ kind: SessionKind) -> String {
        switch kind {
        case .exercise: "exercise"
        case .tutorial: "tutorial"
        case .seminar: "seminar"
        default: "lecture"
        }
    }

    /// "Thu 22 Oct".
    static func dayText(_ date: Date, timeZone: TimeZone) -> String {
        let parts = Calendar.gregorian(in: timeZone).dateComponents([.weekday, .day, .month], from: date)
        let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][((parts.weekday ?? 1) - 1 + 7) % 7]
        let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][((parts.month ?? 1) - 1 + 12) % 12]
        return "\(weekday) \(parts.day ?? 1) \(month)"
    }
}
