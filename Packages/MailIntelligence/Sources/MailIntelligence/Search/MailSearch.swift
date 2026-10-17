import Foundation
import GRDB
import Search
import StudyCore

/// Where a mail search looks (the app maps MailUI's `MailScope` onto it).
public struct MailSearchScope: Hashable, Sendable {
    public enum Place: Hashable, Sendable {
        /// Every synced mailbox.
        case all
        case inbox
        /// A course's mail in Inbox and Archive.
        case course(Course.ID)
        /// University, Newsletters, … in Inbox and Archive.
        case category(MailCategory)
        case sent
        case archive
    }

    public var place: Place
    /// Sender name or address contains this (case-insensitive).
    public var from: String?
    /// Received at or after.
    public var since: Date?
    /// Received before.
    public var until: Date?

    public init(_ place: Place = .all, from: String? = nil, since: Date? = nil, until: Date? = nil) {
        self.place = place
        self.from = from
        self.since = since
        self.until = until
    }

    public static let all = MailSearchScope()
}

/// One message a search found.
public struct MailSearchHit: Hashable, Sendable, Identifiable {
    public var messageID: MailMessage.ID
    public var subject: String
    public var fromName: String
    public var fromAddress: String
    public var receivedAt: Date
    public var courseID: Course.ID?
    /// The best matching stretch of the message (its chunk text, shortened).
    public var snippet: String
    /// bm25 of the best chunk (lower is better).
    public var score: Double

    public var id: MailMessage.ID { messageID }
}

/// Keyword search over `mail` chunks (the Mail toolbar search, Q&A tools). Every word must occur
/// in the message (any chunk), as a prefix of a word while typing or as a lemma ("Abgabe" finds
/// "Abgaben", "ging" finds "gehen"); results by relevance, newest first on ties.
public struct MailSearch: Sendable {
    public let database: any DatabaseReader

    public init(services: StudyServices) {
        database = services.database
    }

    public init(database: any DatabaseReader) {
        self.database = database
    }

    public func search(_ query: String, in scope: MailSearchScope = .all, limit: Int = 50) async throws -> [MailSearchHit] {
        let terms = Self.terms(of: query)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let filter = Self.filter(for: scope)
        return try await database.read { db in
            // Every term must match some chunk of the message.
            var candidates: Set<String>?
            for term in terms {
                let ids = try String.fetchSet(db, sql: """
                    SELECT DISTINCT c.source_id FROM search_fts JOIN search_chunk c ON c.id = search_fts.rowid
                    WHERE search_fts MATCH ? AND c.kind = 'mail'
                    """, arguments: [term])
                candidates = candidates.map { $0.intersection(ids) } ?? ids
                if candidates?.isEmpty == true { return [] }
            }
            guard let candidates else { return [] }
            let any = terms.count == 1 ? terms[0] : terms.map { "(\($0))" }.joined(separator: " OR ")
            // bm25 per chunk (materialized: an auxiliary function cannot run inside the
            // aggregate), then the best chunk of each message (SQLite takes the bare columns
            // from the row `min` picked).
            let rows = try Row.fetchCursor(db, sql: """
                WITH hits AS MATERIALIZED (
                    SELECT c.source_id AS id, bm25(search_fts, 4.0, 1.0) AS score, c.text AS text,
                           m.subject AS subject, m.from_name AS from_name, m.from_address AS from_address,
                           m.received_at AS received_at, m.course_id AS course_id
                    FROM search_fts
                    JOIN search_chunk c ON c.id = search_fts.rowid
                    JOIN mail_message m ON m.id = c.source_id
                    LEFT JOIN mailbox b ON b.id = m.mailbox_id
                    WHERE search_fts MATCH ? AND c.kind = 'mail' \(filter.sql)
                )
                SELECT id, min(score) AS score, text, subject, from_name, from_address, received_at, course_id
                FROM hits
                GROUP BY id
                """, arguments: StatementArguments([any]) + filter.arguments)
            var hits: [MailSearchHit] = []
            while let row = try rows.next() {
                let id: String = row["id"]
                guard candidates.contains(id), let messageID = UUID(uuidString: id) else { continue }
                let courseID: String? = row["course_id"]
                hits.append(MailSearchHit(
                    messageID: messageID,
                    subject: row["subject"],
                    fromName: row["from_name"],
                    fromAddress: row["from_address"],
                    receivedAt: row["received_at"],
                    courseID: courseID.flatMap(UUID.init(uuidString:)),
                    snippet: Self.snippet(row["text"]),
                    score: row["score"]
                ))
            }
            hits.sort { ($0.score, $1.receivedAt) < ($1.score, $0.receivedAt) }
            return Array(hits.prefix(limit))
        }
    }

    // MARK: - Query

    /// One FTS5 expression per query word: the word as a prefix, or one of its German and English
    /// lemmas. Function words are left out unless the query has nothing else.
    static func terms(of query: String) -> [String] {
        let words = Folding.words(query).filter { !$0.isEmpty }
        let content = words.filter { !stopwords.contains($0) }
        let chosen = content.isEmpty ? words : content
        let lemmatizer = Lemmatizer()
        var seen = Set<String>()
        var terms: [String] = []
        for word in chosen where seen.insert(word).inserted {
            var options = ["text:\(quoted(word))*"]
            var lemmas = Set<String>()
            for language in ["de", "en"] {
                let lemma = Folding.fold(lemmatizer.lemmaText(of: word, language: language))
                if !lemma.isEmpty, !lemma.contains(" "), lemma != word { lemmas.insert(lemma) }
            }
            for lemma in lemmas.sorted() {
                options.append("lemma_text:\(quoted(lemma))\(lemma.count >= 5 ? "*" : "")")
            }
            options.append("lemma_text:\(quoted(word))*")
            terms.append(options.count == 1 ? options[0] : "(" + options.joined(separator: " OR ") + ")")
        }
        return terms
    }

    static func quoted(_ word: String) -> String {
        "\"" + word.replacing("\"", with: "\"\"") + "\""
    }

    static let stopwords: Set<String> = [
        "the", "a", "an", "of", "and", "or", "to", "in", "on", "for", "is", "are", "was", "be", "with", "at", "by",
        "der", "die", "das", "und", "oder", "ein", "eine", "ist", "sind", "zu", "im", "in", "am", "von", "mit", "fur", "den", "dem",
    ]

    struct Filter {
        var sql: String
        var arguments: StatementArguments
    }

    static func filter(for scope: MailSearchScope) -> Filter {
        var sql = ""
        var arguments = StatementArguments()
        switch scope.place {
        case .all:
            break
        case .inbox:
            sql += " AND b.role = 'inbox'"
        case .sent:
            sql += " AND b.role = 'sent'"
        case .archive:
            sql += " AND b.role = 'archive'"
        case .course(let id):
            sql += " AND m.course_id = ? AND b.role IN ('inbox', 'archive')"
            arguments += [id.uuidString.lowercased()]
        case .category(let category):
            sql += " AND m.category = ? AND m.course_id IS NULL AND b.role IN ('inbox', 'archive')"
            arguments += [category.rawValue]
        }
        if let from = scope.from?.trimmingCharacters(in: .whitespaces), !from.isEmpty {
            sql += " AND (m.from_address LIKE ? ESCAPE '\\' OR m.from_name LIKE ? ESCAPE '\\')"
            let pattern = "%" + from.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_") + "%"
            arguments += [pattern, pattern]
        }
        if let since = scope.since {
            sql += " AND m.received_at >= ?"
            arguments += [since]
        }
        if let until = scope.until {
            sql += " AND m.received_at < ?"
            arguments += [until]
        }
        return Filter(sql: sql, arguments: arguments)
    }

    static func snippet(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > 240 else { return flat }
        return String(flat.prefix(240)) + "…"
    }
}
