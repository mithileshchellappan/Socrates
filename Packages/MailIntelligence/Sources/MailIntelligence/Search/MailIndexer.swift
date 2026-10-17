import Foundation
import GRDB
import Search
import StudyCore

/// Writes `mail` search chunks (one source = one message): subject and sender first, then the
/// body in paragraphs of at most ~800 characters cut at sentences, without quoted replies and
/// signatures; `lemma_text` from Search's `Lemmatizer` in the message's language, so the search
/// engine matches mail as it matches transcripts; `course_id` follows the message's route.
public actor MailIndexer {
    /// What one catch-up did.
    public struct Report: Sendable, Equatable {
        public var messages = 0
        public var chunks = 0
    }

    public static let chunkLength = 800

    private let database: any DatabaseWriter
    private let index: SearchIndexRepository
    private let lemmatizer = Lemmatizer()

    public init(services: StudyServices) {
        self.init(database: services.database)
    }

    public init(database: any DatabaseWriter) {
        self.database = database
        index = SearchIndexRepository(database: database)
    }

    /// Indexes messages without chunks and re-indexes those whose route changed course.
    @discardableResult
    public func catchUp() async throws -> Report {
        let ids = try await database.read { db in
            try String.fetchAll(db, sql: """
                SELECT m.id FROM mail_message m
                WHERE NOT EXISTS (SELECT 1 FROM search_chunk c WHERE c.kind = 'mail' AND c.source_id = m.id)
                   OR EXISTS (SELECT 1 FROM search_chunk c WHERE c.kind = 'mail' AND c.source_id = m.id
                              AND c.course_id IS NOT m.course_id)
                ORDER BY m.received_at DESC
                """)
        }
        return try await reindex(ids.compactMap(UUID.init(uuidString:)))
    }

    /// Rebuilds the chunks of `ids` (e.g. after their bodies were parsed again).
    @discardableResult
    public func reindex(_ ids: [MailMessage.ID]) async throws -> Report {
        var report = Report()
        for page in ids.chunked(50) {
            let messages = try await database.read { db in
                try MailMessage.where { $0.id.in(Array(page)) }.fetchAll(db)
            }
            for message in messages {
                let chunks = chunks(for: message)
                try await index.replaceChunks(kind: .mail, sourceID: message.id, with: chunks)
                report.messages += 1
                report.chunks += chunks.count
            }
        }
        return report
    }

    /// Drops every mail chunk and indexes all mail again.
    @discardableResult
    public func reindexAll() async throws -> Report {
        try await database.write { db in
            try SearchChunk.where { $0.kind.eq(SearchChunkKind.mail) }.delete().execute(db)
        }
        return try await catchUp()
    }

    /// The chunks of one message.
    func chunks(for message: MailMessage) -> [SearchChunkInput] {
        let language = Self.language(of: message, lemmatizer: lemmatizer)
        let sender = [message.fromName, message.fromAddress].filter { !$0.isEmpty }.joined(separator: " ")
        let head = [message.subject, sender].filter { !$0.isEmpty }.joined(separator: " · ")
        var texts = [head.isEmpty ? "(no subject)" : head]
        texts += Self.paragraphs(of: Self.ownText(message.bodyText), limit: Self.chunkLength)
        return texts.map { text in
            SearchChunkInput(
                kind: .mail, sourceID: message.id, courseID: message.courseID, mailMessageID: message.id,
                lang: language, text: text, lemmaText: lemmatizer.lemmaText(of: text, language: language),
                sourceUpdatedAt: message.updatedAt
            )
        }
    }

    static func language(of message: MailMessage, lemmatizer: Lemmatizer) -> String {
        let code = message.language.prefix(2).lowercased()
        if code == "de" || code == "en" { return code }
        return lemmatizer.language(of: message.subject + "\n" + message.bodyText.prefix(2_000), fallback: "en")
    }

    // MARK: - Text

    /// The body without quoted replies ("> …", "On … wrote:", "Am … schrieb …:", forwarded
    /// originals) and without the signature ("-- ").
    static func ownText(_ body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "--" || line == "-- " || trimmed.hasPrefix("-----Original") || trimmed.hasPrefix("-----Urspr")
                || trimmed.hasPrefix("________________________________") {
                break
            }
            if (trimmed.hasPrefix("On ") && trimmed.hasSuffix("wrote:")) || (trimmed.hasPrefix("Am ") && trimmed.contains("schrieb") && trimmed.hasSuffix(":")) {
                break
            }
            if trimmed.hasPrefix(">") { continue }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Paragraphs (blank-line separated, whitespace collapsed) merged up to `limit` characters;
    /// longer ones cut at sentence ends.
    static func paragraphs(of text: String, limit: Int) -> [String] {
        let raw = text.components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var pieces: [String] = []
        for paragraph in raw {
            pieces += paragraph.count <= limit ? [paragraph] : sentences(of: paragraph, limit: limit)
        }
        var chunks: [String] = []
        var current = ""
        for piece in pieces {
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += "\n" + piece
            } else {
                chunks.append(current)
                current = piece
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// `text` cut after sentence ends into pieces of at most `limit` characters (a sentence
    /// longer than that is cut at a space).
    static func sentences(of text: String, limit: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        var sentence = ""
        func flushSentence() {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            sentence = ""
            guard !trimmed.isEmpty else { return }
            if current.isEmpty {
                current = trimmed
            } else if current.count + 1 + trimmed.count <= limit {
                current += " " + trimmed
            } else {
                pieces.append(current)
                current = trimmed
            }
            while current.count > limit {
                var cut = current.index(current.startIndex, offsetBy: limit)
                if let space = current[..<cut].lastIndex(of: " ") { cut = space }
                pieces.append(String(current[..<cut]))
                current = current[cut...].trimmingCharacters(in: .whitespaces)
            }
        }
        var previous: Character?
        for character in text {
            sentence.append(character)
            if character == " ", let previous, ".!?".contains(previous) { flushSentence() }
            previous = character
        }
        flushSentence()
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }
}
