import Foundation
import GRDB
import StudyCore

/// Which sources need (re-)chunking: compares each source unit (a recording's transcript, a
/// deck, a note) with the chunks it has in `search_chunk`.
///
/// A unit's chunks all carry the unit's version in `source_updated_at` (the newest `updated_at`
/// among its rows). A unit is stale when the versions differ, its chunk count is off, or its
/// chunks name another lecture or course than the source now does (a re-filed lecture or deck).
enum IndexState {
    struct Work: Sendable {
        var recordings: [Recording.ID] = []
        var decks: [Deck.ID] = []
        var notes: [Note.ID] = []
        /// M5: further-reading annotations.
        var readings: [Annotation.ID] = []

        var isEmpty: Bool { recordings.isEmpty && decks.isEmpty && notes.isEmpty && readings.isEmpty }

        /// Adds `other`'s units that are not here yet.
        mutating func formUnion(_ other: Work) {
            recordings += other.recordings.filter { !recordings.contains($0) }
            decks += other.decks.filter { !decks.contains($0) }
            notes += other.notes.filter { !notes.contains($0) }
            readings += other.readings.filter { !readings.contains($0) }
        }
    }

    /// The version of the text the chunker writes (`SlideText.clean`, `ChunkBuilder.noteText`).
    /// Bump it with any change to either: the next launch then checks every deck's and note's
    /// chunks once (`outdatedText`); otherwise launches skip that check.
    static let textVersion = 2

    /// What `outdatedText` compares, read in one go (the cleaning runs after the read, so the
    /// first frame's reads never wait behind it).
    struct IndexedText: Sendable {
        struct DeckText: Sendable {
            var deckID: Deck.ID
            /// (page number, slide text), in page order.
            var pages: [(number: Int, text: String)]
            /// The slide chunks' text by page.
            var indexed: [Int: String]
        }

        var decks: [DeckText] = []
        var notes: [Note] = []
        var noteTexts: [Note.ID: String] = [:]
    }

    static func indexedText(_ db: Database) throws -> IndexedText {
        var rows = IndexedText()
        let decks = try Deck.ID.fetchAll(db, sql: """
            SELECT DISTINCT deck_id FROM search_chunk WHERE kind = 'slide' AND deck_id IS NOT NULL
            """)
        for deckID in decks {
            let pages = try Row.fetchAll(db, sql: """
                SELECT page_number, text FROM deck_page WHERE deck_id = ? ORDER BY page_number
                """, arguments: [deckID.storageText]).map { (number: $0["page_number"] as Int, text: $0["text"] as String) }
            var indexed: [Int: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT page_number, text FROM search_chunk WHERE kind = 'slide' AND deck_id = ? AND page_number IS NOT NULL
                """, arguments: [deckID.storageText]) {
                indexed[row["page_number"]] = row["text"]
            }
            rows.decks.append(IndexedText.DeckText(deckID: deckID, pages: pages, indexed: indexed))
        }
        for row in try Row.fetchAll(db, sql: "SELECT note_id, text FROM search_chunk WHERE kind = 'note' AND note_id IS NOT NULL") {
            rows.noteTexts[row["note_id"]] = row["text"]
        }
        if !rows.noteTexts.isEmpty {
            rows.notes = try Note.where({ $0.id.in(Array(rows.noteTexts.keys)) }).fetchAll(db)
        }
        return rows
    }

    /// Decks and notes whose chunks an earlier build cut differently: the text the chunker gives
    /// them now is not the text they have (slides and notes became one line with " · " between
    /// items). Checked once per `textVersion`, so a library indexed by an older build is
    /// re-chunked without a schema change. Transcript chunks are a segment's own text and are not
    /// checked. Runs off the database (on rows `indexedText` read).
    static func outdatedText(_ rows: IndexedText) -> Work {
        var work = Work()
        for deck in rows.decks {
            let cleaned = SlideText.clean(deck.pages.map { $0.text })
            var expected: [Int: String] = [:]
            for (page, text) in zip(deck.pages, cleaned) where !text.isEmpty { expected[page.number] = text }
            if deck.indexed != expected { work.decks.append(deck.deckID) }
        }
        for note in rows.notes where rows.noteTexts[note.id] != ChunkBuilder.noteText(note) {
            work.notes.append(note.id)
        }
        return work
    }

    /// Dates are compared to the millisecond the database stores.
    static func same(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 0.0005
        default: false
        }
    }

    static func staleUnits(_ db: Database) throws -> Work {
        var work = Work()
        let blank = "trim(%@, ' ' || char(9) || char(10) || char(13)) <> ''"

        // Transcripts: only recordings filed to a lecture (an orphaned recording is not reviewable).
        for row in try Row.fetchAll(db, sql: """
            SELECT r.id AS id,
              (SELECT count(*) FROM transcript_segment s WHERE s.recording_id = r.id AND \(String(format: blank, "s.text"))) AS expected,
              (SELECT max(s.updated_at) FROM transcript_segment s WHERE s.recording_id = r.id) AS segments,
              (SELECT max(p.updated_at) FROM lecture_deck_span p WHERE p.recording_id = r.id) AS spans,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'transcript' AND c.recording_id = r.id) AS have,
              (SELECT max(c.source_updated_at) FROM search_chunk c WHERE c.kind = 'transcript' AND c.recording_id = r.id) AS indexed,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'transcript' AND c.recording_id = r.id
                 AND (c.lecture_id IS NOT r.lecture_id OR c.course_id IS NOT l.course_id)) AS moved
            FROM recording r JOIN lecture l ON l.id = r.lecture_id
            """) {
            let expected: Int = row["expected"]
            let have: Int = row["have"]
            let moved: Int = row["moved"]
            let version = newest(row["segments"], row["spans"])
            if expected != have || moved > 0 || (expected > 0 && !same(version, row["indexed"])) {
                work.recordings.append(row["id"])
            }
        }

        for row in try Row.fetchAll(db, sql: """
            SELECT d.id AS id, d.updated_at AS deck,
              (SELECT count(*) FROM deck_page p WHERE p.deck_id = d.id AND \(String(format: blank, "p.text"))) AS expected,
              (SELECT max(p.updated_at) FROM deck_page p WHERE p.deck_id = d.id) AS pages,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'slide' AND c.deck_id = d.id) AS have,
              (SELECT max(c.source_updated_at) FROM search_chunk c WHERE c.kind = 'slide' AND c.deck_id = d.id) AS indexed,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'slide' AND c.deck_id = d.id
                 AND c.course_id IS NOT d.course_id) AS moved
            FROM deck d
            """) {
            let expected: Int = row["expected"]
            let have: Int = row["have"]
            let moved: Int = row["moved"]
            let version = newest(row["deck"], row["pages"])
            // A page left empty by footer removal has no chunk, so only "none at all" counts as missing.
            if (expected > 0 && have == 0) || (expected == 0 && have > 0) || moved > 0
                || (have > 0 && !same(version, row["indexed"])) {
                work.decks.append(row["id"])
            }
        }

        work.notes = try staleNotes(db).notes

        // M5: visible further reading (ai, not hidden), one chunk each, on its lecture's course.
        for row in try Row.fetchAll(db, sql: """
            SELECT a.id AS id, a.updated_at AS version,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'further_reading' AND c.source_id = a.id) AS have,
              (SELECT max(c.source_updated_at) FROM search_chunk c WHERE c.kind = 'further_reading' AND c.source_id = a.id) AS indexed,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'further_reading' AND c.source_id = a.id
                 AND (c.lecture_id IS NOT a.lecture_id OR c.course_id IS NOT l.course_id
                      OR c.deck_id IS NOT a.deck_id OR c.page_number IS NOT a.page_number)) AS moved
            FROM annotation a JOIN lecture l ON l.id = a.lecture_id
            WHERE a.kind = 'further_reading' AND a.layer = 'ai' AND a.hidden_at IS NULL AND \(String(format: blank, "a.body"))
            """) {
            let have: Int = row["have"]
            let moved: Int = row["moved"]
            if have != 1 || moved > 0 || !same(row["version"], row["indexed"]) {
                work.readings.append(row["id"])
            }
        }
        return work
    }

    /// Only the notes whose chunks are stale (a pass started by a note save: the student types, a
    /// save every half second must not scan every recording, deck and reading).
    static func staleNotes(_ db: Database) throws -> Work {
        var work = Work()
        for row in try Row.fetchAll(db, sql: """
            SELECT n.id AS id, n.updated_at AS version,
              (SELECT max(c.source_updated_at) FROM search_chunk c WHERE c.kind = 'note' AND c.note_id = n.id) AS indexed,
              (SELECT count(*) FROM search_chunk c WHERE c.kind = 'note' AND c.note_id = n.id
                 AND (c.lecture_id IS NOT n.lecture_id
                      OR c.course_id IS NOT coalesce(n.course_id, (SELECT l.course_id FROM lecture l WHERE l.id = n.lecture_id)))) AS moved
            FROM note n
            """) {
            let moved: Int = row["moved"]
            if moved > 0 || !same(row["version"], row["indexed"]) {
                work.notes.append(row["id"])
            }
        }
        return work
    }

    /// Removes chunks whose source is gone without a cascade: transcripts of recordings no longer
    /// filed to a lecture. Returns how many. `notesOnly`: only note chunks without a note.
    static func removeOrphans(_ db: Database, notesOnly: Bool = false) throws -> Int {
        if notesOnly {
            try db.execute(sql: "DELETE FROM search_chunk WHERE kind = 'note' AND note_id IS NULL")
            return db.changesCount
        }
        try db.execute(sql: """
            DELETE FROM search_chunk WHERE kind = 'transcript' AND (recording_id IS NULL
              OR recording_id IN (SELECT id FROM recording WHERE lecture_id IS NULL))
            """)
        var removed = db.changesCount
        try db.execute(sql: "DELETE FROM search_chunk WHERE kind = 'slide' AND deck_id IS NULL")
        removed += db.changesCount
        try db.execute(sql: "DELETE FROM search_chunk WHERE kind = 'note' AND note_id IS NULL")
        removed += db.changesCount
        // M5: further reading hidden, deleted, or no longer the study pass's (no cascade).
        try db.execute(sql: """
            DELETE FROM search_chunk WHERE kind = 'further_reading' AND source_id NOT IN (
              SELECT a.id FROM annotation a JOIN lecture l ON l.id = a.lecture_id
              WHERE a.kind = 'further_reading' AND a.layer = 'ai' AND a.hidden_at IS NULL)
            """)
        removed += db.changesCount
        return removed
    }

    private static func newest(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): max(a, b)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }
}
