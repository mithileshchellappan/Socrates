import Foundation
import SQLiteData

// Repositories added with schema v16 (ln: lecture notes). The rules (what the writer reads, the
// prompt, validation, asking) live in StudyPass (`NotesWriter`, `NotesAsker`) and AppAgent (the
// task runner, the agent's actions); the screens (StudyPage, Courses, Review) read rows and write
// marks and versions through this. docs/plan-lecture-notes.md §5 and its "Build plan".

extension LectureNotes {
    /// A version that can be the current notes: neither discarded nor cancelled.
    public var isCandidate: Bool { discardedAt == nil && state != .cancelled }

    /// The current notes among a lecture's versions: the newest candidate.
    public static func current(of versions: [LectureNotes]) -> LectureNotes? {
        versions.filter(\.isCandidate).max { $0.version < $1.version }
    }

    /// The text has started: the screens show the notes (else, in Review, the study pass's
    /// Summary and Only said in class blocks while the notes are queued).
    public var hasText: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Lecture notes (`lecture_notes`) and the student's marks on them (`lecture_notes_mark`).
public struct LectureNotesRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    // MARK: Reading

    /// Every version of a lecture's notes, oldest first.
    public func versions(lectureID: Lecture.ID) async throws -> [LectureNotes] {
        try await store.database.read { db in try Self.versions(lectureID: lectureID, in: db) }
    }

    public static func versions(lectureID: Lecture.ID, in db: Database) throws -> [LectureNotes] {
        try LectureNotes.where { $0.lectureID.eq(lectureID) }.order { $0.version.asc() }.fetchAll(db)
    }

    /// The current notes of a lecture (the newest version neither discarded nor cancelled).
    public func current(lectureID: Lecture.ID) async throws -> LectureNotes? {
        try await store.database.read { db in try Self.current(lectureID: lectureID, in: db) }
    }

    public static func current(lectureID: Lecture.ID, in db: Database) throws -> LectureNotes? {
        LectureNotes.current(of: try versions(lectureID: lectureID, in: db))
    }

    public func notes(_ id: LectureNotes.ID) async throws -> LectureNotes? {
        try await store.fetch(LectureNotes.self, id: id)
    }

    /// The version a `lecture_notes` task writes.
    public func notes(taskID: AgentTask.ID) async throws -> LectureNotes? {
        let reference = AgentTask.ID?.some(taskID)
        return try await store.database.read { db in
            try LectureNotes.where { $0.taskID.eq(reference) }.fetchOne(db)
        }
    }

    /// The student's marks on a lecture's notes that are not removed, oldest first.
    public func marks(lectureID: Lecture.ID) async throws -> [LectureNotesMark] {
        try await store.database.read { db in
            try LectureNotesMark.where { $0.lectureID.eq(lectureID) && $0.removedAt.is(nil) }.order { $0.createdAt.asc() }.fetchAll(db)
        }
    }

    // MARK: Queueing (the only way a version starts)

    /// Queues a new version (an `agent_task` of kind `lecture_notes` and a `queued` row with the
    /// outline from the lecture's topics, in one transaction) unless a version of the lecture is
    /// open already, the lecture is gone, or nothing can be written from yet. The source is
    /// `recording` once the lecture's study pass synthesis is done, else `slides` for a lecture
    /// with slides and no recording. `request`: Write Again's sentence. Returns the new row.
    @discardableResult
    public func queue(lectureID: Lecture.ID, request: String? = nil, createdBy: Author) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try Self.queue(lectureID: lectureID, request: request, createdBy: createdBy, in: db, now: stamp)
        }
    }

    /// First open of a lecture's notes page or Review's Whole lecture pane (`user`): queues the
    /// first version when the lecture has none that can be current (all discarded or cancelled,
    /// or none at all) and no open one. A failed version is not queued again (Write Again is).
    @discardableResult
    public func queueIfNeeded(lectureID: Lecture.ID, createdBy: Author = .user) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let versions = try Self.versions(lectureID: lectureID, in: db)
            guard LectureNotes.current(of: versions) == nil else { return nil }
            return try Self.queue(lectureID: lectureID, request: nil, createdBy: createdBy, in: db, now: stamp)
        }
    }

    /// After the lecture's study pass synthesis is written (StudyPass; `agent`): queues a version
    /// from the recording when the lecture has no current notes, or its current notes came from
    /// the slides alone (replaced once, automatically), or were written before the lecture got its
    /// slides (`predatesSlides`: slides that arrived later, filed or found by continuation
    /// detection; the pass ran again with them; written again once, with the same Write Again
    /// sentence), or `rerun` (the student re-ran the study pass: they asked for the lecture's AI
    /// again).
    @discardableResult
    public func queueAfterStudyPass(lectureID: Lecture.ID, rerun: Bool = false) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let current = try Self.current(lectureID: lectureID, in: db)
            let stale = try current.map { try Self.predatesSlides($0, in: db) } ?? false
            guard current == nil || current?.source == .slides || stale || rerun else { return nil }
            guard try Self.source(lectureID: lectureID, in: db) == .recording else { return nil }
            let request = stale && !rerun ? current?.request : nil
            return try Self.queue(lectureID: lectureID, request: request, createdBy: .agent, in: db, now: stamp)
        }
    }

    /// Finished notes queued before the lecture's current slides were linked (its newest coarse
    /// span changed after the version was queued): written from the recording without them.
    static func predatesSlides(_ notes: LectureNotes, in db: Database) throws -> Bool {
        guard notes.state == .done, let slides = try LectureSlides.current(lectureID: notes.lectureID, in: db) else { return false }
        return slides.updatedAt > notes.createdAt
    }

    /// What a new version of the lecture would be written from now; nil: nothing yet (a recording
    /// whose study pass has not written its synthesis, or neither slides nor recording). The
    /// synthesis counts as written when its unit is done or the lecture has topic rows (a library
    /// whose topics came without units).
    public static func source(lectureID: Lecture.ID, in db: Database) throws -> LectureNotesSource? {
        let synthesized = try StudyUnit
            .where { $0.lectureID.eq(lectureID) && $0.stage.eq(StudyStage.synthesize) && $0.state.eq(ExtractionState.done) }
            .fetchCount(db)
        let reference = Lecture.ID?.some(lectureID)
        let topics = try Annotation
            .where { $0.lectureID.eq(reference) && $0.kind.eq(AnnotationKind.topic) && $0.hiddenAt.is(nil) }
            .fetchCount(db)
        if synthesized > 0 || topics > 0 { return .recording }
        let recordings = try Recording.where { $0.lectureID.eq(Lecture.ID?.some(lectureID)) }.fetchCount(db)
        guard recordings == 0, try LectureSlides.current(lectureID: lectureID, in: db) != nil else { return nil }
        return .slides
    }

    static func queue(lectureID: Lecture.ID, request: String?, createdBy: Author, in db: Database, now: Date) throws -> LectureNotes? {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { return nil }
        let versions = try versions(lectureID: lectureID, in: db)
        guard !versions.contains(where: { $0.state.isOpen }) else { return nil }
        guard let source = try source(lectureID: lectureID, in: db) else { return nil }
        let name = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = lecture.number.map { "Notes: Lecture \($0)" + (name.isEmpty ? "" : " · \(name)") } ?? "Notes: \(name.isEmpty ? "Lecture" : name)"
        let task = AgentTask(
            kind: .lectureNotes, title: String(title.prefix(80)), goal: "Write the lecture's notes.",
            model: LectureNotesCalls.writeModel, effort: LectureNotesCalls.writeEffort, tools: [],
            courseID: lecture.courseID, lectureID: lectureID, createdBy: createdBy, createdAt: now, updatedAt: now
        )
        try AgentTask.upsert { task }.execute(db)
        let trimmed = request?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = LectureNotes(
            courseID: lecture.courseID, lectureID: lectureID, version: (versions.map(\.version).max() ?? 0) + 1,
            state: .queued, source: source,
            request: trimmed.flatMap { $0.isEmpty ? nil : String($0.prefix(LectureNotes.requestLimit)) },
            sections: try outline(lectureID: lectureID, in: db), taskID: task.id, createdBy: createdBy,
            createdAt: now, updatedAt: now
        )
        try LectureNotes.upsert { notes }.execute(db)
        return notes
    }

    /// The outline from the lecture's topic rows (`annotation` ai · topic, not hidden) in lecture
    /// order: key, title, slides, start (and the next topic's start as end), whether an exam hint
    /// lies in it. The writer refines it when the version is done.
    public static func outline(lectureID: Lecture.ID, in db: Database) throws -> [LectureNotesSection] {
        let reference = Lecture.ID?.some(lectureID)
        let rows = try Annotation
            .where { $0.lectureID.eq(reference) && $0.hiddenAt.is(nil) && $0.kind.in([AnnotationKind.topic, AnnotationKind.examHint]) }
            .fetchAll(db)
        let topics = rows.filter { $0.kind == .topic }.sorted { lhs, rhs in
            let left = (lhs.startTime ?? .greatestFiniteMagnitude, lhs.pageNumber ?? .max)
            let right = (rhs.startTime ?? .greatestFiniteMagnitude, rhs.pageNumber ?? .max)
            return left.0 != right.0 ? left.0 < right.0 : left.1 < right.1
        }
        let hints = rows.filter { $0.kind == .examHint }
        var seen: Set<String> = []
        var sections: [LectureNotesSection] = []
        for (index, topic) in topics.enumerated() {
            let key = LectureNotesFormat.sectionKey(topicTitle: topic.body)
            guard !topic.body.isEmpty, seen.insert(key).inserted else { continue }
            let end = topics.dropFirst(index + 1).compactMap(\.startTime).first
            var section = LectureNotesSection(
                key: key, title: topic.body, topicID: topic.id, firstPage: topic.pageNumber,
                lastPage: topic.lastPage ?? topic.pageNumber, startTime: topic.startTime, endTime: end
            )
            section.hasExamHint = hints.contains { hint in
                if let time = hint.startTime, let start = topic.startTime { return time >= start && time < (end ?? .greatestFiniteMagnitude) }
                if let page = hint.pageNumber { return section.covers(page: page) }
                return false
            }
            sections.append(section)
        }
        return sections
    }

    // MARK: Writing a version (the writer)

    /// The writer starts (or resumes) a version: `generating`, with what it was written for.
    /// `body` stays (a resume goes on from its complete sections). From queued, paused or
    /// generating (a quit left it running); nil when it was cancelled meanwhile.
    @discardableResult
    public func begin(
        _ id: LectureNotes.ID, length: NotesLength, targetWords: Int, sections: [LectureNotesSection], inputHash: String,
        promptVersion: Int, model: String, effort: String
    ) async throws -> LectureNotes? {
        let store = store
        return try await store.database.write { db in
            guard var notes = try LectureNotes.find(id).fetchOne(db), notes.state.isOpen else { return nil }
            notes.state = .generating
            notes.length = length
            notes.targetWords = targetWords
            notes.sections = sections
            notes.inputHash = inputHash
            notes.promptVersion = promptVersion
            notes.model = model
            notes.effort = effort
            notes.pausedUntil = nil
            notes.error = nil
            let stamped = store.stamp(notes)
            try LectureNotes.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// The text so far (at most every 100 ms), only while `generating`. False when it is no longer
    /// (cancelled): the writer stops.
    @discardableResult
    public func stream(_ id: LectureNotes.ID, body: String) async throws -> Bool {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try LectureNotes
                .where { $0.id.eq(id) && $0.state.eq(LectureNotesState.generating) }
                .update { $0.body = body; $0.updatedAt = stamp }
                .execute(db)
            return db.changesCount > 0
        }
    }

    /// The checked version: `done` with its text, outline and Check yourself questions (written as
    /// `study_question` rows, origin `notes`, whose ids the outline lists), in one transaction. The
    /// unanswered notes questions of the lecture's other versions are retired (answered ones stay).
    /// nil when it was cancelled meanwhile.
    @discardableResult
    public func finish(
        _ id: LectureNotes.ID, body: String, sections: [LectureNotesSection], questions: [StudyQuestion], apiCallID: APICall.ID?,
        costUSD: Double?, repairs: Int
    ) async throws -> LectureNotes? {
        let store = store
        let stamp = store.currentDate
        return try await store.database.write { db in
            guard var notes = try LectureNotes.find(id).fetchOne(db), notes.state.isOpen else { return nil }
            let others = try Self.versions(lectureID: notes.lectureID, in: db).filter { $0.id != id }
            let older = Set(others.flatMap { $0.sections.flatMap(\.questionIDs) })
            if !older.isEmpty {
                let answered = Set(try StudyAnswer.where { $0.questionID.in(Array(older)) }.fetchAll(db).map(\.questionID))
                let retire = Array(older.subtracting(answered))
                try StudyQuestion
                    .where { $0.id.in(retire) && $0.retiredAt.is(nil) }
                    .update { $0.retiredAt = Date?.some(stamp); $0.updatedAt = stamp }
                    .execute(db)
            }
            for question in questions {
                let stamped = store.stamp(question)
                try StudyQuestion.upsert { stamped }.execute(db)
            }
            notes.state = .done
            notes.body = body
            notes.sections = sections
            notes.apiCallID = apiCallID ?? notes.apiCallID
            notes.costUSD = costUSD
            notes.repairs = repairs
            notes.error = nil
            notes.pausedUntil = nil
            notes.finishedAt = stamp
            let stamped = store.stamp(notes)
            try LectureNotes.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// It could not be written: `failed` with one readable sentence; `body` (when given) keeps what
    /// came.
    public func fail(_ id: LectureNotes.ID, error: String, body: String? = nil, costUSD: Double? = nil) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var notes = try LectureNotes.find(id).fetchOne(db), notes.state.isOpen else { return }
            notes.state = .failed
            notes.error = error
            if let body { notes.body = body }
            if let costUSD { notes.costUSD = costUSD }
            notes.pausedUntil = nil
            notes.finishedAt = stamp
            notes.updatedAt = stamp
            try LectureNotes.upsert { notes }.execute(db)
        }
    }

    /// A usage limit: `paused` until the reset (the task is paused by the queue); what came stays.
    public func pause(_ id: LectureNotes.ID, until: Date, body: String? = nil) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var notes = try LectureNotes.find(id).fetchOne(db), notes.state.isOpen else { return }
            notes.state = .paused
            notes.pausedUntil = until
            if let body { notes.body = body }
            notes.updatedAt = stamp
            try LectureNotes.upsert { notes }.execute(db)
        }
    }

    // MARK: Versions (Write Again, Previous Version, Undo)

    /// Cancels an open version and its task (Undo of the agent's write_lecture_notes while it is
    /// written, Cancel in the panel's task list; the queue stops a running task whose row was
    /// cancelled). False when it was not open.
    @discardableResult
    public func cancel(_ id: LectureNotes.ID) async throws -> Bool {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try Self.cancel(id, in: db, now: stamp)
        }
    }

    static func cancel(_ id: LectureNotes.ID, in db: Database, now: Date) throws -> Bool {
        guard var notes = try LectureNotes.find(id).fetchOne(db), notes.state.isOpen else { return false }
        notes.state = .cancelled
        notes.pausedUntil = nil
        notes.finishedAt = now
        notes.updatedAt = now
        try LectureNotes.upsert { notes }.execute(db)
        if let taskID = notes.taskID {
            try AgentTask
                .where { $0.id.eq(taskID) && $0.state.in(AgentTaskState.open) }
                .update { $0.state = AgentTaskState.cancelled; $0.finishedAt = Date?.some(now); $0.updatedAt = now }
                .execute(db)
        }
        return true
    }

    /// The `lecture_notes` task was cancelled from outside (the panel's task list, cancel_task): its
    /// open version is cancelled too.
    public func cancel(taskID: AgentTask.ID) async throws {
        let stamp = store.currentDate
        let reference = AgentTask.ID?.some(taskID)
        try await store.database.write { db in
            let versions = try LectureNotes.where { $0.taskID.eq(reference) }.fetchAll(db)
            for notes in versions {
                _ = try Self.cancel(notes.id, in: db, now: stamp)
            }
        }
    }

    /// Previous Version (Edit ▸ Undo "Undo Write Again"): the current version is discarded, or
    /// cancelled while it is still being written, so the one before is current again. Only when an
    /// earlier candidate exists. Returns the version it took away (Redo: `restore`).
    @discardableResult
    public func previousVersion(lectureID: Lecture.ID) async throws -> LectureNotes.ID? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let versions = try Self.versions(lectureID: lectureID, in: db)
            guard let current = LectureNotes.current(of: versions),
                  versions.contains(where: { $0.isCandidate && $0.version < current.version }) else { return nil }
            if current.state.isOpen {
                _ = try Self.cancel(current.id, in: db, now: stamp)
            } else {
                try LectureNotes.where { $0.id.eq(current.id) }
                    .update { $0.discardedAt = Date?.some(stamp); $0.updatedAt = stamp }
                    .execute(db)
            }
            return current.id
        }
    }

    /// Redo of Previous Version: a discarded version is a candidate again (a cancelled one stays
    /// cancelled: Write Again writes it anew).
    public func restore(_ id: LectureNotes.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try LectureNotes.where { $0.id.eq(id) }
                .update { $0.discardedAt = Date?.none; $0.updatedAt = stamp }
                .execute(db)
        }
    }

    // MARK: Marks

    /// Keeps a highlight or an answer (the capsule, the menu, Keep, the agent's keep_notes_answer).
    @discardableResult
    public func addMark(_ mark: LectureNotesMark) async throws -> LectureNotesMark {
        try await store.save(mark)
    }

    /// Remove Highlight, Remove from Notes. Edit ▸ Undo: `restoreMark`.
    public func removeMark(_ id: LectureNotesMark.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try LectureNotesMark.where { $0.id.eq(id) && $0.removedAt.is(nil) }
                .update { $0.removedAt = Date?.some(stamp); $0.updatedAt = stamp }
                .execute(db)
        }
    }

    public func restoreMark(_ id: LectureNotesMark.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try LectureNotesMark.where { $0.id.eq(id) }
                .update { $0.removedAt = Date?.none; $0.updatedAt = stamp }
                .execute(db)
        }
    }

    /// The current version no longer holds a mark's passage (`true`), or holds it again.
    public func setOrphaned(_ id: LectureNotesMark.ID, _ orphaned: Bool) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            if orphaned {
                try LectureNotesMark.where { $0.id.eq(id) && $0.orphanedAt.is(nil) }
                    .update { $0.orphanedAt = Date?.some(stamp); $0.updatedAt = stamp }
                    .execute(db)
            } else {
                try LectureNotesMark.where { $0.id.eq(id) && $0.orphanedAt.isNot(nil) }
                    .update { $0.orphanedAt = Date?.none; $0.updatedAt = stamp }
                    .execute(db)
            }
        }
    }
}
