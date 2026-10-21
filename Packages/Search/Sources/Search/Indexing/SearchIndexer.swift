import Foundation
import GRDB
import StudyCore
import Synchronization

/// Keeps `search_chunk` (and through its triggers the FTS5 tables) in step with the library.
///
/// `start()` catches up (sources without chunks, or newer than their chunks), then watches
/// `transcript_segment`, `deck_page`, `note`, `lecture_deck_span`, `lecture` and `deck` (md: and
/// `document`, `document_page`) and catches up again about a second after they change. Deleted lectures, recordings, decks and notes take
/// their chunks with them through foreign-key cascades.
public actor SearchIndexer {
    /// What one catch-up did.
    public struct Report: Sendable, Equatable {
        public var recordings = 0
        public var decks = 0
        public var notes = 0
        /// M5: further-reading rows.
        public var readings = 0
        /// md: kept documents.
        public var documents = 0
        /// Chunks written.
        public var chunks = 0
        /// Chunks deleted without being rewritten (orphans, blanked sources).
        public var removed = 0

        public var isEmpty: Bool { recordings == 0 && decks == 0 && notes == 0 && readings == 0 && documents == 0 && removed == 0 }
    }

    private let database: any DatabaseWriter
    private let debounce: Duration
    private let now: @Sendable () -> Date
    /// Where the `IndexState.textVersion` the library was last checked against is kept (nil: the
    /// check runs at every start).
    private let textStamp: URL?
    private let builder = ChunkBuilder()
    private let changes = ChangeCounter()
    /// What changed since the last pass: notes only, or anything else too.
    private let scope = PendingScope()
    private var observation: AnyDatabaseCancellable?
    private var noteObservation: AnyDatabaseCancellable?
    private var loop: Task<Void, Never>?
    private var isCatchingUp = false
    private var catchUpAgain = false
    private var catchUpAgainScope = Scope.notes

    /// What a pass looks at: every source (launch, a lecture, deck or recording changed), or the
    /// notes alone (the student typing: a save every half second).
    enum Scope: Sendable {
        case notes
        case all

        func union(_ other: Scope) -> Scope { self == .all || other == .all ? .all : .notes }
    }

    /// Tables whose changes can make chunks stale (M5: `annotation`, for further reading).
    /// `note` is watched on its own (`noteRegion`): its changes start a notes-only pass.
    static let observedTables = [
        "transcript_segment", "deck_page", "lecture_deck_span", "lecture", "deck", "recording", "annotation",
        // md: the document bank (its pages; of `document` only what chunks are cut from).
        "document", "document_page",
    ]

    static var noteRegion: any DatabaseRegionConvertible { SQLRequest<Row>(sql: "SELECT * FROM \"note\"") }

    /// What the indexer watches: every column of the tables above, except that of `lecture` and
    /// `annotation` only the columns chunks are built from (rows added or deleted always count).
    /// The review screen writes `lecture.review_position` every few seconds while playing, and
    /// the student moves pins (`annotation.anchor_*`); neither must start a staleness scan.
    static var observedRegions: [any DatabaseRegionConvertible] {
        observedTables.map { table in
            switch table {
            case "lecture":
                SQLRequest<Row>(sql: "SELECT id, course_id, language FROM lecture")
            case "annotation":
                SQLRequest<Row>(sql: """
                    SELECT id, lecture_id, layer, kind, deck_id, page_number, body, detail, hidden_at FROM annotation
                    """)
            case "document":
                // The summary task writes title, summary, facts…: none of it is in a chunk (mt:
                // the role decides the chunks' kind).
                SQLRequest<Row>(sql: "SELECT id, text_state, language, role FROM document")
            default:
                SQLRequest<Row>(sql: "SELECT * FROM \"\(table)\"")
            }
        }
    }

    public init(services: StudyServices, debounce: Duration = .seconds(1)) {
        self.init(
            database: services.database, debounce: debounce,
            textStamp: services.paths.caches.appending(path: "SearchTextVersion")
        )
    }

    public init(
        database: any DatabaseWriter, debounce: Duration = .seconds(1), textStamp: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.database = database
        self.debounce = debounce
        self.textStamp = textStamp
        self.now = now
    }

    /// Starts watching the library, then catches up once. Returns after the catch-up; changes
    /// keep being indexed until `stop()`.
    public func start() async {
        guard loop == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let changes = changes
        let scope = scope
        let onError: @Sendable (any Error) -> Void = { error in
            Log.search.error("Search index observation failed: \(String(describing: error), privacy: .public)")
        }
        observation = DatabaseRegionObservation(tracking: Self.observedRegions).start(
            in: database, onError: onError,
            onChange: { _ in
                scope.add(.all)
                changes.bump()
                continuation.yield()
            }
        )
        noteObservation = DatabaseRegionObservation(tracking: Self.noteRegion).start(
            in: database, onError: onError,
            onChange: { _ in
                scope.add(.notes)
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
                guard let pending = scope.take() else { continue }
                await self?.catchUpLogged(pending)
            }
        }
        await catchUpLogged(.all, verifyingText: textVersionChanged())
    }

    /// Stops watching the library.
    public func stop() {
        observation?.cancel()
        observation = nil
        noteObservation?.cancel()
        noteObservation = nil
        loop?.cancel()
        loop = nil
    }

    // MARK: - Text version

    /// Whether the chunker's text changed since the library was last checked against it.
    private func textVersionChanged() -> Bool {
        guard let textStamp, let data = try? Data(contentsOf: textStamp),
              let stored = Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        else { return true }
        return stored != IndexState.textVersion
    }

    private func saveTextVersion() {
        guard let textStamp else { return }
        do {
            try FileManager.default.createDirectory(at: textStamp.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("\(IndexState.textVersion)".utf8).write(to: textStamp, options: .atomic)
        } catch {
            Log.search.error("Saving the search text version failed: \(String(describing: type(of: error)), privacy: .public)")
        }
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

    /// `verifyingText` also re-chunks sources an earlier build cut differently
    /// (`IndexState.outdatedText`), as `start()` does when `IndexState.textVersion` changed.
    @discardableResult
    public func catchUp(verifyingText: Bool) async throws -> Report {
        try await catchUp(.all, verifyingText: verifyingText)
    }

    func catchUp(_ scope: Scope, verifyingText: Bool) async throws -> Report {
        var report = Report()
        var work = try await database.read { db in
            try scope == .all ? IndexState.staleUnits(db) : IndexState.staleNotes(db)
        }
        if verifyingText {
            let rows = try await database.read { db in try IndexState.indexedText(db) }
            work.formUnion(IndexState.outdatedText(rows))
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
        for annotationID in work.readings {
            report.chunks += try await indexReading(annotationID)
            report.readings += 1
        }
        for documentID in work.documents {
            report.chunks += try await indexDocument(documentID)
            report.documents += 1
        }
        report.removed = try await database.write { db in try IndexState.removeOrphans(db, notesOnly: scope == .notes) }
        if verifyingText { saveTextVersion() }
        return report
    }

    /// Catches up, logging what it did. A change that arrives while a catch-up is suspended on
    /// the database (the actor is reentrant) runs one more pass afterwards (of everything that
    /// changed meanwhile) instead of a second catch-up alongside.
    private func catchUpLogged(_ scope: Scope, verifyingText: Bool = false) async {
        guard !isCatchingUp else {
            catchUpAgainScope = catchUpAgain ? catchUpAgainScope.union(scope) : scope
            catchUpAgain = true
            return
        }
        isCatchingUp = true
        defer { isCatchingUp = false }
        var verifies = verifyingText
        var current = scope
        repeat {
            if catchUpAgain {
                current = catchUpAgainScope
                catchUpAgain = false
            }
            do {
                let started = ContinuousClock.now
                let report = try await catchUp(current, verifyingText: verifies)
                verifies = false
                if !report.isEmpty {
                    let elapsed = ContinuousClock.now - started
                    Log.search.info("""
                        Indexed \(report.recordings) transcripts, \(report.decks) decks, \(report.notes) notes, \
                        \(report.readings) further reading, \(report.documents) documents \
                        (\(report.chunks) chunks, \(report.removed) removed) \
                        in \(elapsed.formatted(.units(allowed: [.milliseconds])), privacy: .public)
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
        // A slide's note opens its lecture; any other note the Notes screen (M6: All Notes for a
        // note without a course).
        let draft = builder.noteChunk(note: note, courseID: courseID, fallbackLanguage: Self.language(language), now: now())
        let removed = try await replace(draft.map { [$0] } ?? [], kind: .note) { $0.noteID.eq(noteID) }
        return (draft == nil ? 0 : 1, draft != nil || removed > 0)
    }

    /// M5: one further-reading row as a chunk ("title · byline", its lecture, deck and page); a
    /// row no longer visible (hidden, gone, not the study pass's) loses its chunk.
    private func indexReading(_ annotationID: Annotation.ID) async throws -> Int {
        let source = try await database.read { db -> (Annotation, Lecture, Course?)? in
            guard let annotation = try Annotation.find(annotationID).fetchOne(db),
                  annotation.kind == .furtherReading, annotation.layer == .ai, annotation.hiddenAt == nil,
                  let lectureID = annotation.lectureID, let lecture = try StudyCore.Lecture.find(lectureID).fetchOne(db)
            else { return nil }
            return (annotation, lecture, try StudyCore.Course.find(lecture.courseID).fetchOne(db))
        }
        let draft = source.flatMap { annotation, lecture, course in
            builder.readingChunk(
                annotation: annotation, courseID: lecture.courseID,
                fallbackLanguage: Self.language(lecture.language, course?.language), now: now())
        }
        try await replace(draft.map { [$0] } ?? [], kind: .furtherReading) { $0.sourceID.eq(annotationID) }
        return draft == nil ? 0 : 1
    }

    /// md: a kept document's pages as windows (`ChunkBuilder.documentChunks`); a document gone, or
    /// whose text is not read (pending, failed), has none.
    private func indexDocument(_ documentID: StudyDocument.ID) async throws -> Int {
        let source = try await database.read { db -> (StudyDocument, [StudyDocumentPage])? in
            guard let document = try StudyDocument.find(documentID).fetchOne(db), document.textState == .done else { return nil }
            return (document, try StudyDocumentPage.where { $0.documentID.eq(documentID) }.order(by: \.pageNumber).fetchAll(db))
        }
        let reference = StudyDocument.ID?.some(documentID)
        guard let (document, pages) = source else {
            try await deleteChunks(kind: .document) { $0.documentID.eq(reference) }
            try await deleteChunks(kind: .material) { $0.documentID.eq(reference) }
            return 0
        }
        let version = pages.map(\.updatedAt).max() ?? document.updatedAt
        let drafts = builder.documentChunks(document: document, pages: pages, version: version, now: now())
        // mt: a document's chunks are of one kind (its role's); the other kind's go.
        let kind = ChunkBuilder.chunkKind(of: document)
        try await deleteChunks(kind: kind == .material ? .document : .material) { $0.documentID.eq(reference) }
        try await replace(drafts, kind: kind) { $0.documentID.eq(reference) }
        return drafts.count
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

/// The scope of the changes since the last pass (written by the observations' callbacks).
private final class PendingScope: Sendable {
    private let pending = Mutex<SearchIndexer.Scope?>(nil)

    func add(_ scope: SearchIndexer.Scope) {
        pending.withLock { $0 = $0.map { $0.union(scope) } ?? scope }
    }

    /// What changed, and nothing pending from now on.
    func take() -> SearchIndexer.Scope? {
        pending.withLock { value in
            defer { value = nil }
            return value
        }
    }
}
