import CryptoKit
import Foundation
import GRDB
import StudyCore

/// What the semantic index embeds (M5, docs/plan-m5.md §5.1): per unit the indexer re-cuts as a
/// whole (a recording's transcript, a deck, a note, a further-reading row), the stretches of text
/// that get one vector each.
///
/// - Transcript: consecutive lines of one slide section (the slide on screen, or one off-slide
///   stretch), up to about 60 words; the window stands for its first line's chunk.
/// - Slide, note, further reading: one window per chunk.
/// - Mail: never.
enum SemanticWindows {
    /// The chunk kinds the index embeds.
    static let kinds: [SearchChunkKind] = [.transcript, .slide, .note, .furtherReading]
    /// A transcript window closes before a line that would take it over this many words (a
    /// window under `minimumWords` takes the line anyway).
    static let windowWords = 60
    static let minimumWords = 20
    /// Texts shorter than this are not embedded: a title-only slide ("Applications") or a lone
    /// "OK." sits near every short query in this model's space (measured on the parity library)
    /// and keyword search finds them anyway.
    static let minimumIndexedWords = 6

    /// A unit: the chunk kind and the id of what the indexer re-cuts (`search_vector.unit_id`).
    struct Unit: Hashable, Sendable {
        var kind: SearchChunkKind
        /// Lower-case UUID text, as stored.
        var id: String
    }

    struct Window: Sendable, Equatable {
        /// The chunk the vector stands for (a transcript window's first line).
        var chunkID: Int64
        var text: String
        /// "de" / "en" from the chunk (NaturalLanguage's hint).
        var language: String?
        var sha256: String
        var courseID: String?
        var lectureID: String?
    }

    /// The column that names a unit, per kind.
    static func unitColumn(_ kind: SearchChunkKind) -> String {
        switch kind {
        case .transcript: "recording_id"
        case .slide: "deck_id"
        case .note: "note_id"
        default: "source_id"
        }
    }

    /// The unit's windows, from its chunks as they are now.
    static func windows(of unit: Unit, in db: Database) throws -> [Window] {
        let order = unit.kind == .transcript ? "start_time, id" : (unit.kind == .slide ? "page_number, id" : "id")
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, deck_id, page_number, text, lang, course_id, lecture_id FROM search_chunk
            WHERE kind = ? AND \(unitColumn(unit.kind)) = ? ORDER BY \(order)
            """, arguments: [unit.kind.rawValue, unit.id])
        guard unit.kind == .transcript else {
            return rows.compactMap { row in
                let text: String = row["text"]
                guard wordCount(text) >= minimumIndexedWords else { return nil }
                return window(chunkID: row["id"], text: text, language: row["lang"], course: row["course_id"], lecture: row["lecture_id"])
            }
        }
        var windows: [Window] = []
        var lines: [String] = []
        var first: Row?
        var words = 0
        var section: String?
        func flush() {
            guard let first, !lines.isEmpty, words >= minimumIndexedWords else { return }
            windows.append(window(
                chunkID: first["id"], text: lines.joined(separator: " "), language: first["lang"], course: first["course_id"],
                lecture: first["lecture_id"]))
        }
        for row in rows {
            let text: String = row["text"]
            let count = wordCount(text)
            guard count > 0 else { continue }
            let deck: String? = row["deck_id"]
            let page: Int? = row["page_number"]
            let key = "\(deck ?? "-")#\(page.map(String.init) ?? "-")"
            if first == nil || key != section || (words + count > windowWords && words >= minimumWords) {
                flush()
                first = row
                lines = []
                words = 0
                section = key
            }
            lines.append(text)
            words += count
        }
        flush()
        return windows
    }

    static func window(chunkID: Int64, text: String, language: String?, course: String?, lecture: String?) -> Window {
        Window(
            chunkID: chunkID, text: text, language: language.flatMap { $0.isEmpty ? nil : $0 }, sha256: sha256(text),
            courseID: course, lectureID: lecture)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Staleness

    /// Units whose vectors do not follow their chunks: none yet, chunks newer than the vectors,
    /// vectors whose chunk the indexer deleted (`chunk_id` NULL after a re-cut), or vectors of
    /// another model. Newest chunks first. And units with vectors but no chunks (orphans).
    static func work(_ db: Database, model: String) throws -> (stale: [Unit], orphans: [Unit]) {
        let kindList = kinds.map { "'\($0.rawValue)'" }.joined(separator: ", ")
        var chunkUnits: [Unit: Date] = [:]
        let chunks = try Row.fetchCursor(db, sql: """
            SELECT kind, unit, max(updated_at) AS newest FROM (
              SELECT kind, CASE kind WHEN 'transcript' THEN recording_id WHEN 'slide' THEN deck_id
                                     WHEN 'note' THEN note_id ELSE source_id END AS unit, updated_at
              FROM search_chunk WHERE kind IN (\(kindList))
            ) WHERE unit IS NOT NULL GROUP BY kind, unit
            """)
        while let row = try chunks.next() {
            let unit = Unit(kind: SearchChunkKind(rawValue: row["kind"]), id: row["unit"])
            chunkUnits[unit] = row["newest"] ?? .distantPast
        }
        struct Held {
            var newest: Date
            var loose: Int
            var foreign: Int
        }
        var vectorUnits: [Unit: Held] = [:]
        let vectors = try Row.fetchCursor(db, sql: """
            SELECT kind, unit_id, max(updated_at) AS newest, sum(chunk_id IS NULL) AS loose, sum(model <> ?) AS other_model
            FROM search_vector GROUP BY kind, unit_id
            """, arguments: [model])
        while let row = try vectors.next() {
            let unit = Unit(kind: SearchChunkKind(rawValue: row["kind"]), id: row["unit_id"])
            vectorUnits[unit] = Held(newest: row["newest"] ?? .distantPast, loose: row["loose"] ?? 0, foreign: row["other_model"] ?? 0)
        }
        var stale: [(Unit, Date)] = []
        for (unit, newest) in chunkUnits {
            guard let held = vectorUnits[unit] else {
                stale.append((unit, newest))
                continue
            }
            if held.newest < newest || held.loose > 0 || held.foreign > 0 { stale.append((unit, newest)) }
        }
        let orphans = vectorUnits.keys.filter { chunkUnits[$0] == nil }
        return (stale.sorted { $0.1 > $1.1 }.map(\.0), Array(orphans))
    }
}
