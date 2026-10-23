import Foundation
import GRDB
import Processing
import StudyCore

/// One change of where a lecture sits or what it is called, at the student's request (the agent's
/// lecture-plan actions, 2026-10-23).
///
/// A lecture's number is its label in the course's sequence (what the decks' "03_…" and the
/// student call L3), not the ordinal of its class: it changes only when the student asks. One
/// class holds at most one linked lecture (`lecture_session_id`); a second lecture taught in the
/// same meeting is *joined* to it: dated to the class's start, without the link (so
/// `SessionLectures.lecture(forSession:)` stays the linked one and adoption skips the taken
/// class). A planned lecture is one linked to a class that starts after now, with no recording and
/// no running job: only planned lectures move along as followers.
public enum LecturePlanEdit: Sendable, Hashable {
    /// The lecture goes to a class of its course (an exercise beside a lecture stands for that
    /// lecture's meeting). With `followers`, the course's planned lectures numbered after it go
    /// to the free classes after it, in order (the forward case "we already did chapter 3 today"
    /// and the backward case "chapter 3 continues next week" alike).
    case place(Lecture.ID, session: LectureSession.ID, followers: Bool)
    /// A new title and/or number. With `shiftLater`, every lecture numbered after the old number
    /// moves by the same step (an unnumbered lecture taking a number pushes those from it on).
    case label(Lecture.ID, title: String?, number: Int?, shiftLater: Bool)
    /// A lecture that holds nothing (no recording, slides, notes, flags or answered practice).
    case deleteEmpty(Lecture.ID)
}

/// Where a lecture-plan change comes from (its `agent_change` source columns).
public struct LecturePlanSource: Sendable {
    public var quote: String
    public var sourceKind: SourceRef.Kind
    public var model: String
    public var conversationID: AgentConversation.ID?
    public var taskID: AgentTask.ID?

    public init(
        quote: String, sourceKind: SourceRef.Kind = .chat, model: String = "", conversationID: AgentConversation.ID? = nil,
        taskID: AgentTask.ID? = nil
    ) {
        self.quote = quote
        self.sourceKind = sourceKind
        self.model = model
        self.conversationID = conversationID
        self.taskID = taskID
    }
}

/// Why a lecture-plan change was not made (the agent says it in its own words).
public enum LecturePlanRefusal: Error, Equatable, Sendable {
    /// The lecture, class or recording is gone.
    case missing
    /// The class (or the lecture a recording goes to) is another course's.
    case otherCourse
    case cancelledSession
    /// A lecture with recordings cannot go to a class that has not happened.
    case recordedToFuture
    /// The class's lecture has recordings too (counts: the moved one's, the class's).
    case bothRecorded(Int, Int)
    /// A recording of it is being processed right now.
    case busy
    /// It has neither slides nor a recording of its own: beside the class's lecture it would be
    /// merged into it (`merge_lectures`).
    case holdsNothing
    /// Another lecture of the course has that number.
    case numberTaken(Lecture.ID)
    case emptyTitle
    /// Only empty lectures are deleted.
    case notEmpty(recordings: Int, slides: Int, notes: Int)
    /// It is so already.
    case unchanged
}

/// What `editLecturePlan` did.
public struct LecturePlanOutcome: Sendable {
    public var change: AgentChange
    /// Lectures besides the one asked about that moved with it (followers, a joined lecture that
    /// took the class it left).
    public var moved: [Lecture.ID]
    /// Followers left without a class (past the course's last one): undated now.
    public var unplaced: [Lecture.ID]
}

extension FilingService {
    // MARK: - Editing the plan

    /// Applies one lecture-plan change in ONE transaction with its `agent_change` row: every check
    /// runs inside it (the actor is reentrant and the agent's change log has a service of its
    /// own, so the transaction is the only point that serialises them). `lecture_edit` rows keep
    /// every touched lecture before and after (`AgentChangeValues.lectures`), `lecture_delete`
    /// rows the deleted rows (`before.deletion`). Throws `LecturePlanRefusal`.
    public func editLecturePlan(_ edit: LecturePlanEdit, source: LecturePlanSource) async throws -> LecturePlanOutcome {
        let now = now()
        let store = store
        let outcome = try await services.database.write { db -> LecturePlanOutcome in
            switch edit {
            case .place(let id, let sessionID, let followers):
                return try Self.place(id, sessionID: sessionID, followers: followers, source: source, in: db, store: store, now: now)
            case .label(let id, let title, let number, let shiftLater):
                return try Self.label(id, title: title, number: number, shiftLater: shiftLater, source: source, in: db, store: store, now: now)
            case .deleteEmpty(let id):
                return try Self.deleteEmpty(id, source: source, in: db, store: store, now: now)
            }
        }
        Log.importer.notice(
            "Lecture plan changed (\(outcome.change.kind.rawValue, privacy: .public)): \(outcome.moved.count, privacy: .public) more moved, \(outcome.unplaced.count, privacy: .public) without a class"
        )
        return outcome
    }

    /// Undo of a `lecture_edit` (every touched lecture back where it was, all or none) or a
    /// `lecture_delete` (the lecture and what went with it back), with the row marked undone, in
    /// one transaction. False when it was undone already; `FilingError.changedSince` when a
    /// touched lecture no longer holds what the change wrote, or a class it goes back to holds
    /// another lecture now.
    public func undoLecturePlan(_ change: AgentChange) async throws -> Bool {
        let now = now()
        let id = change.id
        let undone = try await services.database.write { db -> Bool in
            guard let current = try AgentChange.find(id).fetchOne(db), current.undoneAt == nil else { return false }
            switch current.kind {
            case .lectureEdit:
                guard let before = current.before?.lectures, let after = current.after?.lectures else { throw FilingError.missing }
                try Self.restore(before, after: after, in: db, now: now)
            case .lectureDelete:
                guard let kept = current.before?.deletion else { throw FilingError.missing }
                let deletion = try Deletion(encoded: kept)
                if case .lecture(let lectureID) = deletion.item, try Lecture.find(lectureID).fetchCount(db) > 0 {
                    throw FilingError.changedSince
                }
                try deletion.rows.restore(in: db)
            default:
                throw FilingError.missing
            }
            try AgentChangeRepository.markUndone(id, at: now, db: db)
            return true
        }
        if undone { Log.importer.notice("Undid a lecture plan change (\(change.kind.rawValue, privacy: .public))") }
        return undone
    }

    /// Moves a recording (with its transcript, slide stamps, notes, flags, jobs and timed spans)
    /// into another lecture through `move`, as the student's own Change… does: the old lecture's
    /// study pass is dropped and alignment or transcription queued, and a lecture its filing
    /// created goes when nothing is left in it. Its `agent_change` row (`filing`, target
    /// `filing`: Undo puts the filing back through `undoAdvice`) is written in the move's
    /// transaction, which also refuses (and rolls back) while a job of the recording runs. Into
    /// another course only with `acrossCourses`. A recording without a filing (imported before
    /// smart import) gets one first.
    public func moveRecording(
        _ recordingID: Recording.ID, to lectureID: Lecture.ID, acrossCourses: Bool, source: LecturePlanSource
    ) async throws -> AgentChange {
        guard let recording = try await store.fetch(Recording.self, id: recordingID),
              let target = try await store.fetch(Lecture.self, id: lectureID)
        else { throw LecturePlanRefusal.missing }
        guard recording.lectureID != lectureID else { throw LecturePlanRefusal.unchanged }
        var fromCourse = recording.courseID
        if let id = recording.lectureID, let old = try await store.fetch(Lecture.self, id: id) { fromCourse = old.courseID }
        if let fromCourse, fromCourse != target.courseID, !acrossCourses { throw LecturePlanRefusal.otherCourse }
        let filing: Filing
        if let found = try await FilingRepository(store: store).latest(recordingID: recordingID) {
            filing = found
        } else {
            filing = try await describe(recording)
        }
        let library = try await loadLibrary()
        let changeID = UUID()
        let now = now()
        let started = Self.spoken(recording.startedAt, zone: library.zone)
        let hook: MoveHook = { db, before, after, lecture in
            let running = try Job.where { $0.recordingID.eq(recordingID) && $0.state.eq(JobState.running) }.fetchCount(db)
            if running > 0 { throw LecturePlanRefusal.busy }
            let course = try Course.find(lecture.courseID).fetchOne(db)
            let short = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName } ?? ""
            let place = [short, lecture.number.map { "L\($0)" }, lecture.title.isEmpty ? nil : lecture.title]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " · ")
            let change = AgentChange(
                id: changeID, kind: .filing, targetTable: .filing, targetID: after.id, title: "Recording of \(started)",
                summary: "Moved to \(place)",
                before: AgentChangeValues(exists: true, courseID: before.courseID, lectureID: before.lectureID, lectureSessionID: before.lectureSessionID),
                after: AgentChangeValues(exists: true, courseID: after.courseID, lectureID: after.lectureID, lectureSessionID: after.lectureSessionID),
                sourceKind: source.sourceKind, lectureID: lecture.id, conversationID: source.conversationID, taskID: source.taskID,
                quote: source.quote, confidence: 1, model: source.model, appliedAt: now, createdAt: now, updatedAt: now
            )
            try AgentChangeRepository.insert(change, db: db)
        }
        _ = try await move(filing, to: .lecture(lectureID), courseID: target.courseID, reason: .user, hook: hook)
        guard let change = try await store.fetch(AgentChange.self, id: changeID) else { throw FilingError.missing }
        Log.importer.notice("Moved a recording to another lecture as asked")
        return change
    }

    /// A filing row for a recording that has none (it records where the recording is).
    private func describe(_ recording: Recording) async throws -> Filing {
        var lecture: Lecture?
        if let id = recording.lectureID { lecture = try await store.fetch(Lecture.self, id: id) }
        let zone = try await loadLibrary().zone
        return try await store.save(Filing(
            kind: recording.source == .file ? .recording : .capture, fileName: "Recording of \(Self.spoken(recording.startedAt, zone: zone))",
            courseID: lecture?.courseID ?? recording.courseID, lectureID: lecture?.id, lectureSessionID: lecture?.lectureSessionID,
            recordingID: recording.id, source: .auto, confidence: lecture == nil ? 0 : 1, createdAt: now()
        ))
    }

    // MARK: - Placing

    /// `place` inside the transaction.
    static func place(
        _ lectureID: Lecture.ID, sessionID: LectureSession.ID, followers: Bool, source: LecturePlanSource,
        in db: Database, store: RecordStore, now: Date
    ) throws -> LecturePlanOutcome {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db), let asked = try LectureSession.find(sessionID).fetchOne(db) else {
            throw LecturePlanRefusal.missing
        }
        guard asked.courseID == lecture.courseID else { throw LecturePlanRefusal.otherCourse }
        guard !asked.isCancelled else { throw LecturePlanRefusal.cancelledSession }
        let courseID = lecture.courseID
        let sessions = try LectureSession.where { $0.courseID.eq(courseID) }.fetchAll(db)
        // An exercise or tutorial beside a lecture is that lecture's class meeting.
        let session = SessionLectures.meeting(of: asked, among: sessions)
        let holdings = try Self.holdings(in: db)
        let recordings = holdings[lectureID]?.recordings ?? 0
        if recordings > 0, session.startsAt > now { throw LecturePlanRefusal.recordedToFuture }
        if try Self.isProcessing(lectureID, in: db) { throw LecturePlanRefusal.busy }

        let lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Followers: the planned lectures numbered after it, in number order.
        var following: [Lecture] = []
        if followers, let number = lecture.number {
            following = try lectures.filter { other in
                guard other.id != lectureID, let value = other.number, value > number, let id = other.lectureSessionID,
                      let held = byID[id], held.startsAt > now, (holdings[other.id]?.recordings ?? 0) == 0
                else { return false }
                return try !Self.isProcessing(other.id, in: db)
            }
            .sorted { lhs, rhs in
                (lhs.number ?? 0, lhs.lectureSessionID.flatMap { byID[$0]?.startsAt } ?? .distantFuture)
                    < (rhs.number ?? 0, rhs.lectureSessionID.flatMap { byID[$0]?.startsAt } ?? .distantFuture)
            }
        }
        let moving = Set(following.map(\.id))

        // Linked to the class already: it stays as it is (the followers may still move). Else the
        // class's own lecture, unless it moves along, keeps the class: the lecture joins its meeting.
        var placed = lecture
        if lecture.lectureSessionID != session.id {
            placed.heldAt = session.startsAt
            if let holder = lectures.first(where: { $0.lectureSessionID == session.id && $0.id != lectureID && !moving.contains($0.id) }) {
                let theirs = holdings[holder.id]?.recordings ?? 0
                if recordings > 0, theirs > 0 { throw LecturePlanRefusal.bothRecorded(recordings, theirs) }
                if recordings == 0, holdings[lectureID]?.slides.isEmpty ?? true { throw LecturePlanRefusal.holdsNothing }
                placed.lectureSessionID = nil
            } else {
                placed.lectureSessionID = session.id
            }
        }
        var after: [Lecture.ID: Lecture] = [lectureID: placed]

        // The class it left: a lecture joined to it takes the link.
        if let left = lecture.lectureSessionID, left != placed.lectureSessionID, let leftSession = byID[left],
           let joined = lectures.first(where: { other in
               other.id != lectureID && other.lectureSessionID == nil && !moving.contains(other.id)
                   && other.heldAt.map { abs($0.timeIntervalSince(leftSession.startsAt)) < 1 } == true
           }) {
            var linked = joined
            linked.lectureSessionID = left
            after[joined.id] = linked
        }

        // The followers, in order, into the free numbered classes after it.
        var unplaced: [Lecture.ID] = []
        if !following.isEmpty {
            let start = max(now, session.startsAt)
            let taken = Set(lectures.filter { !moving.contains($0.id) }.map { after[$0.id] ?? $0 }.compactMap(\.lectureSessionID))
            var free = sessions
                .filter { !$0.isCancelled && $0.startsAt > start && !taken.contains($0.id) && SessionLectures.numbersLectures($0, among: sessions) }
                .sorted { $0.startsAt < $1.startsAt }[...]
            for follower in following {
                var moved = follower
                if let next = free.popFirst() {
                    moved.lectureSessionID = next.id
                    moved.heldAt = next.startsAt
                } else {
                    moved.lectureSessionID = nil
                    moved.heldAt = nil
                    unplaced.append(follower.id)
                }
                after[follower.id] = moved
            }
        }

        let original = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = after.values.filter { value in
            guard let old = original[value.id] else { return false }
            return !LecturePlacementValues(old, filings: []).matches(value)
        }
        guard !changed.isEmpty else { throw LecturePlanRefusal.unchanged }
        let (before, written) = try Self.write(changed, original: original, in: db, now: now)

        let course = try Course.find(courseID).fetchOne(db)
        let zone = Self.zone(of: course, semesters: try Semester.order(by: \.lectureStart).fetchAll(db))
        let movedItself = changed.contains { $0.id == lectureID }
        var summary = (movedItself ? "Moved to " : "Stays on ") + Self.spoken(session.startsAt, zone: zone)
        if movedItself, placed.lectureSessionID == nil, let holder = lectures.first(where: { $0.lectureSessionID == session.id && $0.id != lectureID }) {
            summary += holder.number.map { " with L\($0)" } ?? " with its lecture"
        }
        let others = changed.filter { $0.id != lectureID }.count
        if others > 0 { summary += others == 1 ? "; 1 later lecture moved" : "; \(others) later lectures moved" }
        let change = try Self.record(
            .lectureEdit, lecture: lecture, course: course, summary: summary, before: before, after: written, source: source,
            in: db, store: store, now: now
        )
        return LecturePlanOutcome(change: change, moved: changed.map(\.id).filter { $0 != lectureID }, unplaced: unplaced)
    }

    /// A job of the lecture or of its recordings is running.
    static func isProcessing(_ lectureID: Lecture.ID, in db: Database) throws -> Bool {
        let reference: Lecture.ID? = lectureID
        let recordings: [Recording.ID?] = try Recording.where { $0.lectureID.eq(reference) }.fetchAll(db).map(\.id)
        let running = try Job
            .where { ($0.lectureID.eq(reference) || $0.recordingID.in(recordings)) && $0.state.eq(JobState.running) }
            .fetchCount(db)
        return running > 0
    }

    // MARK: - Labels

    /// `label` inside the transaction.
    static func label(
        _ lectureID: Lecture.ID, title: String?, number: Int?, shiftLater: Bool, source: LecturePlanSource,
        in db: Database, store: RecordStore, now: Date
    ) throws -> LecturePlanOutcome {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { throw LecturePlanRefusal.missing }
        let courseID = lecture.courseID
        let lectures = try Lecture.where { $0.courseID.eq(courseID) }.fetchAll(db)
        var after: [Lecture.ID: Lecture] = [:]
        var renamed = lecture
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw LecturePlanRefusal.emptyTitle }
            renamed.title = String(trimmed.prefix(200))
        }
        if let number, number != lecture.number {
            renamed.number = number
            if shiftLater {
                for other in lectures where other.id != lectureID {
                    guard let value = other.number else { continue }
                    var shifted = other
                    if let old = lecture.number, value > old {
                        shifted.number = value + (number - old)
                    } else if lecture.number == nil, value >= number {
                        shifted.number = value + 1
                    } else {
                        continue
                    }
                    after[other.id] = shifted
                }
            }
        }
        after[lectureID] = renamed
        // Each number this change gives must be that lecture's alone.
        let final = lectures.map { after[$0.id] ?? $0 }
        for value in after.values where value.number != lectures.first(where: { $0.id == value.id })?.number {
            guard let number = value.number else { continue }
            if let other = final.first(where: { $0.id != value.id && $0.number == number }) {
                throw LecturePlanRefusal.numberTaken(other.id)
            }
        }
        let original = Dictionary(lectures.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = after.values.filter { value in original[value.id].map { !LecturePlacementValues($0, filings: []).matches(value) } ?? false }
        guard !changed.isEmpty else { throw LecturePlanRefusal.unchanged }
        let (before, written) = try Self.write(changed, original: original, in: db, now: now)

        var parts: [String] = []
        if renamed.title != lecture.title { parts.append("Renamed “\(String(renamed.title.prefix(60)))”") }
        if renamed.number != lecture.number, let value = renamed.number { parts.append("Now L\(value)") }
        let others = changed.filter { $0.id != lectureID }.count
        if others > 0 { parts.append(others == 1 ? "1 later lecture renumbered" : "\(others) later lectures renumbered") }
        let course = try Course.find(courseID).fetchOne(db)
        let change = try Self.record(
            .lectureEdit, lecture: lecture, course: course, summary: parts.joined(separator: "; "), before: before, after: written,
            source: source, in: db, store: store, now: now
        )
        return LecturePlanOutcome(change: change, moved: changed.map(\.id).filter { $0 != lectureID }, unplaced: [])
    }

    // MARK: - Deleting an empty lecture

    /// What the student (or filing) put in a lecture: a delete of it is only for empty ones.
    struct LectureContents {
        var recordings = 0
        /// Deck links, coarse or timed, any source.
        var slides = 0
        /// The student's notes and the marks they kept on its summary.
        var notes = 0
        /// The student's own flags and practice answers.
        var work = 0

        var isEmpty: Bool { recordings + slides + notes + work == 0 }
    }

    static func contents(of lectureID: Lecture.ID, in db: Database) throws -> LectureContents {
        let reference: Lecture.ID? = lectureID
        var contents = LectureContents()
        contents.recordings = try Recording.where { $0.lectureID.eq(reference) }.fetchCount(db)
        contents.slides = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        contents.notes = try Note.where { $0.lectureID.eq(reference) }.fetchCount(db)
            + LectureNotesMark.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let flags = try Annotation.where { $0.lectureID.eq(lectureID) && $0.studyUnitID.is(nil) }.fetchCount(db)
        let answered = try Int.fetchOne(db, sql: """
            SELECT count(*) FROM "study_question" q
            WHERE q."lecture_id" = ? AND EXISTS (SELECT 1 FROM "study_answer" a WHERE a."question_id" = q."id")
            """, arguments: [lectureID.uuidString.lowercased()]) ?? 0
        contents.work = flags + answered
        return contents
    }

    /// `deleteEmpty` inside the transaction: the lecture through the delete's own plan, its rows
    /// kept in the change row for Undo.
    static func deleteEmpty(
        _ lectureID: Lecture.ID, source: LecturePlanSource, in db: Database, store: RecordStore, now: Date
    ) throws -> LecturePlanOutcome {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { throw LecturePlanRefusal.missing }
        let contents = try Self.contents(of: lectureID, in: db)
        guard contents.isEmpty else {
            throw LecturePlanRefusal.notEmpty(recordings: contents.recordings, slides: contents.slides, notes: contents.notes + contents.work)
        }
        let course = try Course.find(lecture.courseID).fetchOne(db)
        let item = LibraryItem.lecture(lectureID)
        let plan = try Self.deletionPlan(item, in: db)
        let rows = try DeletedRows.collect(plan.selectors, in: db)
        let summary = try Self.summary(item, rows: rows, in: db)
        try rows.deleteRoots(in: db)
        let deletion = Deletion(item: item, summary: summary, rows: rows, jobs: [], blobs: [])
        let change = store.stamp(AgentChange(
            kind: .lectureDelete, targetTable: .lecture, targetID: lectureID, title: Self.lectureName(lecture, course: course),
            summary: "Deleted (it was empty)",
            before: AgentChangeValues(exists: true, deletion: try deletion.encoded()), after: AgentChangeValues(exists: false),
            sourceKind: source.sourceKind, conversationID: source.conversationID, taskID: source.taskID, quote: source.quote,
            confidence: 1, model: source.model, appliedAt: now, createdAt: now, updatedAt: now
        ))
        try AgentChangeRepository.insert(change, db: db)
        return LecturePlanOutcome(change: change, moved: [], unplaced: [])
    }

    // MARK: - Writing and restoring

    /// Writes the lectures' new title, number, date and class, and points their filings at the
    /// class (inside the transaction). Returns each lecture before and after, with its filings.
    static func write(
        _ lectures: [Lecture], original: [Lecture.ID: Lecture], in db: Database, now: Date
    ) throws -> (before: [LecturePlacementValues], after: [LecturePlacementValues]) {
        var before: [LecturePlacementValues] = []
        var after: [LecturePlacementValues] = []
        for lecture in lectures.sorted(by: { ($0.number ?? Int.max, $0.createdAt) < ($1.number ?? Int.max, $1.createdAt) }) {
            guard let old = original[lecture.id] else { continue }
            let id = lecture.id
            let reference: Lecture.ID? = id
            let filings = try Filing.where { $0.lectureID.eq(reference) }.fetchAll(db)
            before.append(LecturePlacementValues(old, filings: filings.map { .init(id: $0.id, lectureSessionID: $0.lectureSessionID) }))
            let title = lecture.title
            let number = lecture.number
            let heldAt = lecture.heldAt
            let sessionID = lecture.lectureSessionID
            try Lecture.find(id)
                .update { $0.title = title; $0.number = number; $0.heldAt = heldAt; $0.lectureSessionID = sessionID; $0.updatedAt = now }
                .execute(db)
            try Filing.where { $0.lectureID.eq(reference) }
                .update { $0.lectureSessionID = sessionID; $0.updatedAt = now }
                .execute(db)
            after.append(LecturePlacementValues(lecture, filings: filings.map { .init(id: $0.id, lectureSessionID: sessionID) }))
        }
        return (before, after)
    }

    /// Undo of a `lecture_edit` inside the transaction: all or none.
    static func restore(_ before: [LecturePlacementValues], after: [LecturePlacementValues], in db: Database, now: Date) throws {
        for value in after {
            guard let lecture = try Lecture.find(value.id).fetchOne(db), value.matches(lecture) else { throw FilingError.changedSince }
        }
        let touched = Set(before.map(\.id))
        for value in before {
            guard let sessionID = value.lectureSessionID else { continue }
            // The class is gone, or holds a lecture the change did not touch.
            guard try LectureSession.find(sessionID).fetchCount(db) > 0 else { throw FilingError.changedSince }
            let holders = try Lecture.where { $0.lectureSessionID.eq(LectureSession.ID?.some(sessionID)) }.fetchAll(db)
            if holders.contains(where: { !touched.contains($0.id) }) { throw FilingError.changedSince }
        }
        for value in before {
            let title = value.title
            let number = value.number
            let heldAt = value.heldAt
            let sessionID = value.lectureSessionID
            let reference: Lecture.ID? = value.id
            try Lecture.find(value.id)
                .update { $0.title = title; $0.number = number; $0.heldAt = heldAt; $0.lectureSessionID = sessionID; $0.updatedAt = now }
                .execute(db)
            for filing in value.filings {
                let place = filing.lectureSessionID
                try Filing.where { $0.id.eq(filing.id) && $0.lectureID.eq(reference) }
                    .update { $0.lectureSessionID = place; $0.updatedAt = now }
                    .execute(db)
            }
        }
    }

    /// The `lecture_edit` row, inserted in the caller's transaction, titled by the lecture.
    static func record(
        _ kind: AgentChangeKind, lecture: Lecture, course: Course?, summary: String, before: [LecturePlacementValues],
        after: [LecturePlacementValues], source: LecturePlanSource, in db: Database, store: RecordStore, now: Date
    ) throws -> AgentChange {
        let change = store.stamp(AgentChange(
            kind: kind, targetTable: .lecture, targetID: lecture.id, title: Self.lectureName(lecture, course: course), summary: summary,
            before: AgentChangeValues(exists: true, lectures: before), after: AgentChangeValues(exists: true, lectures: after),
            sourceKind: source.sourceKind, lectureID: lecture.id, conversationID: source.conversationID, taskID: source.taskID,
            quote: source.quote, confidence: 1, model: source.model, appliedAt: now, createdAt: now, updatedAt: now
        ))
        try AgentChangeRepository.insert(change, db: db)
        return change
    }

    /// "Thu 22 Oct, 14:00" in `zone`.
    static func spoken(_ date: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.weekday, .day, .month, .hour, .minute], from: date)
        let weekday = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][((parts.weekday ?? 1) - 1 + 7) % 7]
        let month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][((parts.month ?? 1) - 1 + 12) % 12]
        return "\(weekday) \(parts.day ?? 1) \(month), " + String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
