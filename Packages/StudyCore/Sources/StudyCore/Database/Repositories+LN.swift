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
    public static let nothingToWriteFrom = "There is nothing to write this summary from yet."

    /// The sentence before the notes were called Summary (2026-10-22): rows that wait with it
    /// still wait.
    static let nothingToWriteFromBefore = "There is nothing to write these notes from yet."

    /// Either sentence (`nothingToWriteFrom`, `nothingToWriteFromBefore`).
    public static let nothingToWriteFromSentences = [nothingToWriteFrom, nothingToWriteFromBefore]

    /// A version set aside because there was nothing to write it from (a `failed` row with that
    /// sentence and no text; rows written before 2026-10-21 look the same).
    public var isWaitingForMaterial: Bool {
        state == .failed && error.map(Self.nothingToWriteFromSentences.contains) == true && !hasText
    }

    /// Write Again on a finished Summary while its recording's study pass is on its way
    /// (`WriteAgainOutcome.waiting`): the row holds the student's instruction until the pass
    /// writes the version from the recording with it. Never shown, never current.
    static let waitingToWrite = "This summary is written again when its recording is ready."

    /// A Write Again that waits for its recording (a `failed` row with `waitingToWrite`, no text,
    /// no task).
    public var isWaitingToWrite: Bool { state == .failed && error == Self.waitingToWrite && !hasText }

    /// A version that can be the current notes: neither discarded, cancelled nor waiting (for its
    /// material or, a Write Again, for its recording).
    public var isCandidate: Bool { discardedAt == nil && state != .cancelled && !isWaitingForMaterial && !isWaitingToWrite }

    /// The student's Write Again that waits for its recording: the newest version neither
    /// discarded nor cancelled, when it is such a row (a version queued after it took it up).
    public static func pendingWriteAgain(of versions: [LectureNotes]) -> LectureNotes? {
        guard let newest = versions.filter({ $0.discardedAt == nil && $0.state != .cancelled }).max(by: { $0.version < $1.version }),
              newest.isWaitingToWrite
        else { return nil }
        return newest
    }

    /// The current notes among a lecture's versions: the newest candidate.
    public static func current(of versions: [LectureNotes]) -> LectureNotes? {
        versions.filter(\.isCandidate).max { $0.version < $1.version }
    }

    /// The text has started: the screens show the notes (else, in Review, the study pass's
    /// Summary and Only said in class blocks while the notes are queued).
    public var hasText: Bool { !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The student's standing instruction for the lecture's Summary: the `request` of the newest
    /// version neither discarded nor cancelled (failed and waiting versions count). Every version
    /// is written with the instruction it carries on (`NotesInstruction.standing`), so Previous
    /// Version (or cancelling an open Write Again) takes a new instruction back and Redo restores
    /// it, with nothing stored apart.
    public static func instruction(of versions: [LectureNotes]) -> String? {
        versions.filter { $0.discardedAt == nil && $0.state != .cancelled }.max { $0.version < $1.version }?.request
    }
}

/// Write Again of a lecture's Summary as the app runs it: Retry of a blocked recording first, then
/// `LectureNotesRepository.writeAgain` (the app's `NotesWriteAgain`, one action behind the
/// Summary's Write Again and the agent's write_lecture_notes).
public typealias NotesWriteAgain = @Sendable (_ lectureID: Lecture.ID, _ instruction: NotesInstruction, _ createdBy: Author) async throws -> WriteAgainOutcome

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

    /// Write Again (the page's ⋯, the failure line, Review's Summary) and the agent's
    /// write_lecture_notes: the student's own act, with `instruction`. In one transaction:
    /// - a version open with the same instruction: nothing (`.writing`); with another, it is
    ///   cancelled (the student's act wins) and theirs follows;
    /// - a finished Summary (or nothing to write from) while the recording's study pass is on its
    ///   way (`LectureNotesInputs.studyPassComing`): the instruction waits on a row
    ///   (`isWaitingToWrite`) and the pass writes the one version from the recording with it
    ///   (`queueAfterStudyPass`; from what there is when the way ends blocked,
    ///   `queueDueReplacement`), no call now (`.waiting`);
    /// - else a new version (an `agent_task` of kind `lecture_notes` and a `queued` row with the
    ///   outline) from whatever there is to write from now (`LectureNotesInputs.available`).
    /// `.nothingToWriteFrom` (the log says why) with nothing at all, or when the lecture is gone.
    /// The app retries a blocked recording first (`NotesWriteAgain`), so its way is on its way
    /// again here.
    public func writeAgain(lectureID: Lecture.ID, instruction: NotesInstruction, createdBy: Author) async throws -> WriteAgainOutcome {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let key = ChatCitation.key(lectureID)
            guard let lecture = try Lecture.find(lectureID).fetchOne(db) else {
                Log.lectureNotes.notice("Notes for lecture \(key, privacy: .public) not written again: the lecture is gone")
                return .nothingToWriteFrom
            }
            var versions = try Self.versions(lectureID: lectureID, in: db)
            let request = instruction.request(after: versions)
            if let open = versions.first(where: { $0.state.isOpen }) {
                guard open.request != request else {
                    Log.lectureNotes.notice(
                        "Notes for lecture \(key, privacy: .public) not written again: v\(open.version, privacy: .public) with the same instruction is \(open.state.rawValue, privacy: .public)"
                    )
                    return .writing(open)
                }
                _ = try Self.cancel(open.id, in: db, now: stamp)
                versions = try Self.versions(lectureID: lectureID, in: db)
            }
            let inputs = try Self.inputs(lectureID: lectureID, in: db)
            if inputs.studyPassComing, LectureNotes.current(of: versions)?.state == .done || inputs.available == nil {
                let row = try Self.waitingRow(
                    courseID: lecture.courseID, lectureID: lectureID, request: request, error: LectureNotes.waitingToWrite, createdBy: createdBy,
                    versions: versions, in: db, now: stamp
                )
                Log.lectureNotes.notice(
                    "Notes for lecture \(key, privacy: .public) written again once the recording is ready: v\(row.version, privacy: .public) waits (\(inputs.summary, privacy: .public)), \(request == nil ? "no instruction" : "with the instruction", privacy: .public), by \(createdBy.rawValue, privacy: .public)"
                )
                return .waiting(row)
            }
            // The instruction as it stood before a cancel (a cancelled version's is no longer read).
            guard let source = inputs.available,
                  let notes = try Self.queue(
                      lectureID: lectureID, source: source, instruction: .new(request ?? ""), createdBy: createdBy, inputs: inputs, in: db, now: stamp
                  )
            else {
                Log.lectureNotes.notice(
                    "Notes for lecture \(key, privacy: .public) not written again: nothing to write from (\(inputs.summary, privacy: .public))"
                )
                return .nothingToWriteFrom
            }
            return .queued(notes)
        }
    }

    /// How the lecture's recording is getting into its Summary now (the app's Write Again retries
    /// a blocked way before it writes).
    public func recording(lectureID: Lecture.ID) async throws -> RecordingNotesState {
        try await store.database.read { db in try Self.inputs(lectureID: lectureID, in: db).recording }
    }

    /// A row that only holds an instruction (`request`): a `failed` version without text or task
    /// whose `error` says what it waits for (`waitingToWrite`: a Write Again waiting for the
    /// recording; `nothingToWriteFrom`: an instruction kept for later versions). Never current;
    /// `LectureNotes.instruction(of:)` counts it.
    static func waitingRow(
        courseID: Course.ID, lectureID: Lecture.ID, request: String?, error: String, createdBy: Author, versions: [LectureNotes], in db: Database,
        now: Date
    ) throws -> LectureNotes {
        let row = LectureNotes(
            courseID: courseID, lectureID: lectureID, version: (versions.map(\.version).max() ?? 0) + 1, state: .failed, source: .recording,
            request: request, error: error, createdBy: createdBy, createdAt: now, updatedAt: now
        )
        try LectureNotes.upsert { row }.execute(db)
        return row
    }

    /// A lecture merge (Filing): the instruction of the lecture that went is kept on the survivor
    /// (a row `isWaitingForMaterial`, never current, no task) when the survivor has none of its
    /// own. Returns the row (the merge's Undo deletes it), nil when nothing was kept.
    public static func keepInstruction(of loser: [LectureNotes], on survivor: Lecture, in db: Database, now: Date) throws -> LectureNotes? {
        guard let request = LectureNotes.instruction(of: loser) else { return nil }
        let versions = try versions(lectureID: survivor.id, in: db)
        guard LectureNotes.instruction(of: versions) == nil else { return nil }
        let row = try waitingRow(
            courseID: survivor.courseID, lectureID: survivor.id, request: request, error: LectureNotes.nothingToWriteFrom, createdBy: .user,
            versions: versions, in: db, now: now
        )
        Log.lectureNotes.notice(
            "Notes for lecture \(ChatCitation.key(survivor.id), privacy: .public) keep the instruction of a merged lecture (v\(row.version, privacy: .public))"
        )
        return row
    }

    /// First open of a lecture's notes page or Review's Summary tab (`user`): queues the first
    /// version when the lecture has none that can be current (all discarded, cancelled or waiting
    /// for their material, or none at all) and no open one, from what the automatic rule allows
    /// (`LectureNotesInputs.source`). A failed version is not queued again (Write Again is). With a
    /// current version, the catch-up of the replace-once rules (`queueDueReplacement`).
    @discardableResult
    public func queueIfNeeded(lectureID: Lecture.ID, createdBy: Author = .user) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let versions = try Self.versions(lectureID: lectureID, in: db)
            guard LectureNotes.current(of: versions) == nil else {
                return try Self.queueDueReplacement(lectureID: lectureID, versions: versions, in: db, now: stamp)
            }
            let inputs = try Self.inputs(lectureID: lectureID, in: db)
            guard let source = inputs.source else {
                Log.lectureNotes.notice(
                    "Notes for lecture \(ChatCitation.key(lectureID), privacy: .public) not queued: nothing to write from (\(inputs.summary, privacy: .public))"
                )
                return nil
            }
            return try Self.queue(lectureID: lectureID, source: source, instruction: .standing, createdBy: createdBy, inputs: inputs, in: db, now: stamp)
        }
    }

    /// After the lecture's study pass synthesis is written (StudyPass; `agent`): queues a version
    /// from the recording when the lecture has no current notes, or its current notes came from
    /// the slides alone (replaced once, automatically), or were written before the lecture got its
    /// slides (`predatesSlides`: slides that arrived later, filed or found by continuation
    /// detection; the pass ran again with them) or before one of its recordings
    /// (`predatesRecording`: another recording of the class whose transcript came later), or
    /// without the study pass's topics (`predatesTopics`: Write Again while the synthesis was on
    /// its way or had failed), or the student re-ran the study pass (`rerunAsked`), or a Write
    /// Again waits for it (`asked`, `pendingWriteAgain`). Each holds once. Always with the
    /// student's standing instruction.
    @discardableResult
    public func queueAfterStudyPass(lectureID: Lecture.ID) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let versions = try Self.versions(lectureID: lectureID, in: db)
            let asked = LectureNotes.pendingWriteAgain(of: versions)
            let reason = try asked.map { _ in Replacement.asked }
                ?? Self.replacement(of: LectureNotes.current(of: versions), includingStale: true, in: db)
            guard let reason else { return nil }
            let inputs = try Self.inputs(lectureID: lectureID, in: db)
            guard inputs.recordingReady else {
                Log.lectureNotes.notice(
                    "Notes for lecture \(ChatCitation.key(lectureID), privacy: .public) not queued after the study pass: \(inputs.summary, privacy: .public)"
                )
                return nil
            }
            Log.lectureNotes.notice(
                "Notes for lecture \(ChatCitation.key(lectureID), privacy: .public) written again after the study pass: \(reason.rawValue, privacy: .public)"
            )
            return try Self.queue(
                lectureID: lectureID, source: .recording, instruction: .standing, createdBy: asked?.createdBy ?? .agent, inputs: inputs, in: db, now: stamp
            )
        }
    }

    /// The catch-up of the replace-once rules after a version settles (the task queue) or when
    /// the Summary opens (`queueIfNeeded`): a version was still open when the synthesis landed, or
    /// the app quit between. Returns the version queued.
    @discardableResult
    public func queueDueReplacement(lectureID: Lecture.ID) async throws -> LectureNotes? {
        let stamp = store.currentDate
        return try await store.database.write { db in
            try Self.queueDueReplacement(lectureID: lectureID, versions: try Self.versions(lectureID: lectureID, in: db), in: db, now: stamp)
        }
    }

    /// The catch-up, inside the caller's transaction, with no version open:
    /// - a Write Again that waits for its recording (`pendingWriteAgain`), once nothing is on its
    ///   way any more: from the recording when it is ready (no synthesis or cover unit pending),
    ///   else from what there is (its way ended blocked, or the recording went);
    /// - the replace-once rules, only once the recording is ready, with no synthesis or cover unit
    ///   pending (the pass queues them itself then), and only over the lecture's newest version
    ///   (it never undoes Previous Version or a cancel; a row only waiting for material does not
    ///   count): for a current version from the slides, one written without the topics, or a
    ///   re-run the student asked for. New slides and a new recording stay the pass's (it plans
    ///   again first).
    static func queueDueReplacement(lectureID: Lecture.ID, versions: [LectureNotes], in db: Database, now: Date) throws -> LectureNotes? {
        guard !versions.contains(where: { $0.state.isOpen }) else { return nil }
        let key = ChatCitation.key(lectureID)
        if let asked = LectureNotes.pendingWriteAgain(of: versions) {
            let inputs = try inputs(lectureID: lectureID, in: db)
            guard !inputs.studyPassComing, !(try inputs.recordingReady && passPending(lectureID: lectureID, in: db)),
                  let source = inputs.available
            else { return nil }
            Log.lectureNotes.notice(
                "Notes for lecture \(key, privacy: .public) written again (asked, caught up): the recording is \(inputs.recording.logDescription, privacy: .public)"
            )
            return try queue(lectureID: lectureID, source: source, instruction: .standing, createdBy: asked.createdBy, inputs: inputs, in: db, now: now)
        }
        guard let current = LectureNotes.current(of: versions), current.id == versions.last(where: { !$0.isWaitingForMaterial })?.id,
              let reason = try replacement(of: current, includingStale: false, in: db)
        else { return nil }
        let inputs = try inputs(lectureID: lectureID, in: db)
        guard inputs.recordingReady, try !passPending(lectureID: lectureID, in: db) else { return nil }
        Log.lectureNotes.notice(
            "Notes for lecture \(key, privacy: .public) written again (caught up): \(reason.rawValue, privacy: .public)"
        )
        return try queue(lectureID: lectureID, source: .recording, instruction: .standing, createdBy: .agent, inputs: inputs, in: db, now: now)
    }

    /// The lecture's synthesis or cover unit is pending: the pass queues the notes itself once it
    /// lands (`queueAfterStudyPass`).
    static func passPending(lectureID: Lecture.ID, in db: Database) throws -> Bool {
        let stages = [StudyStage.synthesize, StudyStage.cover]
        return try StudyUnit
            .where { $0.lectureID.eq(lectureID) && $0.stage.in(stages) && $0.state.eq(ExtractionState.pending) }
            .fetchCount(db) > 0
    }

    /// Why a lecture's current notes are written again from the recording.
    enum Replacement: String {
        case first = "no current version"
        case fromSlides = "written from the slides"
        case predatesSlides = "written before its slides"
        case predatesRecording = "written before one of its recordings"
        case predatesTopics = "written without the study pass's topics"
        case rerun = "the study pass was run again"
        case asked = "a Write Again waited for it"
    }

    /// The reason to replace `current` once the recording's study pass is written (nil: none);
    /// `includingStale`: also new slides and a new recording (the pass's own reasons).
    static func replacement(of current: LectureNotes?, includingStale: Bool, in db: Database) throws -> Replacement? {
        guard let current else { return .first }
        if current.source == .slides { return .fromSlides }
        if includingStale {
            if try predatesSlides(current, in: db) { return .predatesSlides }
            if try predatesRecording(current, in: db) { return .predatesRecording }
        }
        if try predatesTopics(current, in: db) { return .predatesTopics }
        if try rerunAsked(after: current, in: db) { return .rerun }
        return nil
    }

    /// The material arrived for lectures whose notes wait for it (`isWaitingForMaterial`; a deck's
    /// pages or a lecture's range were written, by filing, a link or sync): a new version is
    /// queued for each that has no current or open version and can be written now, with the
    /// student's standing instruction and the waiting version's author. The task queue calls this
    /// when `deck_page` or `lecture_deck_span` change, and once at launch. Returns the versions
    /// queued.
    @discardableResult
    public func requeueWaiting() async throws -> [LectureNotes] {
        let stamp = store.currentDate
        let sentences = LectureNotes.nothingToWriteFromSentences.map { String?.some($0) }
        let any = try await store.database.read { db in
            try LectureNotes.where { $0.state.eq(LectureNotesState.failed) && $0.error.in(sentences) }.fetchCount(db)
        }
        guard any > 0 else { return [] }
        return try await store.database.write { db in
            let waiting = try LectureNotes
                .where { $0.state.eq(LectureNotesState.failed) && $0.error.in(sentences) }
                .fetchAll(db)
                .filter(\.isWaitingForMaterial)
            var queued: [LectureNotes] = []
            for lectureID in Set(waiting.map(\.lectureID)) {
                let versions = try Self.versions(lectureID: lectureID, in: db)
                guard LectureNotes.current(of: versions) == nil, !versions.contains(where: { $0.state.isOpen }),
                      let newest = versions.last(where: \.isWaitingForMaterial)
                else { continue }
                let inputs = try Self.inputs(lectureID: lectureID, in: db)
                guard let source = inputs.source,
                      let notes = try Self.queue(
                          lectureID: lectureID, source: source, instruction: .standing, createdBy: newest.createdBy, inputs: inputs, in: db, now: stamp
                      )
                else { continue }
                Log.lectureNotes.notice(
                    "Notes for lecture \(ChatCitation.key(lectureID), privacy: .public) queued again: their material arrived (v\(notes.version, privacy: .public), \(notes.source.rawValue, privacy: .public))"
                )
                queued.append(notes)
            }
            return queued
        }
    }

    /// Finished notes queued before the lecture's current slides were linked (its newest coarse
    /// span changed after the version was queued): written from the recording without them.
    static func predatesSlides(_ notes: LectureNotes, in db: Database) throws -> Bool {
        guard notes.state == .done, let slides = try LectureSlides.current(lectureID: notes.lectureID, in: db) else { return false }
        return slides.updatedAt > notes.createdAt
    }

    /// Finished notes of a lecture with several recordings, queued before one of them had its
    /// transcript in the lecture (the oldest `updated_at` of its lines: transcribed, or moved in
    /// by filing, after the version was queued): written without it. A new version is queued
    /// after it, so this holds once per arrival. Also a version written before a lecture's notes
    /// covered every recording (2026-10-21: its timed sections name no recording; a new version's
    /// do), once.
    static func predatesRecording(_ notes: LectureNotes, in db: Database) throws -> Bool {
        guard notes.state == .done else { return false }
        let lectureID = Lecture.ID?.some(notes.lectureID)
        let arrivals = try TranscriptSegment
            .where { $0.lectureID.eq(lectureID) }
            .group(by: \.recordingID)
            .select { ($0.recordingID, $0.updatedAt.min()) }
            .fetchAll(db)
        guard arrivals.count > 1 else { return false }
        if arrivals.contains(where: { _, arrived in arrived.map { $0 > notes.createdAt } ?? false }) { return true }
        let timed = notes.sections.filter { $0.startTime != nil }
        return !timed.isEmpty && timed.allSatisfy { $0.recordingID == nil }
    }

    /// Finished notes written from the recording without the study pass's topics (none of its
    /// sections came from a topic row: Write Again while the synthesis was on its way or had
    /// failed), on a lecture whose topic rows were written after it was queued: once more, from
    /// them. The new version is newer than its topics, so this holds once per synthesis.
    static func predatesTopics(_ notes: LectureNotes, in db: Database) throws -> Bool {
        guard notes.state == .done, notes.source == .recording, !notes.sections.contains(where: { $0.topicID != nil }) else { return false }
        let reference = Lecture.ID?.some(notes.lectureID)
        let queued = notes.createdAt
        let newer = try Annotation
            .where { $0.lectureID.eq(reference) && $0.kind.eq(AnnotationKind.topic) && $0.hiddenAt.is(nil) && $0.createdAt.gt(queued) }
            .select(\.id)
            .fetchAll(db)
        return !newer.isEmpty
    }

    /// The student re-ran the lecture's study pass after the version was queued (a succeeded
    /// `study_pass` task: the agent's rerun_study_pass, which only resets the pass's units): they
    /// asked for the lecture's AI again, so its next synthesis writes the notes again, once. Not
    /// when the version was written from the re-run's topics already (it began after that
    /// synthesis landed: one of its sections names a topic row there is now, and a synthesis
    /// writes its topic rows anew).
    static func rerunAsked(after notes: LectureNotes, in db: Database) throws -> Bool {
        let reference = Lecture.ID?.some(notes.lectureID)
        let queued = notes.createdAt
        let tasks = try AgentTask
            .where {
                $0.kind.eq(AgentTaskKind.studyPass) && $0.lectureID.eq(reference) && $0.state.eq(AgentTaskState.succeeded)
                    && $0.createdAt.gt(queued)
            }
            .select(\.id)
            .fetchAll(db)
        guard !tasks.isEmpty else { return false }
        let used = Set(notes.sections.compactMap(\.topicID))
        guard !used.isEmpty else { return true }
        let topics = try Annotation
            .where { $0.lectureID.eq(reference) && $0.kind.eq(AnnotationKind.topic) }
            .select(\.id)
            .fetchAll(db)
        return used.isDisjoint(with: topics)
    }

    /// What the notes writer could read about the lecture now, counted (the writer's
    /// `NotesMaterial` reads the same rows), and how its recording is getting there
    /// (`RecordingNotesState`). Reads only the job columns the state needs: screens observe this.
    public static func inputs(lectureID: Lecture.ID, in db: Database) throws -> LectureNotesInputs {
        let reference = Lecture.ID?.some(lectureID)
        let syntheses = try StudyUnit
            .where { $0.lectureID.eq(lectureID) && $0.stage.eq(StudyStage.synthesize) }
            .select { ($0.state, $0.error, $0.updatedAt) }
            .fetchAll(db)
        let synthesis = syntheses.max { $0.2 < $1.2 }
        let topics = try Annotation
            .where { $0.lectureID.eq(reference) && $0.kind.eq(AnnotationKind.topic) && $0.hiddenAt.is(nil) }
            .fetchCount(db)
        let lines = try TranscriptSegment.where { $0.lectureID.eq(reference) }.fetchCount(db)
        let (transcriptions, busy) = try JobRepository.transcriptions(lectureID: lectureID, in: db)
        let range = try LectureSlides.current(lectureID: lectureID, in: db)
        var pages = 0
        if let range {
            let deckID = range.deckID
            let first = range.firstPage
            let last = range.lastPage
            pages = try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.gte(first) && $0.pageNumber.lte(last) }.fetchCount(db)
        }
        let recording = RecordingNotesState(transcriptions: transcriptions, busy: busy, synthesis: synthesis?.0, synthesisError: synthesis?.1)
        // The pass will write a synthesis: a recording is being transcribed (or waits for its
        // first transcription), or its lines wait for the synthesis (not planned yet, or pending).
        let transcribing = transcriptions.contains { $0.lines == 0 && !$0.hasFailed && $0.latest != .succeeded }
        let synthesisComing = lines > 0 && (synthesis == nil || synthesis?.0 == .pending)
        return LectureNotesInputs(
            synthesized: syntheses.contains { $0.0 == .done }, topics: topics, transcriptLines: lines, recordings: transcriptions.count,
            range: range, rangePages: pages, synthesisSkipped: synthesis?.0 == .skipped, recording: recording,
            studyPassComing: recording == .coming && (transcribing || synthesisComing)
        )
    }

    /// Queues a version from `source` (decided by the caller: `available` for the student's act,
    /// `source` or the recording for the automatic ones) unless the lecture is gone or a version of
    /// it is open. Its instruction: the student's new one, or the standing one carried on.
    static func queue(
        lectureID: Lecture.ID, source: LectureNotesSource, instruction: NotesInstruction, createdBy: Author, inputs: LectureNotesInputs,
        in db: Database, now: Date
    ) throws -> LectureNotes? {
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
        let name = lecture.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = lecture.number.map { "Summary: Lecture \($0)" + (name.isEmpty ? "" : " · \(name)") } ?? "Summary: \(name.isEmpty ? "Lecture" : name)"
        let task = AgentTask(
            kind: .lectureNotes, title: String(title.prefix(80)), goal: "Write the lecture's summary.",
            model: LectureNotesCalls.writeModel, effort: LectureNotesCalls.writeEffort, tools: [],
            courseID: lecture.courseID, lectureID: lectureID, createdBy: createdBy, createdAt: now, updatedAt: now
        )
        try AgentTask.upsert { task }.execute(db)
        let notes = LectureNotes(
            courseID: lecture.courseID, lectureID: lectureID, version: (versions.map(\.version).max() ?? 0) + 1,
            state: .queued, source: source, request: instruction.request(after: versions),
            sections: try outline(lectureID: lectureID, in: db), taskID: task.id, createdBy: createdBy,
            createdAt: now, updatedAt: now
        )
        try LectureNotes.upsert { notes }.execute(db)
        Log.lectureNotes.notice(
            "Notes for lecture \(key, privacy: .public) queued: v\(notes.version, privacy: .public) \(ChatCitation.key(notes.id), privacy: .public) from the \(source.rawValue, privacy: .public) (\(inputs.summary, privacy: .public)), \(notes.request == nil ? "no instruction" : "with the instruction", privacy: .public), by \(createdBy.rawValue, privacy: .public)"
        )
        return notes
    }

    /// The outline from the lecture's topic rows (`annotation` ai · topic, not hidden) in lecture
    /// order (on the timeline of its recordings, `LectureTimeline`): key, title, slides, start on
    /// its recording (and the next topic's start as end when it is on the same recording), whether
    /// an exam hint lies in it. The writer refines it when the version is done.
    public static func outline(lectureID: Lecture.ID, in db: Database) throws -> [LectureNotesSection] {
        let reference = Lecture.ID?.some(lectureID)
        let rows = try Annotation
            .where { $0.lectureID.eq(reference) && $0.hiddenAt.is(nil) && $0.kind.in([AnnotationKind.topic, AnnotationKind.examHint]) }
            .fetchAll(db)
        let timeline = try LectureTimeline.load(lectureID: lectureID, in: db)
        let at: (Annotation) -> Double? = { row in row.startTime.map { timeline.seconds($0, on: row.recordingID) } }
        let topics = rows.filter { $0.kind == .topic }.sorted { lhs, rhs in
            let left = (at(lhs) ?? .greatestFiniteMagnitude, lhs.pageNumber ?? .max)
            let right = (at(rhs) ?? .greatestFiniteMagnitude, rhs.pageNumber ?? .max)
            return left.0 != right.0 ? left.0 < right.0 : left.1 < right.1
        }
        let hints = rows.filter { $0.kind == .examHint }
        var seen: Set<String> = []
        var sections: [LectureNotesSection] = []
        for (index, topic) in topics.enumerated() {
            let key = LectureNotesFormat.sectionKey(topicTitle: topic.body)
            guard !topic.body.isEmpty, seen.insert(key).inserted else { continue }
            let next = topics.dropFirst(index + 1).first { $0.startTime != nil }
            let end = next.flatMap { timeline.same($0.recordingID, topic.recordingID) ? $0.startTime : nil }
            var section = LectureNotesSection(
                key: key, title: topic.body, topicID: topic.id, firstPage: topic.pageNumber,
                lastPage: topic.lastPage ?? topic.pageNumber, startTime: topic.startTime, endTime: end,
                recordingID: topic.startTime == nil ? nil : topic.recordingID
            )
            let upper = next.flatMap(at) ?? .greatestFiniteMagnitude
            section.hasExamHint = hints.contains { hint in
                if let time = at(hint), let start = at(topic) { return time >= start && time < upper }
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

    /// `cancel(_:)` inside the caller's write transaction (a merge cancels the survivor's
    /// slides-only notes not written yet when a recording comes in).
    public static func cancel(_ id: LectureNotes.ID, in db: Database, now: Date) throws -> Bool {
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

    /// Undo of a Write Again that waits for its recording (`WriteAgainOutcome.waiting`): its row is
    /// discarded, so the instruction before it stands again (Redo: `restore`).
    public func discard(_ id: LectureNotes.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try LectureNotes.where { $0.id.eq(id) && $0.discardedAt.is(nil) }
                .update { $0.discardedAt = Date?.some(stamp); $0.updatedAt = stamp }
                .execute(db)
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
/// that decide `source` and `available`, how its recording is getting there, and their one-line
/// summary for the log (counts, pages and states only, never lecture content).
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
    /// The synthesis unit was skipped: the transcript is under its minimum.
    public var synthesisSkipped: Bool
    /// How the recording is getting into the Summary.
    public var recording: RecordingNotesState
    /// On its way (`recording` is `.coming`) and the study pass will write a synthesis: a
    /// recording is being transcribed, or its lines wait for the synthesis. Its landing writes the
    /// Summary (`queueAfterStudyPass`), so a Write Again on a finished Summary waits for it.
    /// False while only another job of the lecture runs.
    public var studyPassComing: Bool

    public init(
        synthesized: Bool, topics: Int, transcriptLines: Int, recordings: Int, range: LectureSlideRange?, rangePages: Int,
        synthesisSkipped: Bool = false, recording: RecordingNotesState = .none, studyPassComing: Bool = false
    ) {
        self.synthesized = synthesized
        self.topics = topics
        self.transcriptLines = transcriptLines
        self.recordings = recordings
        self.range = range
        self.rangePages = rangePages
        self.synthesisSkipped = synthesisSkipped
        self.recording = recording
        self.studyPassComing = studyPassComing
    }

    /// The study pass has written its synthesis (its unit done, or topic rows: a library whose
    /// topics came without units) over transcript lines (topic rows without a transcript, left by
    /// a recording moved to another lecture, do not count): the notes are written from it.
    public var recordingReady: Bool { transcriptLines > 0 && (synthesized || topics > 0) }

    /// What the student's Write Again (and the agent's write_lecture_notes) writes from: anything
    /// there is. The recording once its pass is written; else its transcript, while the synthesis
    /// is on its way or failed; else the slides; else a short transcript (under the synthesis's
    /// minimum) without slides; nil with nothing at all.
    public var available: LectureNotesSource? {
        if recordingReady { return .recording }
        if transcriptLines > 0, !synthesisSkipped { return .recording }
        if rangePages > 0 { return .slides }
        if transcriptLines > 0 { return .recording }
        return nil
    }

    /// What a version queued automatically (the first open, material that arrived) is written
    /// from: the recording once its pass is written; the slides of a lecture without a recording;
    /// while the recording's way is blocked (`RecordingNotesState.isBlocked`), the slides, else
    /// the transcript of a failed transcription or study pass (`available`), never a transcript
    /// under the synthesis's minimum (only the student's Write Again writes from that). nil while
    /// a recording is still on its way: its pass writes the notes.
    public var source: LectureNotesSource? {
        if recordingReady { return .recording }
        if recordings == 0, rangePages > 0 { return .slides }
        guard recording.isBlocked else { return nil }
        if rangePages > 0 { return .slides }
        return recording == .tooLittleSpeech ? nil : available
    }

    /// "transcript 0 lines, 0 recordings, synthesis no, 5 topics, slides 1–50: 0 pages, recording
    /// coming".
    public var summary: String {
        var text = "transcript \(transcriptLines) lines, \(recordings) recordings, synthesis \(synthesized ? "done" : synthesisSkipped ? "skipped" : "no"), \(topics) topics, "
        if let range {
            text += "slides \(range.firstPage)–\(range.lastPage) of deck \(ChatCitation.key(range.deckID)): \(rangePages) pages"
        } else {
            text += "no slides"
        }
        text += ", recording \(recording.logDescription)"
        return text
    }
}
