import Foundation
import SQLiteData

// Record types added in schema v9 (M5: search & tutor). docs/plan-m5.md §3–4.

// MARK: - Agent memory

/// One thing the agent remembers about the student (a small typed memory, kept by the agent with
/// its `remember` / `update_memory` / `forget` tools and shown in every mail chat and tutor
/// conversation as a `<memory>` block). The agent writes only what the student said: `quote` is an
/// exact span of the student's own words in `conversation_id` (verified in code). The student sees
/// every memory in the chat's Memory sheet, edits its text (`edited_at`) or forgets it.
///
/// Nothing is deleted: forgetting sets `forgotten_at`, and every reader skips those rows.
@Table("agent_memory")
public struct AgentMemory: StudyRecord {
    public let id: UUID
    public var kind: AgentMemoryKind
    /// The course a `course` memory is about (CASCADE: it goes with the course).
    @Column("course_id") public var courseID: Course.ID?
    /// The memory as the agent wrote it (or the student edited it), at most `textLimit` characters.
    public var text: String
    /// The student's own words it was written from (exact, from the conversation).
    public var quote: String
    /// The conversation it was written in (SET NULL when that is deleted).
    @Column("conversation_id") public var conversationID: AgentConversation.ID?
    /// `agent` (a tool call) or `user` (written in the sheet, if that is ever offered).
    @Column("created_by") public var createdBy: Author
    /// The student changed `text` in the Memory sheet.
    @Column("edited_at") public var editedAt: Date?
    /// Forgotten (by the student or the agent's `forget`); never shown or sent again.
    @Column("forgotten_at") public var forgottenAt: Date?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date
    /// v12 (mc): a `plan` memory's choice in a form the planner reads (away days, skips, caps,
    /// which date to sit, seminar hours, classes not attended); written with the memory by
    /// `mark_away_days` / `plan_adjust`. Forgetting the memory drops the rule.
    @Column("plan_rule", as: PlanRule?.JSONRepresentation.self) public var planRule: PlanRule?
    /// v16 (ln): a `preference` memory's length for lecture notes, typed (written with the memory
    /// by `set_notes_length`). Forgetting the memory drops the rule.
    @Column("notes_rule", as: NotesRule?.JSONRepresentation.self) public var notesRule: NotesRule?

    public init(
        id: UUID = UUID(),
        kind: AgentMemoryKind,
        courseID: Course.ID? = nil,
        text: String,
        quote: String,
        conversationID: AgentConversation.ID? = nil,
        createdBy: Author = .agent,
        editedAt: Date? = nil,
        forgottenAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        planRule: PlanRule? = nil,
        notesRule: NotesRule? = nil
    ) {
        self.id = id
        self.kind = kind
        self.courseID = courseID
        self.text = text
        self.quote = quote
        self.conversationID = conversationID
        self.createdBy = createdBy
        self.editedAt = editedAt
        self.forgottenAt = forgottenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.planRule = planRule
        self.notesRule = notesRule
    }

    /// A memory's text is at most this long.
    public static let textLimit = 200
    /// At most this many memories are active; `remember` is refused beyond it.
    public static let activeLimit = 40
}

// MARK: - Search index (device-local, never synced)

/// One on-device embedding of a stretch of indexed text (M5 semantic search): a window of
/// consecutive transcript lines of one slide section, a slide, a note or a further-reading row.
/// Written only by Search's `SemanticIndex` (plain SQL like `search_chunk`).
///
/// `chunk_id` is the hit the vector stands for (a window's first line; SET NULL when the indexer
/// re-cuts the unit, until the index reconciles it). A vector is reused for unchanged text: the
/// index matches `model` + `text_sha256` within the unit before it embeds anything.
@Table("search_vector")
public struct SearchVector: Hashable, Sendable {
    public let id: Int64
    @Column("chunk_id") public var chunkID: Int64?
    /// The unit's `SearchChunkKind` (transcript, slide, note, further_reading).
    public var kind: SearchChunkKind
    /// The unit the indexer re-cuts as a whole: a recording (transcript windows), a deck (slides),
    /// a note, an annotation (further reading).
    @Column("unit_id") public var unitID: UUID
    @Column("course_id") public var courseID: Course.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    /// SHA-256 (hex) of the exact text embedded.
    @Column("text_sha256") public var textSHA256: String
    /// The embedding model and its revision ("nl-contextual-latn-<revision>"); vectors of another
    /// model are never compared.
    public var model: String
    public var dimensions: Int
    /// `dimensions` little-endian Float16 values, L2-normalised.
    public var vector: Data
    @Column("updated_at") public var updatedAt: Date
}

/// The query planner's answer for one query (M5, Haiku DE↔EN): the "Also searched" phrasings.
/// Device-local cache; a query planned once is never sent again (until the planner's version
/// changes, which changes the key).
@Table("search_plan")
public struct SearchPlan: Hashable, Sendable {
    /// `SearchPlan.key(for:version:)` of the query.
    @Column("query_key", primaryKey: true) public var queryKey: String
    /// JSON `[String]`: the alternatives, best first.
    public var alternatives: String
    @Column("api_call_id") public var apiCallID: APICall.ID?
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(queryKey: String, alternatives: [String], apiCallID: APICall.ID? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.queryKey = queryKey
        let data = (try? JSONEncoder().encode(alternatives)) ?? Data("[]".utf8)
        self.alternatives = String(decoding: data, as: UTF8.self)
        self.apiCallID = apiCallID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The cache key of a query: "v<version>:" + the text folded (case and diacritics), with
    /// runs of whitespace as one space, trimmed ("Nachteil  Paravirtualisierung" →
    /// "v1:nachteil paravirtualisierung").
    public static func key(for query: String, version: Int = 1) -> String {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = folded.split(whereSeparator: \.isWhitespace)
        return "v\(version):" + words.joined(separator: " ")
    }

    /// The decoded alternatives (empty when the JSON is unreadable).
    public var decodedAlternatives: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(alternatives.utf8))) ?? []
    }
}
