import Foundation
import GRDB
import StudyCore
import Synchronization

/// Keeps `search_chunk` (and through its triggers the FTS5 tables) in step with the library.
///
/// `start()` catches up (sources without chunks, or newer than their chunks), then watches
/// `transcript_segment`, `deck_page`, `note`, `lecture_deck_span`, `lecture` and `deck` and catches
/// up again about a second after they change. Deleted lectures, recordings, decks and notes take
/// their chunks with them through foreign-key cascades.
public actor SearchIndexer {
    /// What one catch-up did.
    public struct Report: Sendable, Equatable {
        public var recordings = 0
        public var decks = 0
        public var notes = 0
        /// Chunks written.
        public var chunks = 0
        /// Chunks deleted without being rewritten (orphans, blanked sources).
        public var removed = 0

        public var isEmpty: Bool { recordings == 0 && decks == 0 && notes == 0 && removed == 0 }
    }

    private let database: any DatabaseWriter
    private let debounce: Duration
    private let now: @Sendable () -> Date
    private let builder = ChunkBuilder()
    private let changes = ChangeCounter()
    private var observation: AnyDatabaseCancellable?
    private var loop: Task<Void, Never>?
    private var isCatchingUp = false
    private var catchUpAgain = false

    /// Tables whose changes can make chunks stale.
    static let observedTables = ["transcript_segment", "deck_page", "note", "lecture_deck_span", "lecture", "deck", "recording"]

    /// What the indexer watches: every column of the tables above, except that of `lecture` only
    /// the columns chunks are built from (rows added or deleted always count). The review screen
    /// writes `lecture.review_position` every few seconds while playing; that must not start a
    /// staleness scan.
    static var observedRegions: [any DatabaseRegionConvertible] {
        observedTables.map { table in
            table == "lecture"
                ? SQLRequest<Row>(sql: "SELECT id, course_id, language FROM lecture")
                : SQLRequest<Row>(sql: "SELECT * FROM \"\(table)\"")
        }
    }

    public init(services: StudyServices, debounce: Duration = .seconds(1)) {
        self.init(database: services.database, debounce: debounce)
    }

    public init(database: any DatabaseWriter, debounce: Duration = .seconds(1), now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.debounce = debounce
        self.now = now
    }

    /// Starts watching the library, then catches up once. Returns after the catch-up; changes
    /// keep being indexed until `stop()`.
    public func start() async {
        guard loop == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let changes = changes
        observation = DatabaseRegionObservation(tracking: Self.observedRegions).start(
            in: database,
            onError: { error in
                Log.search.error("Search index observation failed: \(String(describing: error), privacy: .public)")
            },
            onChange: { _ in
                changes.bump()
                continuation.yield()
            }
        )
        let debounce = debounce
        loop = Task { [weak self] in
            for await _ in stream {
                // Wait for a quiet second (at most three) so a burst of saves is indexed once.
                var seen = changes.value
                for _ in 0..<3 {
                    do { try await Task.sleep(for: debounce) } catch { return }
                    let current = changes.value
                    if current == seen { break }
                    seen = current
                }
                await self?.catchUpLogged()
            }
        }
        await catchUpLogged(verifyingText: true)
    }

    /// Stops watching the library.
    public func stop() {
        observation?.cancel()
        observation = nil
        loop?.cancel()
        loop = nil
    }

    /// Drops every chunk and indexes the whole library again.
    public func reindexAll() async throws {
        try await database.write { db in
            try SearchChunk.delete().execute(db)
        }
        try await catchUp()
    }

    /// Re-chunks every stale source and removes orphaned chunks.
    @discardableResult
    public func catchUp() async throws -> Report {
        try await catchUp(verifyingText: false)
    }

    /// `verifyingText` also re-chunks sources an earlier build cut differently (`IndexState.outdatedText`).
    @discardableResult
    func catchUp(verifyingText: Bool) async throws -> Report {
        var report = Report()
        var work = try await database.read { db in try IndexState.staleUnits(db) }
        if verifyingText {
            let outdated = try await database.read { db in try IndexState.outdatedText(db) }
            work.formUnion(outdated)
        }
        for recordingID in work.recordings {
            report.chunks += try await indexRecording(recordingID)
            report.recordings += 1
        }
        for deckID in work.decks {
            report.chunks += try await indexDeck(deckID)
            report.decks += 1
        }
        for noteID in work.notes {
            let written = try await indexNote(noteID)
            report.chunks += written.written
            if written.changed { report.notes += 1 }
        }
        report.removed = try await database.write { db in try IndexState.removeOrphans(db) }
        return report
    }

    /// Catches up, logging what it did. A change that arrives while a catch-up is suspended on
    /// the database (the actor is reentrant) runs one more pass afterwards instead of a second
    /// catch-up alongside.
    private func catchUpLogged(verifyingText: Bool = false) async {
        guard !isCatchingUp else {
            catchUpAgain = true
            return
        }
        isCatchingUp = true
        defer { isCatchingUp = false }
        var verifies = verifyingText
        repeat {
            catchUpAgain = false
            do {
                let started = ContinuousClock.now
                let report = try await catchUp(verifyingText: verifies)
                verifies = false
                if !report.isEmpty {
                    let elapsed = ContinuousClock.now - started
                    Log.search.info("""
                        Indexed \(report.recordings) transcripts, \(report.decks) decks, \(report.notes) notes \
                        (\(report.chunks) chunks, \(report.removed) removed) in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)
                        """)
                }
            } catch {
                Log.search.error("Search indexing failed: \(String(describing: error), privacy: .public)")
            }
        } while catchUpAgain
    }

    // MARK: - Units

    private struct RecordingSource: Sendable {
        var recording: Recording
        var lecture: Lecture
        var course: Course?
        var segments: [TranscriptSegment]
        var spans: [LectureDeckSpan]
    }

    private func indexRecording(_ recordingID: Recording.ID) async throws -> Int {
        let source = try await database.read { db -> RecordingSource? in
            guard let recording = try StudyCore.Recording.find(recordingID).fetchOne(db),
                  let lectureID = recording.lectureID,
                  let lecture = try StudyCore.Lecture.find(lectureID).fetchOne(db)
            else { return nil }
            return RecordingSource(
                recording: recording,
                lecture: lecture,
                course: try StudyCore.Course.find(lecture.courseID).fetchOne(db),
                segments: try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.fetchAll(db),
                spans: try LectureDeckSpan.where { $0.recordingID.eq(recordingID) }.fetchAll(db)
            )
        }
        guard let source else {
            try await deleteChunks(kind: .transcript) { $0.recordingID.eq(recordingID) }
            return 0
        }
        let version = [source.segments.map(\.updatedAt).max(), source.spans.map(\.updatedAt).max()].compactMap { $0 }.max()
        let drafts = builder.transcriptChunks(
            segments: source.segments,
            spans: source.spans,
            lectureID: source.lecture.id,
            courseID: source.lecture.courseID,
            recordingID: recordingID,
            fallbackLanguage: Self.language(source.lecture.language, source.course?.language),
            version: version ?? now(),
            now: now()
        )
        try await replace(drafts, kind: .transcript) { $0.recordingID.eq(recordingID) }
        return drafts.count
    }

    private func indexDeck(_ deckID: Deck.ID) async throws -> Int {
        let source = try await database.read { db -> (Deck, [DeckPage], Course?)? in
            guard let deck = try Deck.find(deckID).fetchOne(db) else { return nil }
            let pages = try DeckPage.where { $0.deckID.eq(deckID) }.fetchAll(db)
            let course = try deck.courseID.flatMap { try StudyCore.Course.find($0).fetchOne(db) }
            return (deck, pages, course)
        }
        guard let (deck, pages, course) = source else { return 0 }
        let version = ([deck.updatedAt] + pages.map(\.updatedAt)).max() ?? deck.updatedAt
        let drafts = builder.slideChunks(
            deck: deck, pages: pages, fallbackLanguage: Self.language(course?.language), version: version, now: now()
        )
        try await replace(drafts, kind: .slide) { $0.deckID.eq(deckID) }
        return drafts.count
    }

    private func indexNote(_ noteID: Note.ID) async throws -> (written: Int, changed: Bool) {
        let source = try await database.read { db -> (Note, Course.ID?, String?)? in
            guard let note = try Note.find(noteID).fetchOne(db) else { return nil }
            let lecture = try note.lectureID.flatMap { try StudyCore.Lecture.find($0).fetchOne(db) }
            let courseID = note.courseID ?? lecture?.courseID
            let course = try courseID.flatMap { try StudyCore.Course.find($0).fetchOne(db) }
            return (note, courseID, lecture?.language ?? course?.language)
        }
        guard let (note, courseID, language) = source else { return (0, false) }
        // A note opens its lecture or course; one with neither has nowhere to go.
        let draft = (note.lectureID != nil || courseID != nil)
            ? builder.noteChunk(note: note, courseID: courseID, fallbackLanguage: Self.language(language), now: now())
            : nil
        let removed = try await replace(draft.map { [$0] } ?? [], kind: .note) { $0.noteID.eq(noteID) }
        return (draft == nil ? 0 : 1, draft != nil || removed > 0)
    }

    /// Deletes the unit's chunks and inserts `drafts` in one transaction (never INSERT OR REPLACE).
    /// Returns how many chunks were deleted.
    @discardableResult
    private func replace<Unit: QueryExpression<Bool>>(
        _ drafts: [ChunkRow],
        kind: SearchChunkKind,
        where unit: @escaping @Sendable (SearchChunk.TableColumns) -> Unit
    ) async throws -> Int {
        try await database.write { db in
            try SearchChunk.where { $0.kind.eq(kind) && unit($0) }.delete().execute(db)
            let removed = db.changesCount
            try ChunkRow.insert(drafts, into: db)
            return removed
        }
    }

    private func deleteChunks<Unit: QueryExpression<Bool>>(
        kind: SearchChunkKind,
        where unit: @escaping @Sendable (SearchChunk.TableColumns) -> Unit
    ) async throws {
        try await replace([], kind: kind, where: unit)
    }

    private static func language(_ candidates: String?...) -> String {
        for candidate in candidates {
            if let code = candidate?.prefix(2).lowercased(), code == "de" || code == "en" { return code }
        }
        return "en"
    }
}

/// Counts database changes; read and bumped from GRDB's writer queue and the indexer.
private final class ChangeCounter: Sendable {
    private let count = Mutex<UInt64>(0)

    func bump() { count.withLock { $0 &+= 1 } }
    var value: UInt64 { count.withLock { $0 } }
}
