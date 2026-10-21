import Foundation
import SQLiteData

// Repositories added with schema v16 (ln: lecture notes). The rules (what the writer reads, the
// prompt, validation, asking) live in StudyPass (`NotesWriter`, `NotesAsker`) and AppAgent (the
// task runner, the agent's actions); the screens (StudyPage, Courses, Review) read rows and write
// marks and versions through this. docs/plan-lecture-notes.md §5 and its "Build plan".

extension LectureNotes {
    /// The writer found nothing to write from (`LectureNotesRepository.waitForMaterial`): not an
    /// error, so no triangle. The version waits: it is never the current notes, and a new one is
    /// queued when the material arrives (`requeueWaiting`) or the lecture is opened again.
    public static let nothingToWriteFrom = "There is nothing to write these notes from yet."

    /// A version set aside because there was nothing to write it from (a `failed` row with that
    /// sentence and no text; rows written before 2026-10-21 look the same).
    public var isWaitingForMaterial: Bool { state == .failed && error == Self.nothingToWriteFrom && !hasText }

    /// A version that can be the current notes: neither discarded, cancelled nor waiting for its
    /// material.
    public var isCandidate: Bool { discardedAt == nil && state != .cancelled && !isWaitingForMaterial }

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
    /// first version when the lecture has none that can be current (all discarded, cancelled or
    /// waiting for their material, or none at all) and no open one. A failed version is not
    /// queued again (Write Again is).
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
    /// the slides alone (replaced once, automatically), or `rerun` (the student re-ran the study
    /// pass: they asked for the lecture's AI again).
    @discardableResult
    public func queueAfterStudyPass(lectureID: Lecture.ID, rerun: Bool = false) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let current = try Self.current(lectureID: lectureID, in: db)
            guard current == nil || current?.source == .slides || rerun else { return nil }
            let inputs = try Self.inputs(lectureID: lectureID, in: db)
            guard inputs.source == .recording else {
                Log.lectureNotes.notice(
                    "Notes for lecture \(ChatCitation.key(lectureID), privacy: .public) not queued after the study pass: \(inputs.summary, privacy: .public)"
                )
                return nil
            }
            return try Self.queue(lectureID: lectureID, request: nil, createdBy: .agent, in: db, now: stamp)
        }
    }

    /// The material arrived for lectures whose notes wait for it (`isWaitingForMaterial`; a deck's
    /// pages or a lecture's range were written, by filing, a link or sync): a new version is
    /// queued for each that has no current or open version and can be written now, with the
    /// waiting version's sentence and author. The task queue calls this when `deck_page` or
    /// `lecture_deck_span` change, and once at launch. Returns the versions queued.
    @discardableResult
    public func requeueWaiting() async throws -> [LectureNotes] {
        let stamp = store.currentDate
        let sentence = LectureNotes.nothingToWriteFrom
        let any = try await store.database.read { db in
            try LectureNotes.where { $0.state.eq(LectureNotesState.failed) && $0.error.eq(String?.some(sentence)) }.fetchCount(db)
        }
        guard any > 0 else { return [] }
        return try await store.database.write { db in
            let waiting = try LectureNotes
                .where { $0.state.eq(LectureNotesState.failed) && $0.error.eq(String?.some(sentence)) }
                .fetchAll(db)
                .filter(\.isWaitingForMaterial)
            var queued: [LectureNotes] = []
            for lectureID in Set(waiting.map(\.lectureID)) {
                let versions = try Self.versions(lectureID: lectureID, in: db)
                guard LectureNotes.current(of: versions) == nil, !versions.contains(where: { $0.state.isOpen }),
                      let newest = versions.last(where: \.isWaitingForMaterial),
                      try Self.inputs(lectureID: lectureID, in: db).source != nil
                else { continue }
                guard let notes = try Self.queue(lectureID: lectureID, request: newest.request, createdBy: newest.createdBy, in: db, now: stamp)
                else { continue }
                Log.lectureNotes.notice(
                    "Notes for lecture \(ChatCitation.key(lectureID), privacy: .public) queued again: their material arrived (v\(notes.version, privacy: .public), \(notes.source.rawValue, privacy: .public))"
                )
                queued.append(notes)
            }
            return queued
        }
    }

    /// What a new version of the lecture would be written from now; nil: nothing yet (a recording
    /// whose study pass has not written its synthesis, a range of slides whose deck has no pages
    /// there, or neither slides nor recording). `LectureNotesInputs.source` has the rules.
    public static func source(lectureID: Lecture.ID, in db: Database) throws -> LectureNotesSource? {
        try inputs(lectureID: lectureID, in: db).source
    }

    /// What the notes writer could read about the lecture now, counted (the writer's
    /// `NotesMaterial` reads the same rows).
    public static func inputs(lectureID: Lecture.ID, in db: Database) throws -> LectureNotesInputs {
        let reference = Lecture.ID?.some(lectureID)
        let synthesized = try StudyUnit
            .where { $0.lectureID.eq(lectureID) && $0.stage.eq(StudyStage.synthesize) && $0.state.eq(ExtractionState.done) }
            .fetchCount(db)
        let topics = try Annotation
            .where { $0.lectureID.eq(reference) && $0.kind.eq(AnnotationKind.topic) && $0.hiddenAt.is(nil) }
            .fetchCount(db)
        let lines = try TranscriptSegment.where { $0.lectureID.eq(reference) }.fetchCount(db)
        let recordings = try Recording.where { $0.lectureID.eq(reference) }.fetchCount(db)
        let range = try LectureSlides.current(lectureID: lectureID, in: db)
        var pages = 0
        if let range {
            let deckID = range.deckID
            let first = range.firstPage
            let last = range.lastPage
            pages = try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.gte(first) && $0.pageNumber.lte(last) }.fetchCount(db)
        }
        return LectureNotesInputs(
            synthesized: synthesized > 0, topics: topics, transcriptLines: lines, recordings: recordings, range: range, rangePages: pages
        )
    }

    static func queue(lectureID: Lecture.ID, request: String?, createdBy: Author, in db: Database, now: Date) throws -> LectureNotes? {
        let key = ChatCitation.key(lectureID)
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else {
            Log.lectureNotes.notice("Notes for lecture \(key, privacy: .public) not queued: the lecture is gone")
            return nil
        }
        let versions = try versions(lectureID: lectureID, in: db)
        if let open = versions.first(where: { $0.state.isOpen }) {
            Log.lectureNotes.notice(
                "Notes for lecture \(key, privacy: .public) not queued: v\(open.version, privacy: .public) is \(open.state.rawValue, privacy: .public)"
            )
            return nil
        }
        let inputs = try inputs(lectureID: lectureID, in: db)
        guard let source = inputs.source else {
            Log.lectureNotes.notice("Notes for lecture \(key, privacy: .public) not queued: nothing to write from (\(inputs.summary, privacy: .public))")
            return nil
        }
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
        Log.lectureNotes.notice(
            "Notes for lecture \(key, privacy: .public) queued: v\(notes.version, privacy: .public) \(ChatCitation.key(notes.id), privacy: .public) from the \(source.rawValue, privacy: .public) (\(inputs.summary, privacy: .public)), by \(createdBy.rawValue, privacy: .public)"
        )
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

    /// The writer found nothing to write from (the slides or the transcript went between queueing
    /// and writing): the version waits for its material (`isWaitingForMaterial`), quietly; never
    /// the current notes. Only an open version.
    public func waitForMaterial(_ id: LectureNotes.ID) async throws {
        try await fail(id, error: LectureNotes.nothingToWriteFrom)
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
        Log.lectureNotes.notice(
            "Notes \(ChatCitation.key(id), privacy: .public) cancelled: v\(notes.version, privacy: .public) of lecture \(ChatCitation.key(notes.lectureID), privacy: .public) was \(notes.state.rawValue, privacy: .public)"
        )
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

/// What a lecture's notes could be written from now (`LectureNotesRepository.inputs`): the counts
/// that decide `source`, and their one-line summary for the log (counts and pages only, never
/// lecture content).
public struct LectureNotesInputs: Sendable, Hashable {
    /// The study pass's synthesis unit is done.
    public var synthesized: Bool
    /// Topic rows (`annotation` ai · topic, not hidden).
    public var topics: Int
    /// The lecture's transcript lines (`transcript_segment`).
    public var transcriptLines: Int
    public var recordings: Int
    /// The lecture's slides (`LectureSlides.current`).
    public var range: LectureSlideRange?
    /// The deck's pages inside that range.
    public var rangePages: Int

    public init(synthesized: Bool, topics: Int, transcriptLines: Int, recordings: Int, range: LectureSlideRange?, rangePages: Int) {
        self.synthesized = synthesized
        self.topics = topics
        self.transcriptLines = transcriptLines
        self.recordings = recordings
        self.range = range
        self.rangePages = rangePages
    }

    /// `recording` once the study pass wrote its synthesis (its unit done, or topic rows: a library
    /// whose topics came without units) and the lecture has transcript lines; else `slides` for a
    /// lecture without a recording whose range of slides has pages (topic rows without a
    /// transcript, left by a recording moved to another lecture, do not count); else nil.
    public var source: LectureNotesSource? {
        if transcriptLines > 0, synthesized || topics > 0 { return .recording }
        if recordings == 0, rangePages > 0 { return .slides }
        return nil
    }

    /// "transcript 0 lines, 0 recordings, synthesis no, 5 topics, slides 1–50: 0 pages".
    public var summary: String {
        var text = "transcript \(transcriptLines) lines, \(recordings) recordings, synthesis \(synthesized ? "done" : "no"), \(topics) topics, "
        if let range {
            text += "slides \(range.firstPage)–\(range.lastPage) of deck \(ChatCitation.key(range.deckID)): \(rangePages) pages"
        } else {
            text += "no slides"
        }
        return text
    }
}
