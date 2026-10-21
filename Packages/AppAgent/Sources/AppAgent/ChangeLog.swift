import Courses
import Deadlines
import Documents
import Filing
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
        /// mc: a course's credits and/or self-study hours (`set_course_credits`; nil leaves a value).
        case courseCredits(Course.ID, credits: Double?, selfStudyHours: Double?)
        /// mc: a planner rule kept as a `plan` memory (`mark_away_days`, `plan_adjust`). An older
        /// plan memory of the same scope (another cap for the same days, another sitting of the
        /// course…) is forgotten and its change superseded (Undo brings it back).
        case planRule(PlanRule, text: String, courseID: Course.ID?)
        /// mc: a planned block moved to another day (`plan_adjust` move): the row itself,
        /// `created_by = user` (a replan never moves or drops it), at the end of that day.
        case planMove(StudyBlock.ID, to: CalendarDay)
        /// A new course (`add_course`), created as New Course… creates one (`CourseLibrary.insert`).
        case courseAdd(CourseDraft)
        /// A new weekly slot (`add_weekly_slot`), saved as Course Settings' Add Slot saves one
        /// (`CourseSchedule.saveSlot`): its sessions are planned and mirrored to the calendar.
        case slotAdd(WeeklySlot)
        /// A weekly slot's new values (`change_weekly_slot`, the same id).
        case slotChange(WeeklySlot)
        /// A weekly slot removed (`remove_weekly_slot`, `CourseSchedule.deleteSlot`).
        case slotRemove(WeeklySlot.ID)
        /// mr: a lecture's page range of a deck made or changed (`link_deck_pages`,
        /// `LectureSlides.link`; other lectures' ranges of the deck stay).
        case deckLink(lectureID: Lecture.ID, deckID: Deck.ID, firstPage: Int, lastPage: Int)
        /// mr: a lecture's link to a deck removed (`unlink_deck`, `LectureSlides.unlink`; the deck stays).
        case deckUnlink(lectureID: Lecture.ID, deckID: Deck.ID)
        /// oss: the university profile as it is to be, and the semester row as it is to be (nil:
        /// unchanged), from `set_profile` (`ProfileTools.swift`).
        case profile(UniversityProfile, semester: Semester?)
        /// ln: the student's length for lecture notes, kept as a `preference` memory with its
        /// `notes_rule` (`set_notes_length`); the older rule of the same scope is forgotten.
        case notesRule(NotesRule, text: String)
        /// ln: an answer kept on a lecture's notes (`keep_notes_answer`): the mark as it is to be.
        case notesAnswer(LectureNotesMark)
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

    /// Why Undo did nothing: the target changed since the change (a later change replaced it,
    /// or the student edited it); undoing would overwrite that.
    public enum UndoRefused: Error, Sendable, CustomStringConvertible, LocalizedError {
        case changedSince
        /// Undo of `add_course`: the course holds more than it was made with now (lectures,
        /// slides, notes, dates, memories, study work, edits; Delete Course… asks first).
        case holdsWork

        public var description: String {
            switch self {
            case .changedSince: "Changed since; nothing undone."
            case .holdsWork:
                "The course holds more than it was made with now (lectures, slides, notes, dates, memories, study work or edits); "
                    + "nothing undone. Delete Course… in its sidebar menu removes it."
            }
        }

        public var errorDescription: String? {
            switch self {
            case .changedSince: String(localized: "Changed since; nothing undone.")
            case .holdsWork: String(localized: "The course holds more than it was made with now; nothing undone.")
            }
        }
    }

    let services: StudyServices
    let onChange: @Sendable () async -> Void
    /// Smart import, for Undo of the filing advisor's changes (nil: a service of its own).
    let filing: FilingService?
    /// md: the app's document bank, for Undo of `keep_document` (it stops reading the document;
    /// nil: a bank of its own).
    let documents: DocumentBank?
    /// mr: wakes the lecture processor after a change or its Undo queued `align` jobs (a deck
    /// linked, unlinked or put back).
    let wakeProcessing: @Sendable () async -> Void
    let now: @Sendable () -> Date

    /// `memory`: the app's deadline memory, whose `onChange` syncs the calendar after each write.
    /// `filing`: the app's smart import (its Undo wakes the processor for re-alignment).
    /// `documents` (md): the app's document bank. `wakeProcessing` (mr): the processor's `wake()`.
    public init(
        services: StudyServices, memory: DeadlineMemory? = nil, filing: FilingService? = nil, documents: DocumentBank? = nil,
        wakeProcessing: @escaping @Sendable () async -> Void = {}, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        let memory = memory
        onChange = { await memory?.didChange() }
        self.filing = filing
        self.documents = documents
        self.wakeProcessing = wakeProcessing
        self.now = now
    }

    // MARK: - Entry points

    /// Applies one change and writes its log row in one transaction; then the calendar syncs.
    @discardableResult
    public func apply(_ request: Request, quote: String, confidence: Double = 1, origin: Origin) async throws -> Outcome {
        let store = services.records
        let date = now()
        let result: (outcome: Outcome, jobs: [Job]) = try await services.database.write { db in
            try Self.applyQueuing(request, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: date)
        }
        if case .applied = result.outcome { await onChange() }
        // mr: a deck change queued alignment of the lecture's recordings.
        if !result.jobs.isEmpty { await wakeProcessing() }
        return result.outcome
    }

    /// Undo of one change: the target back from `before`, the item's source undone, reminders
    /// cancelled, `undone_at` stamped. False when it was undone already or is unknown.
    @discardableResult
    public func undo(_ id: AgentChange.ID) async throws -> Bool {
        let store = services.records
        let date = now()
        if let change = try await store.fetch(AgentChange.self, id: id) {
            if change.kind == .lectureMerge { return try await undoLectureMerge(change) }
            if change.targetTable == .filing { return try await undoFiling(change, at: date) }
            if change.targetTable == .deckSpan { return try await undoDeckLink(id, at: date) }
            if change.kind == .courseRemove { return try await undoCourseRemoval(change, at: date) }
            if change.kind == .courseAdd { return try await undoCourseAdd(change, at: date) }
            if change.kind == .documentAdd { return try await undoDocumentAdd(change, at: date) }
            // ln: a version of a lecture's notes the agent queued.
            if change.targetTable == .lectureNotes { return try await undoLectureNotes(change, at: date) }
        }
        let undone = try await services.database.write { db in try Self.undo(id, db: db, store: store, now: date) }
        if undone { await onChange() }
        return undone
    }

    /// `remove_course` (the student asked in chat): deletes the course with everything that
    /// belongs to it through smart import's delete (the student's notes stay, unlinked) and logs it
    /// with the deleted rows in `before.deletion`, so Undo puts it all back, in a later session too
    /// (the course's files are kept for that).
    public func removeCourse(_ courseID: Course.ID, quote: String, origin: Origin) async throws -> Outcome {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .refused("A change needs the exact words it comes from.") }
        let service = filing ?? FilingService(services: services)
        let deletion: Deletion
        do {
            deletion = try await service.delete(.course(courseID), keepsFiles: true)
        } catch FilingError.missing {
            return .refused("No course has that token.")
        }
        let store = services.records
        let date = now()
        do {
            var change = AgentChange(
                kind: .courseRemove, targetTable: .course, targetID: courseID, title: deletion.summary.title, summary: "Removed course",
                before: AgentChangeValues(exists: true, deletion: try deletion.encoded()), after: AgentChangeValues(exists: false),
                sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1,
                model: origin.model, apiCallID: origin.apiCallID, appliedAt: date, createdAt: date, updatedAt: date
            )
            ItemChangeRows.apply(origin.source, to: &change)
            change = Self.finalize(change, origin: origin, store: store)
            let row = change
            try await services.database.write { db in try AgentChangeRepository.insert(row, db: db) }
            await onChange()
            return .applied(change)
        } catch {
            // Not logged: not removed either (no change without its Undo).
            try await service.restore(deletion)
            throw error
        }
    }

    /// Undo of `remove_course`: the course and everything that went with it come back from the
    /// rows the change kept (the notes it unlinked are linked again), then the row is marked.
    private func undoCourseRemoval(_ change: AgentChange, at date: Date) async throws -> Bool {
        guard change.undoneAt == nil else { return false }
        guard let kept = change.before?.deletion else { throw UndoRefused.changedSince }
        let deletion = try Deletion(encoded: kept)
        try await (filing ?? FilingService(services: services)).restore(deletion)
        let id = change.id
        try await services.database.write { db in try AgentChangeRepository.markUndone(id, at: date, db: db) }
        await onChange()
        return true
    }

    /// Two lectures the student named merged into one (`merge_lectures`, they asked in chat):
    /// smart import moves what the student or filing put in the one that goes into the one that
    /// stays (`keep`, else the one filed to the lecture session), with its `lecture_merge` row in
    /// the same transaction. Refused: a lecture gone, the same lecture twice, two courses, a
    /// recording of theirs being processed, or both with recordings unless `bothRecorded` (the
    /// student's words say so).
    public func mergeLectures(
        _ first: Lecture.ID, _ second: Lecture.ID, keep: Lecture.ID?, bothRecorded: Bool, quote: String, origin: Origin
    ) async throws -> Outcome {
        let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return .refused("A change needs the exact words it comes from.") }
        let service = filing ?? FilingService(services: services)
        let outcome: LectureMergeOutcome
        do {
            outcome = try await service.mergeLectures(
                first, second, keep: keep, bothRecorded: bothRecorded, quote: quote, sourceKind: origin.sourceKind, model: origin.model,
                conversationID: origin.conversationID, taskID: origin.taskID
            )
        } catch let refusal as LectureMergeRefusal {
            switch refusal {
            case .missing: return .refused("A lecture is gone. Use list_lectures.")
            case .sameLecture: return .refused("Those are one lecture.")
            case .otherCourses: return .refused("The two lectures belong to different courses; only lectures of one course merge.")
            case .bothRecorded(let left, let right):
                return .refused(
                    "Both lectures have recordings (\(left) and \(right)). Merge them only when the student's words ask to merge lectures that both have recordings (both_recorded: true); a single recording moves with Change… on its filing."
                )
            case .busy: return .unchanged("A recording of those lectures is being processed; ask again when it is done.")
            }
        }
        guard let change = outcome.change else { return .unchanged("Nothing was merged.") }
        await wakeProcessing()
        return .applied(change)
    }

    /// Undo of `lecture_merge`: smart import splits the lectures again and marks the row, in one
    /// transaction. Refused when a lecture that kept the meeting is gone since.
    private func undoLectureMerge(_ change: AgentChange) async throws -> Bool {
        guard change.undoneAt == nil else { return false }
        let undone: Bool
        do {
            undone = try await (filing ?? FilingService(services: services)).undoMerge(change)
        } catch FilingError.changedSince {
            throw UndoRefused.changedSince
        }
        if undone { await wakeProcessing() }
        return undone
    }

    /// Undo of a deck the filing advisor filed or moved: smart import puts the filing back (or
    /// takes a deck filed from the panel back), then the row is marked. Refused when the filing
    /// moved since (`UndoRefused.changedSince`).
    private func undoFiling(_ change: AgentChange, at date: Date) async throws -> Bool {
        guard change.undoneAt == nil else { return false }
        guard change.supersededBy == nil else { throw UndoRefused.changedSince }
        let service = filing ?? FilingService(services: services)
        do {
            try await service.undoAdvice(change)
        } catch FilingError.changedSince {
            throw UndoRefused.changedSince
        }
        let id = change.id
        try await services.database.write { db in try AgentChangeRepository.markUndone(id, at: date, db: db) }
        return true
    }

    /// mr: Undo of a `deck_link` / `deck_unlink` change (the agent's or continuation detection's):
    /// `LectureSlides.undo` and the row marked in one transaction; the processor wakes when it
    /// queued alignment. `UndoRefused.changedSince` when the link changed since.
    private func undoDeckLink(_ id: AgentChange.ID, at date: Date) async throws -> Bool {
        let store = services.records
        let result: (undone: Bool, jobs: [Job]) = try await services.database.write { db -> (undone: Bool, jobs: [Job]) in
            guard let change = try AgentChange.find(id).fetchOne(db), change.undoneAt == nil else { return (false, []) }
            let jobs = try Self.undoDeckLink(change, db: db, store: store, now: date)
            try AgentChangeRepository.markUndone(id, at: date, db: db)
            return (true, jobs)
        }
        if !result.jobs.isEmpty { await wakeProcessing() }
        return result.undone
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
        case .courseCredits(let courseID, let credits, let selfStudyHours):
            return try setCredits(courseID, credits: credits, selfStudyHours: selfStudyHours, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        case .planRule(let rule, let text, let courseID):
            return try rememberRule(rule, text: text, courseID: courseID, quote: quote, origin: origin, db: db, store: store, now: now)
        case .planMove(let blockID, let day):
            return try moveBlock(blockID, to: day, quote: quote, origin: origin, db: db, store: store, now: now)
        case .courseAdd(let draft):
            return try addCourse(draft, quote: quote, origin: origin, db: db, store: store, now: now)
        case .slotAdd(let slot):
            return try addSlot(slot, quote: quote, origin: origin, db: db, store: store, now: now)
        case .slotChange(let slot):
            return try changeSlot(slot, quote: quote, origin: origin, db: db, store: store, now: now)
        case .slotRemove(let id):
            return try removeSlot(id, quote: quote, origin: origin, db: db, store: store, now: now)
        case .deckLink, .deckUnlink:
            return try applyDeck(request, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now).outcome
        case .profile(let profile, let semester):
            return try setProfile(profile, semester: semester, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        case .notesRule(let rule, let text):
            return try rememberNotesRule(rule, text: text, quote: quote, origin: origin, db: db, store: store, now: now)
        case .notesAnswer(let mark):
            return try keepNotesAnswer(mark, quote: quote, origin: origin, db: db, store: store, now: now)
        }
    }

    /// `apply` with the `align` jobs a deck change queued (the instance then wakes the processor).
    static func applyQueuing(
        _ request: Request, quote: String, confidence: Double, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> (outcome: Outcome, jobs: [Job]) {
        switch request {
        case .deckLink, .deckUnlink:
            let quote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { return (.refused("A change needs the exact words it comes from."), []) }
            let confidence = min(max(confidence.isFinite ? confidence : 0, 0), 1)
            return try applyDeck(request, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
        default:
            let outcome = try apply(request, quote: quote, confidence: confidence, origin: origin, db: db, store: store, now: now)
            return (outcome, [])
        }
    }

    // MARK: Decks (mr)

    /// A deck link or unlink through `LectureSlides` with its change row (kind `deck_link` /
    /// `deck_unlink`, target the coarse span, `lecture_id` the lecture) and the origin's columns,
    /// in the caller's transaction. Already so: `.unchanged("Already uses …")`; a `DeckLinkError`
    /// (unknown lecture or deck, another course's deck, pages outside the deck, not linked):
    /// `.refused` with its sentence, nothing written.
    static func applyDeck(
        _ request: Request, quote: String, confidence: Double, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> (outcome: Outcome, jobs: [Job]) {
        let result: DeckLinkResult
        do {
            switch request {
            case .deckLink(let lectureID, let deckID, let firstPage, let lastPage):
                result = try LectureSlides.link(
                    lectureID: lectureID, deckID: deckID, firstPage: firstPage, lastPage: lastPage, source: .manual, confidence: 1,
                    in: db, store: store, now: now
                )
            case .deckUnlink(let lectureID, let deckID):
                result = try LectureSlides.unlink(lectureID: lectureID, deckID: deckID, in: db, store: store, now: now)
            default:
                return (.refused("Not a deck change."), [])
            }
        } catch let error as DeckLinkError {
            return (.refused(error.description), [])
        }
        let made = result.change(sourceKind: origin.sourceKind, quote: quote, confidence: confidence, model: origin.model, now: now)
        guard var change = made else {
            let summary = result.summary
            let prefix = "Uses "
            var already = "Already so: " + summary
            if summary.hasPrefix(prefix) {
                let rest = String(summary.dropFirst(prefix.count))
                already = "Already uses " + rest
            }
            return (.unchanged(already + "."), [])
        }
        let lectureID = change.lectureID
        ItemChangeRows.apply(origin.source, to: &change)
        // The row's lecture is the one whose slides changed (a transcript quote's may differ).
        change.lectureID = lectureID
        change.apiCallID = origin.apiCallID
        let stamped = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(stamped, db: db)
        var jobs = result.alignJobs
        // Slides that arrive later: the course's other recordings without slides are checked again.
        if case .deckLink = request, let courseID = try Lecture.find(result.lectureID).fetchOne(db)?.courseID {
            jobs += try LectureSlides.queueContinuationChecks(courseID: courseID, reason: "slides linked", in: db, store: store, now: now)
        }
        return (.applied(stamped), jobs)
    }

    /// Undo of a deck change in the caller's transaction (`LectureSlides.undo`); the caller marks
    /// the row. Returns the `align` jobs it queued.
    static func undoDeckLink(_ change: AgentChange, db: Database, store: RecordStore, now: Date) throws -> [Job] {
        do {
            return try LectureSlides.undo(change, in: db, store: store, now: now)
        } catch DeckLinkError.changedSince {
            throw UndoRefused.changedSince
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

    // MARK: Course credits (mc)

    /// "6 credits · 120 h self-study".
    static func creditsSummary(credits: Double?, selfStudyHours: Double?) -> String {
        func number(_ value: Double) -> String { value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value) }
        var parts: [String] = []
        if let credits { parts.append("\(number(credits)) credits") }
        if let selfStudyHours { parts.append("\(number(selfStudyHours)) h self-study") }
        return parts.isEmpty ? "Credits cleared" : parts.joined(separator: " · ")
    }

    private static func setCredits(
        _ courseID: Course.ID, credits: Double?, selfStudyHours: Double?, quote: String, confidence: Double, origin: Origin, db: Database,
        store: RecordStore, now: Date
    ) throws -> Outcome {
        guard let course = try Course.find(courseID).fetchOne(db) else { return .refused("Unknown course.") }
        guard credits != nil || selfStudyHours != nil else { return .refused("Give the credits or the self-study hours.") }
        if let credits, !(credits > 0 && credits <= 60) { return .refused("Credits must be between 0 and 60.") }
        if let selfStudyHours, !(selfStudyHours > 0 && selfStudyHours <= 1_800) { return .refused("Self-study hours must be between 0 and 1,800.") }
        let newCredits = credits ?? course.credits
        let newHours = selfStudyHours ?? course.selfStudyHours
        guard newCredits != course.credits || newHours != course.selfStudyHours else {
            return .unchanged("The course has these credits already.")
        }
        try Course.find(courseID).update {
            $0.credits = newCredits
            $0.selfStudyHours = newHours
            $0.updatedAt = now
        }
        .execute(db)
        let previous = try AgentChange
            .where { $0.targetTable.eq(AgentChangeTarget.course) && $0.targetID.eq(UUID?.some(courseID)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) && $0.kind.eq(AgentChangeKind.courseCredits) }
            .fetchAll(db)
        var change = AgentChange(
            kind: .courseCredits, targetTable: .course, targetID: courseID, title: course.name,
            summary: creditsSummary(credits: newCredits, selfStudyHours: newHours),
            before: AgentChangeValues(exists: true, credits: course.credits, selfStudyHours: course.selfStudyHours),
            after: AgentChangeValues(exists: true, credits: newCredits, selfStudyHours: newHours), sourceKind: origin.sourceKind,
            taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: confidence, model: origin.model,
            apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        for old in previous { try AgentChangeRepository.supersede(old.id, by: change.id, at: now, db: db) }
        return .applied(change)
    }

    // MARK: Plan rules (mc)

    /// Two rules the student would not keep side by side: a newer one replaces the older (another
    /// cap or away rule for the same days, another sitting or seminar-hours choice for the course,
    /// another attend choice for the class). Skips add up.
    static func sameScope(_ lhs: PlanRule, _ rhs: PlanRule) -> Bool {
        guard lhs.kind == rhs.kind else { return false }
        switch lhs.kind {
        case .cap, .away: return lhs.weekdays == rhs.weekdays && lhs.first == rhs.first && lhs.last == rhs.last
        case .sitting, .seminarHours: return lhs.courseID == rhs.courseID
        case .attend: return lhs.slotID == rhs.slotID && lhs.sessionID == rhs.sessionID
        default: return false
        }
    }

    private static func rememberRule(
        _ rule: PlanRule, text: String, courseID: Course.ID?, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AgentMemory.textLimit))
        guard !text.isEmpty else { return .refused("The rule needs a text.") }
        let active = try AgentMemory.where { $0.forgottenAt.is(nil) }.fetchAll(db)
        if active.contains(where: { $0.planRule == rule }) { return .unchanged("The plan follows that already.") }
        let replaced = active.filter { memory in memory.kind == .plan && memory.planRule.map { sameScope($0, rule) } == true }
        guard active.count - replaced.count < AgentMemory.activeLimit else {
            return .refused("\(AgentMemory.activeLimit) memories are kept at most. Forget one first.")
        }
        let memory = store.stamp(AgentMemory(
            kind: .plan, courseID: courseID, text: text, quote: quote, conversationID: origin.conversationID, createdBy: .agent,
            createdAt: now, updatedAt: now, planRule: rule
        ))
        try AgentMemory.upsert { memory }.execute(db)
        var change = AgentChange(
            kind: .memory, targetTable: .memory, targetID: memory.id, title: String(text.prefix(AgentChange.titleLimit)), summary: "Remembered",
            before: AgentChangeValues(exists: false),
            after: AgentChangeValues(exists: true, memoryText: text, forgotten: false, planRule: rule), sourceKind: origin.sourceKind,
            taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1, model: origin.model, apiCallID: origin.apiCallID,
            appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        // The older rule of the same scope is forgotten; its change row points at this one, so
        // Undo of this change brings it back.
        for old in replaced {
            let oldID = old.id
            try AgentMemory.find(oldID).update {
                $0.forgottenAt = Date?.some(now)
                $0.updatedAt = now
            }
            .execute(db)
            let rows = try AgentChange
                .where { $0.targetTable.eq(AgentChangeTarget.memory) && $0.targetID.eq(UUID?.some(oldID)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) }
                .fetchAll(db)
            for row in rows { try AgentChangeRepository.supersede(row.id, by: change.id, at: now, db: db) }
        }
        return .applied(change)
    }

    // MARK: Plan blocks (mc)

    private static func moveBlock(
        _ id: StudyBlock.ID, to day: CalendarDay, quote: String, origin: Origin, db: Database, store: RecordStore, now: Date
    ) throws -> Outcome {
        guard let block = try StudyBlock.find(id).fetchOne(db) else { return .refused("Unknown block.") }
        guard block.state == .planned else { return .refused("Only a block not started yet can move.") }
        guard block.day != day else { return .unchanged("The block is on that day already.") }
        let memories = try AgentMemory.where { $0.forgottenAt.is(nil) && $0.kind.eq(AgentMemoryKind.plan) }.fetchAll(db)
        let away = PlanRules(memories: memories).isAway(day)
        let last = try StudyBlock.where { $0.day.eq(day) }.fetchAll(db).map(\.sortOrder).max() ?? -1
        var moved = block
        moved.day = day
        moved.sortOrder = last + 1
        moved.createdBy = .user
        moved.isAway = away
        let stamped = store.stamp(moved)
        try StudyBlock.upsert { stamped }.execute(db)
        let zone = AppAgentModule.timeZone
        let title = block.detail.isEmpty ? block.title : "\(block.title) · \(block.detail)"
        let previous = try AgentChange
            .where { $0.targetTable.eq(AgentChangeTarget.block) && $0.targetID.eq(UUID?.some(id)) && $0.undoneAt.is(nil) && $0.supersededBy.is(nil) }
            .fetchAll(db)
        var change = AgentChange(
            kind: .planMove, targetTable: .block, targetID: id, title: String(title.prefix(AgentChange.titleLimit)),
            summary: "Moved from \(ChangeSummary.day(block.day.start(in: zone), timeZone: zone)) to \(ChangeSummary.day(day.start(in: zone), timeZone: zone))",
            before: AgentChangeValues(exists: true, day: block.day, sortOrder: block.sortOrder, createdBy: block.createdBy, isAway: block.isAway),
            after: AgentChangeValues(exists: true, day: day, sortOrder: moved.sortOrder, createdBy: .user, isAway: away),
            sourceKind: origin.sourceKind, taskID: origin.taskID, eventID: origin.eventID, quote: quote, confidence: 1, model: origin.model,
            apiCallID: origin.apiCallID, appliedAt: now, createdAt: now, updatedAt: now
        )
        ItemChangeRows.apply(origin.source, to: &change)
        change = finalize(change, origin: origin, store: store)
        try AgentChangeRepository.insert(change, db: db)
        for old in previous { try AgentChangeRepository.supersede(old.id, by: change.id, at: now, db: db) }
        return .applied(change)
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
        case .block:
            // mc: a moved block goes back to its day and place, only while it is still planned on
            // the day the move put it and its old day has not passed.
            let today = CalendarDay(now, in: AppAgentModule.timeZone)
            if current, let targetID = change.targetID, var block = try StudyBlock.find(targetID).fetchOne(db),
               let before = change.before, let day = before.day, day >= today,
               block.state == .planned, block.day == change.after?.day {
                block.day = day
                block.sortOrder = before.sortOrder ?? block.sortOrder
                block.createdBy = before.createdBy ?? block.createdBy
                block.isAway = before.isAway ?? block.isAway
                let stamped = store.stamp(block)
                try StudyBlock.upsert { stamped }.execute(db)
            }
        case .course where change.kind == .courseCredits:
            // mc: the credits and self-study hours from `before`, only while the course still has
            // what the change wrote.
            if current, let targetID = change.targetID, let course = try Course.find(targetID).fetchOne(db),
               let before = change.before, let after = change.after,
               course.credits == after.credits, course.selfStudyHours == after.selfStudyHours {
                let credits = before.credits
                let hours = before.selfStudyHours
                try Course.find(targetID).update {
                    $0.credits = credits
                    $0.selfStudyHours = hours
                    $0.updatedAt = now
                }
                .execute(db)
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
                // Only the memory as this change left it: not after a later change replaced it
                // (`superseded_by`), nor after an edit in the Memory sheet (text or rule differ).
                let after = change.after
                let forgottenNow = memory.forgottenAt != nil
                let unchanged = change.supersededBy == nil
                    && (after?.memoryText.map { $0 == memory.text } ?? true)
                    && after?.planRule == memory.planRule
                    && (after?.forgotten.map { $0 == forgottenNow } ?? true)
                guard unchanged else { throw UndoRefused.changedSince }
                if change.before?.exists == false {
                    memory.forgottenAt = now
                } else {
                    if let text = change.before?.memoryText { memory.text = text }
                    // The rule goes back with the text, so the coach plans by it again.
                    memory.planRule = change.before?.planRule
                    if change.before?.forgotten == false { memory.forgottenAt = nil }
                }
                let stamped = store.stamp(memory)
                try AgentMemory.upsert { stamped }.execute(db)
            }
            // mc: the plan rules this one replaced are kept again.
            let replaced = try AgentChange
                .where { $0.supersededBy.eq(AgentChange.ID?.some(id)) && $0.targetTable.eq(AgentChangeTarget.memory) && $0.undoneAt.is(nil) }
                .fetchAll(db)
            for row in replaced {
                guard let memoryID = row.targetID else { continue }
                try AgentMemory.find(memoryID).update {
                    $0.forgottenAt = Date?.none
                    $0.updatedAt = now
                }
                .execute(db)
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
        case .slot:
            // Slot changes are not superseded: each puts back only the fields it wrote, while the
            // slot still has them (`undoSlot`).
            if let targetID = change.targetID {
                try undoSlot(change, slotID: targetID, db: db, store: store, now: now)
            }
        case .deckSpan:
            // mr: a deck link made, changed or removed (the agent's, or continuation detection's).
            _ = try undoDeckLink(change, db: db, store: store, now: now)
        case .profile:
            // oss: the profile and the semester as they were, each only while it is still as the
            // change left it.
            if current { try undoProfile(change, db: db, store: store, now: now) }
        case .lectureNotesMark:
            // ln: a kept answer is removed.
            try undoNotesMark(change, db: db, now: now)
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
