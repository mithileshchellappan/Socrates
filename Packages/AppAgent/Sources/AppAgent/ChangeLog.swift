import Courses
import Deadlines
import Foundation
import StudyCore

/// The activity log and the one write path of every automatic change (docs/plan-agent.md §4):
/// each change of the app's own data (a session's room, time, cancellation, restoration or an
/// extra session; an item added, moved, done or updated; a course fact; a note appended to at the
/// student's request; a reminder) is applied together with its `agent_change` row (and, for items
/// and session changes, a `tracked_item_source` row with the exact quote) in ONE transaction, so
/// Undo always has what it needs. Nothing is deleted: Undo puts the target back from `before` and
/// stamps `undone_at`.
///
/// Rules, in code:
/// - **Conflicts**: the newest authoritative source wins (the student's words in chat > mail >
///   the lecture's own words > a timetable file > a calendar edit elsewhere; equal rank: the newer
///   source). Haiku's change that loses is not applied (`.conflict`: triage escalates it); a
///   careful decision (Opus: an escalation, the panel) may overrule a stronger source. A change
///   that is applied marks the older change of the same target and field `superseded_by` (kept,
///   both sources stay on the item).
/// - **Undo** puts back only what the change wrote (a session's field of the change's kind, the
///   one course rule or the lecturers), and only while the target still holds what it wrote; a
///   change a newer one replaced only gets its row (and its item source) marked undone.
/// - **The student's own edits**: a session the student edited by hand, an item or a rule they
///   wrote, is never changed by Haiku (`.conflict`, escalated to Opus).
/// - **Session changes** settle at once: the session row is changed (`edited_at`, replanned and
///   renumbered), a tracked item of the change's kind is written `done` with its source.
public struct ChangeLog: Sendable {
    /// Where a change comes from and who decided it.
    public struct Origin: Sendable, Hashable {
        public var source: ItemFinding.Source
        /// When the source said it (a mail's Date, the class's time, now for chat): equal-rank
        /// conflicts go to the newer.
        public var sourceDate: Date
        /// `claude-haiku-5-5`, `claude-opus-5-5`, or "" for code (a timetable diff).
        public var model: String
        public var apiCallID: APICall.ID?
        public var eventID: AgentEvent.ID?
        public var taskID: AgentTask.ID?
        /// The conversation the change was made in (the panel's, a task's).
        public var conversationID: AgentConversation.ID?
        /// False for mail with text that talks to a model: nothing from it enters the calendar.
        public var trusted: Bool

        public init(
            source: ItemFinding.Source, sourceDate: Date, model: String, apiCallID: APICall.ID? = nil, eventID: AgentEvent.ID? = nil,
            taskID: AgentTask.ID? = nil, conversationID: AgentConversation.ID? = nil, trusted: Bool = true
        ) {
            self.source = source
            self.sourceDate = sourceDate
            self.model = model
            self.apiCallID = apiCallID
            self.eventID = eventID
            self.taskID = taskID
            self.conversationID = conversationID
            self.trusted = trusted
        }

        /// Haiku decided it (it may not overrule the student or a stronger source).
        var isHaiku: Bool { model.contains("haiku") }

        var rank: Int { ChangeLog.rank(of: sourceKind) }

        var sourceKind: SourceRef.Kind {
            switch source {
            case .mail: .mail
            case .transcript: .transcript
            case .chat: .chat
            case .external(let kind, _): kind
            }
        }
    }

    /// One change to apply.
    public enum Request: Sendable, Hashable {
        case sessionRoom(LectureSession.ID, room: String)
        case sessionTime(LectureSession.ID, startsAt: Date, endsAt: Date)
        case sessionCancel(LectureSession.ID)
        case sessionRestore(LectureSession.ID)
        case sessionExtra(courseID: Course.ID, kind: SessionKind, startsAt: Date, endsAt: Date, room: String)
        /// A deadline, exercise, exam, event, announcement or task; `dateVerified`: the quote
        /// states its date (only then may it go into the calendar on its own).
        case itemAdd(DeadlineDraft, dateVerified: Bool)
        case itemMove(TrackedItem.ID, due: Date, allDay: Bool, dateVerified: Bool)
        case itemDone(TrackedItem.ID)
        case itemUpdate(TrackedItem.ID, title: String?, details: String?, room: String?, relevance: ItemRelevance?)
        /// A course rule (`kind`), or the lecturers (`professors`).
        case courseFact(Course.ID, kind: CourseRule.Kind?, text: String, professors: [String]?)
        /// Blocks appended to a note (nil: a new note of the course or lecture).
        case noteAppend(noteID: Note.ID?, courseID: Course.ID?, lectureID: Lecture.ID?, blocks: [NoteBlock])
        case reminder(itemID: TrackedItem.ID?, courseID: Course.ID?, title: String, body: String, fireAt: Date)
    }

    /// What `apply` did.
    public enum Outcome: Sendable {
        case applied(AgentChange)
        /// Already so; where it fits, the source was added to the change's item.
        case unchanged(String)
        /// Not applied: a stronger or newer source, or the student's own edit, stands (triage
        /// escalates it; a tool tells the model).
        case conflict(String)
        /// Not applied: invalid (unknown row, nothing to change).
        case refused(String)

        public var change: AgentChange? {
            if case .applied(let change) = self { return change }
            return nil
        }

        /// A readable line for a tool result or a log.
        public var message: String {
            switch self {
            case .applied(let change): "\(change.title): \(change.summary)"
            case .unchanged(let text), .conflict(let text), .refused(let text): text
            }
        }
    }

    let services: StudyServices
    let onChange: @Sendable () async -> Void
    let now: @Sendable () -> Date

    /// `memory`: the app's deadline memory, whose `onChange` syncs the calendar after each write.
    public init(services: StudyServices, memory: DeadlineMemory? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        let memory = memory
        onChange = { await memory?.didChange() }
        self.now = now
    }

    // MARK: - Entry points

    /// Applies one change and writes its log row in one transaction; then the calendar syncs.
    @discardableResult
    public func apply(_ request: Request, quote: String, confidence: Double = 1, origin: Origin) async throws -> Outcome {
        let store = services.records
        let date = now()
        let outcome = try await services.database.write { db in
            try Self.apply(request, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: date)
        }
        if case .applied = outcome { await onChange() }
        return outcome
    }

    /// Undo of one change: the target back from `before`, the item's source undone, reminders
    /// cancelled, `undone_at` stamped. False when it was undone already or is unknown.
    @discardableResult
    public func undo(_ id: AgentChange.ID) async throws -> Bool {
        let store = services.records
        let date = now()
        let undone = try await services.database.write { db in try Self.undo(id, db: db, store: store, now: date) }
        if undone { await onChange() }
        return undone
    }

    /// Undo from an item's popover (or Mail's found row): the change written with that source
    /// through the log; for another source of an applied session change (a second mail or the
    /// lecture saying it again, no change row of its own) the session change's Undo; else the
    /// deadline memory's Undo of the source (M3).
    public func undo(sourceID: TrackedItemSource.ID) async throws {
        let store = services.records
        let date = now()
        try await services.database.write { db in
            if let change = try AgentChange.where({ $0.trackedItemSourceID.eq(TrackedItemSource.ID?.some(sourceID)) })
                .order(by: { $0.appliedAt.desc() }).fetchOne(db) {
                if change.undoneAt == nil { _ = try Self.undo(change.id, db: db, store: store, now: date) }
                return
            }
            if let source = try TrackedItemSource.find(sourceID).fetchOne(db),
               let item = try TrackedItem.find(source.trackedItemID).fetchOne(db),
               item.kind.isSessionChange, let sessionID = item.lectureSessionID {
                let itemID = item.id
                let sources = Set(try TrackedItemSource.where { $0.trackedItemID.eq(itemID) }.fetchAll(db).map(\.id))
                let applied = try AgentChange
                    .where { $0.targetTable.eq(AgentChangeTarget.session) && $0.targetID.eq(UUID?.some(sessionID)) && $0.undoneAt.is(nil) }
                    .order(by: { $0.appliedAt.desc() })
                    .fetchAll(db)
                    .first { $0.trackedItemSourceID.map(sources.contains) == true }
                if let applied { _ = try Self.undo(applied.id, db: db, store: store, now: date) }
            }
            // This source is marked undone too (the item is dismissed already when the change was).
            try DeadlineMemory.undo(sourceID, in: db, store: store, now: date)
        }
        await onChange()
    }

    /// The timetable import's recorder (`TimetableImporter.apply(…, sessionChange:)`): logs a
    /// session the import changed (a meeting the series skips) as a settled cancellation with the
    /// file's words, model "" (code), inside the import's transaction.
    public static func timetableRecorder(store: RecordStore) -> TimetableSessionChangeRecorder {
        { change, db in
            let date = store.currentDate
            let origin = Origin(source: .external(.timetable, reference: change.file), sourceDate: date, model: "")
            _ = try logSession(
                kind: .sessionCancel, before: change.before, after: change.after, quote: change.quote, confidence: 1, origin: origin,
                previous: [], db: db, store: store, now: date
            )
        }
    }

    // MARK: - Applying (in the caller's transaction)

    public static func apply(
        _ request: Request, quote: String, confidence: Double, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .refused("A change needs the exact words it comes from.") }
        let confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
        switch request {
        case .sessionRoom(let id, let room):
            let room = room.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !room.isEmpty else { return .refused("A room is needed.") }
            return try changeSession(id, kind: .sessionRoom, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now) {
                $0.room = room
            }
        case .sessionTime(let id, let startsAt, let endsAt):
            guard endsAt > startsAt else { return .refused("The session must end after it starts.") }
            return try changeSession(id, kind: .sessionTime, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now) {
                $0.startsAt = startsAt
                $0.endsAt = endsAt
            }
        case .sessionCancel(let id):
            return try changeSession(id, kind: .sessionCancel, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now) {
                $0.isCancelled = true
            }
        case .sessionRestore(let id):
            return try changeSession(id, kind: .sessionRestore, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now) {
                $0.isCancelled = false
            }
        case .sessionExtra(let courseID, let kind, let startsAt, let endsAt, let room):
            return try addSession(
                courseID: courseID, kind: kind, startsAt: startsAt, endsAt: endsAt, room: room, quote: quote, confidence: confidence,
                origin: origin, db: db, store: store, now: now
            )
        case .itemAdd(let draft, let verified):
            return try addItem(draft, verified: verified, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        case .itemMove(let id, let due, let allDay, let verified):
            return try changeItem(id, kind: .itemMove, quote: quote, confidence: confidence, origin: origin, verified: verified, db: db, store: store, now: now) {
                $0.dueAt = due
                $0.isAllDay = allDay
            }
        case .itemDone(let id):
            return try completeItem(id, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        case .itemUpdate(let id, let title, let details, let room, let relevance):
            return try changeItem(id, kind: .itemUpdate, quote: quote, confidence: confidence, origin: origin, verified: false, db: db, store: store, now: now) {
                if let title, !title.isEmpty { $0.title = title }
                if let details { $0.details = details }
                if let room { $0.room = room.isEmpty ? nil : room }
                if let relevance { $0.relevance = relevance }
            }
        case .courseFact(let courseID, let kind, let text, let professors):
            return try setFact(courseID, kind: kind, text: text, professors: professors, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        case .noteAppend(let noteID, let courseID, let lectureID, let blocks):
            return try appendNote(noteID, courseID: courseID, lectureID: lectureID, blocks: blocks, quote: quote, origin: origin, db: db, store: store, now: now)
        case .reminder(let itemID, let courseID, let title, let body, let fireAt):
            return try schedule(itemID: itemID, courseID: courseID, title: title, body: body, fireAt: fireAt, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        }
    }

    // MARK: Sessions

    /// Session change kinds that touch the same field (conflicts and supersession).
    static func field(_ kind: AgentChangeKind) -> String? {
        switch kind {
        case .sessionRoom: "room"
        case .sessionTime: "time"
        case .sessionCancel, .sessionRestore: "cancelled"
        default: nil
        }
    }

    static func itemKind(_ kind: AgentChangeKind) -> TrackedItemKind {
        switch kind {
        case .sessionRoom: .roomChange
        case .sessionTime: .timeChange
        case .sessionExtra: .extraSession
        default: .cancellation
        }
    }

    private static func changeSession(
        _ id: LectureSession.ID, kind: AgentChangeKind, quote: String, confidence: Double, origin: Origin, db: Database, store: RecordStore,
        now: Date, edit: (inout LectureSession) -> Void
    ) throws -> Outcome {
        guard let session = try LectureSession.find(id).fetchOne(db) else { return .refused("Unknown session.") }
        var target = session
        edit(&target)
        target.endsAt = max(target.endsAt, target.startsAt)
        if kind == .sessionRestore, !session.isCancelled { return .unchanged("That session is not cancelled.") }
        if AgentChangeValues.session(target) == AgentChangeValues.session(session) {
            // Said again (a second mail, the lecture): the source goes onto the change's item.
            let itemKind = itemKind(kind)
            if let item = try TrackedItem
                .where({ $0.lectureSessionID.eq(LectureSession.ID?.some(id)) && $0.kind.eq(itemKind) && $0.status.eq(TrackedItemStatus.done) })
                .order(by: { $0.createdAt.desc() }).fetchOne(db) {
                try DeadlineMemory.addSource(finding(kind: itemKind, session: session, quote: quote, confidence: confidence, origin: origin), to: item.id, in: db, store: store, now: now)
            }
            return .unchanged("The session is like that already.")
        }
        let field = field(kind)
        let previous = try AgentChange
            .where { $0.targetTable.eq(AgentChangeTarget.session) && $0.targetID.eq(UUID?.some(id)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) }
            .fetchAll(db)
            .filter { field != nil && Self.field($0.kind) == field }
        // Haiku never overrules a stronger or newer source; a careful decision (Opus) may.
        for old in previous where origin.isHaiku {
            guard try outranks(origin, old, db: db) else {
                return .conflict("A \(old.sourceKind.rawValue) source changed this session's \(field ?? "state") already (\(old.summary)); a newer or more authoritative source stands.")
            }
        }
        if origin.isHaiku, try editedByStudent(session, db: db) {
            return .conflict("The student changed this session by hand; only a careful decision may change it.")
        }
        guard let (before, after) = try CourseSchedule.edit(id, now: now, store: store, db: db, edit) else {
            return .refused("Unknown session.")
        }
        return try logSession(kind: kind, before: before, after: after, quote: quote, confidence: confidence, origin: origin, previous: previous, db: db, store: store, now: now)
    }

    private static func addSession(
        courseID: Course.ID, kind: SessionKind, startsAt: Date, endsAt: Date, room: String, quote: String, confidence: Double,
        origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard try Course.find(courseID).fetchOne(db) != nil else { return .refused("Unknown course.") }
        guard endsAt > startsAt else { return .refused("The session must end after it starts.") }
        let from = startsAt.addingTimeInterval(-15 * 60)
        let until = startsAt.addingTimeInterval(15 * 60)
        if let existing = try LectureSession
            .where({ $0.courseID.eq(courseID) && $0.startsAt.gte(from) && $0.startsAt.lte(until) && !$0.isCancelled })
            .fetchOne(db) {
            if let item = try TrackedItem
                .where({ $0.lectureSessionID.eq(LectureSession.ID?.some(existing.id)) && $0.kind.eq(TrackedItemKind.extraSession) })
                .fetchOne(db) {
                try DeadlineMemory.addSource(finding(kind: .extraSession, session: existing, quote: quote, confidence: confidence, origin: origin), to: item.id, in: db, store: store, now: now)
            }
            return .unchanged("The course has a session at that time already.")
        }
        let session = try CourseSchedule.insertSession(
            courseID: courseID, kind: kind, startsAt: startsAt, endsAt: endsAt, room: room, now: now, store: store, db: db
        )
        return try logSession(kind: .sessionExtra, before: nil, after: session, quote: quote, confidence: confidence, origin: origin, previous: [], db: db, store: store, now: now, created: true)
    }

    /// Writes the settled session-change item, its source and the change row for a session edit
    /// already made (`before` nil: the change created the session).
    static func logSession(
        kind: AgentChangeKind, before: LectureSession?, after: LectureSession, quote: String, confidence: Double, origin: Origin,
        previous: [AgentChange], db: Database, store: RecordStore, now: Date, created: Bool = false
    ) throws -> Outcome {
        let itemKind = itemKind(kind)
        let course = try Course.find(after.courseID).fetchOne(db)
        let name = SessionText.title(of: after, courseName: course?.name ?? "", shortName: course?.shortName ?? "")
        let summary: String
        let itemTitle: String
        switch kind {
        case .sessionRoom:
            summary = "Moved to \(after.room) · \(ChangeSummary.day(after.startsAt))"
            itemTitle = "Moved to \(after.room)"
        case .sessionTime:
            summary = "Moved to " + ChangeSummary.dayTime(after.startsAt)
            itemTitle = summary
        case .sessionRestore:
            summary = "Restored"
            itemTitle = "Restored"
        case .sessionExtra:
            summary = "Extra session · " + ChangeSummary.dayTime(after.startsAt)
            itemTitle = "Extra session"
        default:
            summary = "Cancelled · " + ChangeSummary.day(after.startsAt)
            itemTitle = "Cancelled"
        }
        let finding = finding(kind: itemKind, session: after, quote: quote, confidence: confidence, origin: origin)
        let recorded = try DeadlineMemory.recordSessionChange(
            kind: itemKind, session: after, title: itemTitle, room: kind == .sessionRoom || kind == .sessionExtra ? after.room : nil,
            finding: finding, in: db, store: store, now: now
        )
        var change = AgentChange(
            kind: kind, targetTable: .session, targetID: after.id, title: name, summary: summary,
            before: before.map(AgentChangeValues.session) ?? AgentChangeValues(exists: false),
            after: AgentChangeValues.session(after), sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID,
            quote: quote, confidence: confidence, model: origin.model, apiCallID: origin.apiCallID,
            trackedItemSourceID: recorded.source?.id, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        let stamped = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(stamped, db: db)
        for old in previous { try AgentChangeRepository.supersede(old.id, by: stamped.id, at: now, db: db) }
        return .applied(stamped)
    }

    /// The row as written: the origin's conversation and task, stamped.
    static func finalize(_ change: AgentChange, origin: Origin, store: RecordStore) -> AgentChange {
        var change = change
        if change.conversationID == nil { change.conversationID = origin.conversationID }
        if change.taskID == nil { change.taskID = origin.taskID }
        if change.eventID == nil { change.eventID = origin.eventID }
        return store.stamp(change)
    }

    static func finding(kind: TrackedItemKind, session: LectureSession, quote: String, confidence: Double, origin: Origin) -> ItemFinding {
        ItemFinding(
            draft: DeadlineDraft(kind: kind, title: kind.rawValue, courseID: session.courseID, dueAt: session.startsAt, lectureSessionID: session.id),
            source: origin.source, quote: quote, confidence: confidence, dateVerified: true, trusted: origin.trusted, createdBy: .agent,
            apiCallID: origin.apiCallID
        )
    }

    /// A session the student changed by hand: `edited_at` set and no change of the log (applied
    /// or undone) made that edit. (Generated sessions have no `edited_at`.)
    static func editedByStudent(_ session: LectureSession, db: Database) throws -> Bool {
        guard let edited = session.editedAt, session.weeklySlotID != nil else { return false }
        let id = session.id
        let changes = try AgentChange
            .where { $0.targetTable.eq(AgentChangeTarget.session) && $0.targetID.eq(UUID?.some(id)) }
            .fetchAll(db)
        return !changes.contains { change in
            abs(change.appliedAt.timeIntervalSince(edited)) < 2 || change.undoneAt.map { abs($0.timeIntervalSince(edited)) < 2 } == true
        }
    }

    // MARK: Conflicts

    /// The student's words > mail > the lecture > a timetable file > a calendar edit elsewhere.
    static func rank(of kind: SourceRef.Kind) -> Int {
        switch kind {
        case .chat: 5
        case .mail: 4
        case .transcript: 3
        case .timetable: 2
        default: 1
        }
    }

    /// Whether a change from `origin` may replace `old` (the same target and field).
    static func outranks(_ origin: Origin, _ old: AgentChange, db: Database) throws -> Bool {
        let oldRank = rank(of: old.sourceKind)
        if origin.rank != oldRank { return origin.rank > oldRank }
        return origin.sourceDate >= (try sourceDate(of: old, db: db))
    }

    /// When the source of a logged change said it: a mail's Date, the class's time, else when it
    /// was applied.
    static func sourceDate(of change: AgentChange, db: Database) throws -> Date {
        if let id = change.mailMessageID, let mail = try MailMessage.find(id).fetchOne(db) { return mail.sentAt ?? mail.receivedAt }
        if let id = change.lectureID, let lecture = try Lecture.find(id).fetchOne(db), let held = lecture.heldAt {
            return held.addingTimeInterval(change.time ?? 0)
        }
        return change.appliedAt
    }

    // MARK: Items

    private static func addItem(
        _ draft: DeadlineDraft, verified: Bool, quote: String, confidence: Double, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return .refused("A title is needed.") }
        let finding = ItemFinding(
            draft: draft, source: origin.source, quote: quote, confidence: confidence, dateVerified: verified, trusted: origin.trusted,
            createdBy: .agent, apiCallID: origin.apiCallID
        )
        let result = try DeadlineMemory.record(finding, in: db, store: store, now: now)
        guard var change = ItemChangeRows.change(
            for: result, finding: finding, model: origin.model, eventID: origin.eventID, taskID: origin.taskID, now: now
        ) else { return .unchanged("\(result.item.title) is listed already.") }
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    private static func changeItem(
        _ id: TrackedItem.ID, kind: AgentChangeKind, quote: String, confidence: Double, origin: Origin, verified: Bool, db: Database,
        store: RecordStore, now: Date, edit: (inout DeadlineDraft) -> Void
    ) throws -> Outcome {
        guard let item = try TrackedItem.find(id).fetchOne(db) else { return .refused("Unknown item.") }
        guard !item.kind.isSessionChange else { return .refused("Session changes are changed through their session.") }
        if origin.isHaiku, item.createdBy == .user {
            return .conflict("The student wrote this item themselves; only a careful decision may change it.")
        }
        if origin.isHaiku, item.kind == .exam, kind == .itemMove {
            return .conflict("Moving an exam is decided carefully, not by triage.")
        }
        var draft = DeadlineDraft(
            kind: item.kind, title: item.title, details: item.details, courseID: item.courseID, dueAt: item.dueAt, isAllDay: item.isAllDay,
            relevance: item.relevance, room: item.room, lectureSessionID: item.lectureSessionID
        )
        edit(&draft)
        let previous = try AgentChange
            .where { $0.targetTable.eq(AgentChangeTarget.item) && $0.targetID.eq(UUID?.some(id)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) && $0.kind.eq(kind) }
            .fetchAll(db)
        for old in previous where origin.isHaiku {
            guard try outranks(origin, old, db: db) else {
                return .conflict("A \(old.sourceKind.rawValue) source changed this item already (\(old.summary)); a newer or more authoritative source stands.")
            }
        }
        let finding = ItemFinding(
            draft: draft, source: origin.source, quote: quote, confidence: confidence, dateVerified: verified, trusted: origin.trusted,
            createdBy: .agent, apiCallID: origin.apiCallID
        )
        guard let (updated, source) = try DeadlineMemory.update(id, to: draft, by: finding, in: db, store: store, now: now) else {
            return .refused("Unknown item.")
        }
        guard let source else { return .unchanged("\(item.title) is like that already.") }
        let summary = kind == .itemMove ? "Moved to " + (updated.dueAt.map { ChangeSummary.dayTime($0, allDay: updated.isAllDay) } ?? "no date") : "Updated"
        var change = ItemChangeRows.row(
            kind: kind, item: updated, summary: summary, before: AgentChangeValues(exists: true, item: TrackedItemSnapshot(item)),
            finding: finding, source: source, model: origin.model, eventID: origin.eventID, taskID: origin.taskID, now: now
        )
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        for old in previous { try AgentChangeRepository.supersede(old.id, by: change.id, at: now, db: db) }
        // Reminders planned for the old date never fire (the automatic ones are planned again).
        if kind == .itemMove { try cancelReminders(itemID: id, db: db, now: now) }
        return .applied(change)
    }

    private static func completeItem(
        _ id: TrackedItem.ID, quote: String, confidence: Double, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard let item = try TrackedItem.find(id).fetchOne(db) else { return .refused("Unknown item.") }
        guard !item.kind.isSessionChange else { return .refused("Session changes are settled already.") }
        guard item.status != .done else { return .unchanged("\(item.title) is done already.") }
        if origin.isHaiku, item.createdBy == .user { return .conflict("The student wrote this item themselves.") }
        let finding = ItemFinding(
            draft: DeadlineDraft(kind: item.kind, title: item.title, courseID: item.courseID, dueAt: item.dueAt, isAllDay: item.isAllDay),
            source: origin.source, quote: quote, confidence: confidence, dateVerified: false, trusted: origin.trusted, createdBy: .agent,
            apiCallID: origin.apiCallID
        )
        guard let (done, source) = try DeadlineMemory.complete(id, by: finding, in: db, store: store, now: now), let source else {
            return .unchanged("\(item.title) is done already.")
        }
        var change = ItemChangeRows.row(
            kind: .itemDone, item: done, summary: "Done", before: AgentChangeValues(exists: true, item: TrackedItemSnapshot(item)),
            finding: finding, source: source, model: origin.model, eventID: origin.eventID, taskID: origin.taskID, now: now
        )
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        // A done item needs no reminder any more.
        try cancelReminders(itemID: id, db: db, now: now)
        return .applied(change)
    }

    // MARK: Course facts

    static func ruleTitle(_ kind: CourseRule.Kind) -> String {
        switch kind {
        case .examAdmission: "Exam admission"
        case .examForm: "Exam"
        case .bonus: "Bonus"
        case .exercise: "Exercises"
        case .attendance: "Attendance"
        default: "Note"
        }
    }

    private static func setFact(
        _ courseID: Course.ID, kind: CourseRule.Kind?, text: String, professors: [String]?, quote: String, confidence: Double,
        origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard var course = try Course.find(courseID).fetchOne(db) else { return .refused("Unknown course.") }
        let before = AgentChangeValues(exists: true, professors: course.professors, rules: course.rules)
        let summary: String
        if let professors {
            let names = professors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !names.isEmpty else { return .refused("No lecturers given.") }
            guard names != course.professors else { return .unchanged("The course has these lecturers already.") }
            course.professors = names
            summary = "Lecturers: " + names.joined(separator: "; ")
        } else {
            let kind = kind ?? .other
            let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
            guard !text.isEmpty else { return .refused("The fact's text is empty.") }
            var source = SourceRef(kind: origin.sourceKind, quote: quote)
            switch origin.source {
            case .mail(_, let rfcMessageID): source.mailMessageID = rfcMessageID
            case .transcript(let lectureID, let recordingID, let time):
                source.lectureID = lectureID
                source.recordingID = recordingID
                source.time = time
            default: break
            }
            let rule = CourseRule(kind: kind, title: ruleTitle(kind), text: text, provenance: .ai, source: source, confirmedAt: now)
            if let index = course.rules.firstIndex(where: { $0.kind == kind && kind != .other }) {
                if origin.isHaiku, course.rules[index].provenance == .user {
                    return .conflict("The student wrote this course rule themselves.")
                }
                guard TextFolding.fold(course.rules[index].text) != TextFolding.fold(text) else {
                    return .unchanged("The course says that already.")
                }
                course.rules[index] = CourseRule(
                    id: course.rules[index].id, kind: kind, title: course.rules[index].title, text: text, provenance: .ai, source: source,
                    confirmedAt: now
                )
            } else {
                course.rules.append(rule)
            }
            summary = "\(ruleTitle(kind)): \(text)"
        }
        let stamped = store.stamp(course)
        try Course.upsert { stamped }.execute(db)
        var change = AgentChange(
            kind: .courseFact, targetTable: .course, targetID: courseID, title: course.name, summary: summary, before: before,
            after: AgentChangeValues(exists: true, professors: stamped.professors, rules: stamped.rules), sourceKind: origin.sourceKind,
            taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: confidence, model: origin.model,
            apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    // MARK: Notes

    /// A note's name: its first block when that is a title, else its first line.
    static func noteTitle(_ blocks: [NoteBlock]) -> String {
        let text = blocks.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text ?? "Note"
        return String(text.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(80) ?? "Note")
    }

    private static func appendNote(
        _ noteID: Note.ID?, courseID: Course.ID?, lectureID: Lecture.ID?, blocks: [NoteBlock], quote: String, origin: Origin,
        db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard !blocks.isEmpty else { return .refused("Nothing to append.") }
        var note: Note
        var created = false
        var existing: [NoteBlock] = []
        if let noteID {
            guard let found = try Note.find(noteID).fetchOne(db) else { return .refused("Unknown note.") }
            note = found
            // Never written when the note's body cannot be read (it would replace it).
            if !found.blocksJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { existing = try NoteBlock.decode(found.blocksJSON) } catch { return .refused("The note could not be read.") }
            }
        } else {
            var course = courseID
            if course == nil, let lectureID { course = try Lecture.find(lectureID).fetchOne(db)?.courseID }
            note = Note(courseID: course, lectureID: lectureID, createdAt: now, updatedAt: now)
            created = true
        }
        note.blocksJSON = NoteBlock.json(existing + blocks)
        let stamped = store.stamp(note)
        try Note.upsert { stamped }.execute(db)
        var change = AgentChange(
            kind: .noteAppend, targetTable: .note, targetID: stamped.id, title: noteTitle(existing.isEmpty ? blocks : existing),
            summary: "Added to notes", before: AgentChangeValues(exists: !created),
            after: AgentChangeValues(exists: true, noteBlocks: blocks, noteCreated: created), sourceKind: origin.sourceKind,
            taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1, model: origin.model, apiCallID: origin.apiCallID,
            appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    // MARK: Reminders

    private static func schedule(
        itemID: TrackedItem.ID?, courseID: Course.ID?, title: String, body: String, fireAt: Date, quote: String, confidence: Double,
        origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard fireAt > now else { return .refused("A reminder must be in the future.") }
        if let itemID {
            let open = try AgentReminder
                .where { $0.trackedItemID.eq(TrackedItem.ID?.some(itemID)) && $0.cancelledAt.is(nil) && $0.deliveredAt.is(nil) }
                .fetchAll(db)
            if open.contains(where: { abs($0.fireAt.timeIntervalSince(fireAt)) < 60 }) { return .unchanged("That reminder is set already.") }
        }
        let reminder = store.stamp(AgentReminder(
            title: title, body: body, fireAt: fireAt, trackedItemID: itemID, courseID: courseID, createdBy: .agent, createdAt: now, updatedAt: now
        ))
        try AgentReminder.upsert { reminder }.execute(db)
        var change = AgentChange(
            kind: .reminder, targetTable: .reminder, targetID: reminder.id, title: reminder.title,
            summary: "Reminder · " + ChangeSummary.dayTime(fireAt), before: AgentChangeValues(exists: false),
            after: AgentChangeValues(exists: true, fireAt: fireAt), sourceKind: origin.sourceKind, taskID: origin.taskID,
            eventID: origin.eventID, quote: quote, confidence: confidence, model: origin.model, apiCallID: origin.apiCallID,
            appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        return .applied(change)
    }

    static func cancelReminders(itemID: TrackedItem.ID, db: Database, now: Date) throws {
        try AgentReminder
            .where { $0.trackedItemID.eq(TrackedItem.ID?.some(itemID)) && $0.cancelledAt.is(nil) && $0.deliveredAt.is(nil) }
            .update { $0.cancelledAt = Date?.some(now); $0.updatedAt = now }
            .execute(db)
    }

    // MARK: - Undo

    /// Undo inside the caller's transaction.
    static func undo(_ id: AgentChange.ID, db: Database, store: RecordStore, now: Date) throws -> Bool {
        guard let change = try AgentChange.find(id).fetchOne(db), change.undoneAt == nil else { return false }
        // A newer change of the same target and field replaced this one: its effect is gone
        // already, only the row is marked.
        let current: Bool
        if let newer = change.supersededBy, let row = try AgentChange.find(newer).fetchOne(db) {
            current = row.undoneAt != nil
        } else {
            current = true
        }
        switch change.targetTable {
        case .session:
            if current, let targetID = change.targetID {
                if let before = change.before, before.exists != false {
                    // Only the field(s) of the change's kind, and only while the session still has
                    // what the change wrote (a later change of another field, or the student's
                    // own edit, stays).
                    if let session = try LectureSession.find(targetID).fetchOne(db),
                       let restore = sessionRestore(change.kind, before: before, after: change.after, session: session) {
                        _ = try CourseSchedule.edit(targetID, now: now, store: store, db: db, restore)
                    }
                } else {
                    // The change added this session: it does not take place (nothing is deleted).
                    _ = try CourseSchedule.edit(targetID, now: now, store: store, db: db) { $0.isCancelled = true }
                }
            }
            if let sourceID = change.trackedItemSourceID { try DeadlineMemory.undo(sourceID, in: db, store: store, now: now) }
        case .item:
            if let sourceID = change.trackedItemSourceID {
                if current {
                    try DeadlineMemory.undo(sourceID, in: db, store: store, now: now)
                } else {
                    // A newer change of the same field stands: the item keeps it; only this
                    // source is marked undone (with what it had made, for Restore).
                    try DeadlineMemory.retire(sourceID, made: change.after?.item, in: db, store: store, now: now)
                }
            }
            if current, change.kind == .itemAdd || change.kind == .itemMove, let itemID = change.targetID {
                try cancelReminders(itemID: itemID, db: db, now: now)
            }
        case .course:
            if current, let targetID = change.targetID, var course = try Course.find(targetID).fetchOne(db),
               let before = change.before, let after = change.after {
                if restoreFact(before: before, after: after, in: &course) {
                    let stamped = store.stamp(course)
                    try Course.upsert { stamped }.execute(db)
                }
            }
        case .memory:
            if let targetID = change.targetID, var memory = try AgentMemory.find(targetID).fetchOne(db) {
                if change.before?.exists == false {
                    memory.forgottenAt = now
                } else {
                    if let text = change.before?.memoryText { memory.text = text }
                    if change.before?.forgotten == false { memory.forgottenAt = nil }
                }
                let stamped = store.stamp(memory)
                try AgentMemory.upsert { stamped }.execute(db)
            }
        case .note:
            if let targetID = change.targetID, var note = try Note.find(targetID).fetchOne(db), let appended = change.after?.noteBlocks {
                var blocks = (try? NoteBlock.decode(note.blocksJSON)) ?? []
                // Only while the appended blocks are unchanged at the end of the note.
                if blocks.count >= appended.count, Array(blocks.suffix(appended.count)) == appended {
                    blocks.removeLast(appended.count)
                    if blocks.isEmpty, change.after?.noteCreated == true {
                        try Note.find(targetID).delete().execute(db)
                    } else {
                        note.blocksJSON = NoteBlock.json(blocks)
                        let stamped = store.stamp(note)
                        try Note.upsert { stamped }.execute(db)
                    }
                }
            }
        case .reminder:
            if let targetID = change.targetID {
                try AgentReminder.where { $0.id.eq(targetID) && $0.cancelledAt.is(nil) }
                    .update { $0.cancelledAt = Date?.some(now); $0.updatedAt = now }
                    .execute(db)
            }
        default:
            break
        }
        // The changes this one had replaced stand again.
        try AgentChange.where { $0.supersededBy.eq(AgentChange.ID?.some(id)) }
            .update { $0.supersededBy = AgentChange.ID?.none; $0.updatedAt = now }
            .execute(db)
        try AgentChangeRepository.markUndone(id, at: now, db: db)
        return true
    }

    /// What Undo of a session change of `kind` writes back: the room, the times or the
    /// cancellation from `before`, only while `session` still holds `after`'s value of that field.
    /// Nil: nothing to put back.
    static func sessionRestore(
        _ kind: AgentChangeKind, before: AgentChangeValues, after: AgentChangeValues?, session: LectureSession
    ) -> ((inout LectureSession) -> Void)? {
        func same(_ lhs: Date, _ rhs: Date?) -> Bool { rhs.map { abs(lhs.timeIntervalSince($0)) < 1 } ?? false }
        switch kind {
        case .sessionRoom:
            guard let room = before.room, session.room == after?.room else { return nil }
            return { $0.room = room }
        case .sessionTime:
            guard let startsAt = before.startsAt, let endsAt = before.endsAt,
                  same(session.startsAt, after?.startsAt), same(session.endsAt, after?.endsAt) else { return nil }
            return { session in
                session.startsAt = startsAt
                session.endsAt = endsAt
            }
        case .sessionCancel, .sessionRestore:
            guard let cancelled = before.isCancelled, session.isCancelled == after?.isCancelled else { return nil }
            return { $0.isCancelled = cancelled }
        default:
            return nil
        }
    }

    /// Undo of a course fact: the one rule the change set goes back to its version before (or is
    /// removed when the change added it), or the lecturers go back; only while the course still
    /// holds what the change wrote. Every other rule stays. False: nothing to write.
    static func restoreFact(before: AgentChangeValues, after: AgentChangeValues, in course: inout Course) -> Bool {
        func same(_ lhs: CourseRule, _ rhs: CourseRule) -> Bool {
            lhs.id == rhs.id && lhs.kind == rhs.kind && lhs.text == rhs.text && lhs.provenance == rhs.provenance
        }
        if let old = before.professors, let new = after.professors, old != new {
            guard course.professors == new else { return false }
            course.professors = old
            return true
        }
        let oldRules = before.rules ?? []
        guard let set = (after.rules ?? []).first(where: { rule in !oldRules.contains { same($0, rule) } }),
              let index = course.rules.firstIndex(where: { $0.id == set.id }), same(course.rules[index], set)
        else { return false }
        if let previous = oldRules.first(where: { $0.id == set.id }) {
            course.rules[index] = previous
        } else {
            course.rules.remove(at: index)
        }
        return true
    }
}
