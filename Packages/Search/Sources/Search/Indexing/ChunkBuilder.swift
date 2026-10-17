import Foundation
import GRDB
import StudyCore

/// A `search_chunk` row to insert (the integer id is assigned by SQLite).
///
/// `SearchChunk.Draft` has no public initializer outside StudyCore, so the indexer writes these
/// with plain SQL: always delete + insert, never INSERT OR REPLACE.
struct ChunkRow: Sendable, Equatable {
    var kind: SearchChunkKind
    var sourceID: UUID
    var courseID: Course.ID?
    var lectureID: Lecture.ID?
    var deckID: Deck.ID?
    var pageNumber: Int?
    var recordingID: Recording.ID?
    var noteID: Note.ID?
    var startTime: Double?
    var endTime: Double?
    var lang: String
    var text: String
    var lemmaText: String
    var sourceUpdatedAt: Date?
    var updatedAt: Date

    init(
        kind: SearchChunkKind, sourceID: UUID, courseID: Course.ID? = nil, lectureID: Lecture.ID? = nil,
        deckID: Deck.ID? = nil, pageNumber: Int? = nil, recordingID: Recording.ID? = nil, noteID: Note.ID? = nil,
        startTime: Double? = nil, endTime: Double? = nil, lang: String, text: String, lemmaText: String,
        sourceUpdatedAt: Date?, updatedAt: Date
    ) {
        self.kind = kind
        self.sourceID = sourceID
        self.courseID = courseID
        self.lectureID = lectureID
        self.deckID = deckID
        self.pageNumber = pageNumber
        self.recordingID = recordingID
        self.noteID = noteID
        self.startTime = startTime
        self.endTime = endTime
        self.lang = lang
        self.text = text
        self.lemmaText = lemmaText
        self.sourceUpdatedAt = sourceUpdatedAt
        self.updatedAt = updatedAt
    }

    static let insertSQL = """
        INSERT INTO "search_chunk" ("kind", "source_id", "course_id", "lecture_id", "deck_id", "page_number",
          "recording_id", "note_id", "start_time", "end_time", "lang", "text", "lemma_text", "source_updated_at", "updated_at")
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    /// Inserts `rows` with one cached statement.
    static func insert(_ rows: [ChunkRow], into db: Database) throws {
        guard !rows.isEmpty else { return }
        let statement = try db.cachedStatement(sql: insertSQL)
        for row in rows {
            try statement.execute(arguments: [
                row.kind.rawValue, row.sourceID.storageText, row.courseID?.storageText, row.lectureID?.storageText,
                row.deckID?.storageText, row.pageNumber, row.recordingID?.storageText, row.noteID?.storageText,
                row.startTime, row.endTime, row.lang, row.text, row.lemmaText, row.sourceUpdatedAt, row.updatedAt,
            ])
        }
    }
}

extension UUID {
    /// How the library stores UUIDs: lower-case text (GRDB alone would write a 16-byte blob).
    var storageText: String { uuidString.lowercased() }
}

/// Cuts library rows into `search_chunk` drafts: one per transcript segment, one per deck page,
/// one per note. Pure apart from the lemmatizer; not thread-safe (owns an NLTagger).
final class ChunkBuilder {
    private let lemmatizer = Lemmatizer()

    /// One chunk per non-blank segment of a recording, with the slide on screen at its midpoint
    /// (the timed span containing it; none in an off-slide stretch).
    func transcriptChunks(
        segments: [TranscriptSegment],
        spans: [LectureDeckSpan],
        lectureID: Lecture.ID,
        courseID: Course.ID,
        recordingID: Recording.ID,
        fallbackLanguage: String,
        version: Date,
        now: Date
    ) -> [ChunkRow] {
        let timed = spans
            .filter { $0.startTime != nil }
            .sorted { ($0.startTime ?? 0) < ($1.startTime ?? 0) }
        var spanIndex = 0
        var drafts: [ChunkRow] = []
        drafts.reserveCapacity(segments.count)
        for segment in segments.sorted(by: { $0.startTime < $1.startTime }) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let middle = (segment.startTime + segment.endTime) / 2
            while spanIndex < timed.count, (timed[spanIndex].endTime ?? .infinity) <= middle { spanIndex += 1 }
            var span: LectureDeckSpan?
            if spanIndex < timed.count, let start = timed[spanIndex].startTime, start <= middle {
                span = timed[spanIndex]
            }
            let language = segment.lang.isEmpty
                ? lemmatizer.language(of: text, fallback: fallbackLanguage)
                : String(segment.lang.prefix(2)).lowercased()
            drafts.append(ChunkRow(
                kind: .transcript,
                sourceID: segment.id,
                courseID: courseID,
                lectureID: lectureID,
                deckID: span?.firstPage == nil ? nil : span?.deckID,
                pageNumber: span?.firstPage,
                recordingID: recordingID,
                startTime: segment.startTime,
                endTime: segment.endTime,
                lang: language,
                text: text,
                lemmaText: lemmatizer.lemmaText(of: text, language: language),
                sourceUpdatedAt: version,
                updatedAt: now
            ))
        }
        return drafts
    }

    /// One chunk per page with text, footers and page numbers removed (`SlideText`).
    func slideChunks(deck: Deck, pages: [DeckPage], fallbackLanguage: String, version: Date, now: Date) -> [ChunkRow] {
        let ordered = pages.sorted { $0.pageNumber < $1.pageNumber }
        let cleaned = SlideText.clean(ordered.map(\.text))
        let deckLanguage = lemmatizer.language(
            of: cleaned.prefix(30).joined(separator: " "), fallback: fallbackLanguage
        )
        var drafts: [ChunkRow] = []
        for (page, text) in zip(ordered, cleaned) where !text.isEmpty {
            let language = lemmatizer.language(of: text, fallback: deckLanguage)
            drafts.append(ChunkRow(
                kind: .slide,
                sourceID: page.id,
                courseID: deck.courseID,
                deckID: deck.id,
                pageNumber: page.pageNumber,
                lang: language,
                text: text,
                lemmaText: lemmatizer.lemmaText(of: text, language: language),
                sourceUpdatedAt: version,
                updatedAt: now
            ))
        }
        return drafts
    }

    /// The note's plain text as one chunk, anchored like the note; nil for a blank note.
    func noteChunk(note: Note, courseID: Course.ID?, fallbackLanguage: String, now: Date) -> ChunkRow? {
        let text = Self.noteText(note)
        guard !text.isEmpty else { return nil }
        let language = lemmatizer.language(of: text, fallback: fallbackLanguage)
        return ChunkRow(
            kind: .note,
            sourceID: note.id,
            courseID: courseID,
            lectureID: note.lectureID,
            deckID: note.deckID,
            pageNumber: note.pageNumber,
            recordingID: note.recordingID,
            noteID: note.id,
            startTime: note.audioTime,
            lang: language,
            text: text,
            lemmaText: lemmatizer.lemmaText(of: text, language: language),
            sourceUpdatedAt: note.updatedAt,
            updatedAt: now
        )
    }

    /// A note's chunk text: its blocks on one line, " · " between them (a snippet reads as one
    /// paragraph, not a ragged first line).
    static func noteText(_ note: Note) -> String {
        SlideText.joinLines(note.plainText)
    }
}
