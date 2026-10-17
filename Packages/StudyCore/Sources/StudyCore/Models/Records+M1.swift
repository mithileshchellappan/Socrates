import Foundation
import SQLiteData

// Record types added in schema v4 (milestone 1): semester, filing provenance, search index.

// MARK: - Semester

/// A semester's lecture period and breaks; weekly slots become sessions inside it.
///
/// v4 seeds WS 2026/27 (`Semester.winter2026`, fixed id); the user edits it in Settings.
@Table("semester")
public struct Semester: StudyRecord {
    public let id: UUID
    /// "WS 2026/27"
    public var name: String
    /// First day of lectures (inclusive).
    @Column("lecture_start") public var lectureStart: CalendarDay
    /// Last day of lectures (inclusive).
    @Column("lecture_end") public var lectureEnd: CalendarDay
    /// Days without classes inside the lecture period.
    @Column(as: [SemesterBreak].JSONRepresentation.self) public var breaks: [SemesterBreak]
    /// IANA time zone of the university.
    @Column("time_zone") public var timeZone: String
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        lectureStart: CalendarDay,
        lectureEnd: CalendarDay,
        breaks: [SemesterBreak] = [],
        timeZone: String = "Europe/Lisbon",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.lectureStart = lectureStart
        self.lectureEnd = lectureEnd
        self.breaks = breaks
        self.timeZone = timeZone
        self.updatedAt = updatedAt
    }

    /// The id v4 seeds WS 2026/27 with: fixed, so every device (and a later CloudKit sync) has the
    /// same row.
    public static let winter2026ID = UUID(uuid: (0x57, 0x53, 0x20, 0x26, 0x27, 0x00, 0x40, 0x00, 0x80, 0x00, 0, 0, 0, 0, 0, 0x01))

    /// WS 2026/27 at Exampleton: lectures 5 Oct 2026 – 29 Jan 2027, Christmas break 24 Dec – 6 Jan.
    public static let winter2026 = Semester(
        id: winter2026ID,
        name: "WS 2026/27",
        lectureStart: CalendarDay(year: 2026, month: 10, day: 5),
        lectureEnd: CalendarDay(year: 2027, month: 1, day: 29),
        breaks: [SemesterBreak(
            name: "Christmas break",
            first: CalendarDay(year: 2026, month: 12, day: 24),
            last: CalendarDay(year: 2027, month: 1, day: 6)
        )],
        updatedAt: Date(timeIntervalSince1970: 0)
    )

    public var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }

    /// True when classes can meet on `day`: inside the lecture period and in no break.
    public func isLectureDay(_ day: CalendarDay) -> Bool {
        lectureStart <= day && day <= lectureEnd && !breaks.contains { $0.contains(day) }
    }

    /// True when `day` lies in the lecture period (breaks included).
    public func contains(_ day: CalendarDay) -> Bool {
        lectureStart <= day && day <= lectureEnd
    }
}

// MARK: - Filing

/// How one imported file (deck, recording, capture) was filed to a course and lecture: the
/// provenance behind smart import's toast (Undo, Change…) and the course's Slides list.
///
/// One row per file import. A lecture usually has two (its deck, its recording), each decided on
/// its own evidence. Undo removes what the filing created; Change moves the file and marks the
/// row `manual`.
@Table("filing")
public struct Filing: StudyRecord {
    public let id: UUID
    public var kind: FilingKind
    /// Original file name ("03_Cloud_Storage_v1.pdf").
    @Column("file_name") public var fileName: String
    @Column("blob_sha256") public var blobSHA256: String
    /// Nil while unfiled (no course fit well enough and the user has not chosen yet).
    @Column("course_id") public var courseID: Course.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("lecture_session_id") public var lectureSessionID: LectureSession.ID?
    @Column("deck_id") public var deckID: Deck.ID?
    @Column("recording_id") public var recordingID: Recording.ID?
    public var source: FilingSource
    /// 0…1 for the chosen destination.
    public var confidence: Double
    @Column(as: [FilingSignal].JSONRepresentation.self) public var signals: [FilingSignal]
    /// Runner-up destinations, best first.
    @Column(as: [FilingCandidate].JSONRepresentation.self) public var candidates: [FilingCandidate]
    /// This filing created `lectureID` (Undo removes the lecture when nothing else uses it).
    @Column("created_lecture") public var createdLecture: Bool
    @Column("created_at") public var createdAt: Date
    @Column("updated_at") public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: FilingKind,
        fileName: String,
        blobSHA256: String = "",
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        lectureSessionID: LectureSession.ID? = nil,
        deckID: Deck.ID? = nil,
        recordingID: Recording.ID? = nil,
        source: FilingSource = .auto,
        confidence: Double = 0,
        signals: [FilingSignal] = [],
        candidates: [FilingCandidate] = [],
        createdLecture: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.fileName = fileName
        self.blobSHA256 = blobSHA256
        self.courseID = courseID
        self.lectureID = lectureID
        self.lectureSessionID = lectureSessionID
        self.deckID = deckID
        self.recordingID = recordingID
        self.source = source
        self.confidence = confidence
        self.signals = signals
        self.candidates = candidates
        self.createdLecture = createdLecture
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Search index

/// One searchable piece of text (a stretch of transcript, a slide, a note), derived from the
/// library by the Search module and never synced.
///
/// Not a `StudyRecord`: the integer primary key is the rowid the FTS5 tables (`SearchText`,
/// `SearchTrigram`) index as external content; triggers keep them in step with this table, and
/// foreign keys delete chunks with their lecture, recording, deck or note. Write it only with
/// delete + insert (`SearchChunk.insert { SearchChunk.Draft(…) }`), never `INSERT OR REPLACE`.
@Table("search_chunk")
public struct SearchChunk: Hashable, Sendable {
    public let id: Int64
    public var kind: SearchChunkKind
    /// The row the chunk was cut from: the first transcript segment, the deck page, the note.
    @Column("source_id") public var sourceID: UUID
    @Column("course_id") public var courseID: Course.ID?
    @Column("lecture_id") public var lectureID: Lecture.ID?
    @Column("deck_id") public var deckID: Deck.ID?
    @Column("page_number") public var pageNumber: Int?
    @Column("recording_id") public var recordingID: Recording.ID?
    @Column("note_id") public var noteID: Note.ID?
    /// Seconds on the recording clock.
    @Column("start_time") public var startTime: Double?
    @Column("end_time") public var endTime: Double?
    /// BCP 47 of `text`, when known.
    public var lang: String
    /// Text as shown (snippets, highlights).
    public var text: String
    /// Lower-cased lemmas of `text` (NLTagger), space separated, for inflection-insensitive match.
    @Column("lemma_text") public var lemmaText: String
    /// `updated_at` of the source when indexed; a newer source needs re-indexing.
    @Column("source_updated_at") public var sourceUpdatedAt: Date?
    @Column("updated_at") public var updatedAt: Date
}

/// FTS5 index over `search_chunk.text` + `lemma_text` (unicode61, diacritics removed, 2- and
/// 3-letter prefix indexes). `rowid` is `SearchChunk.id`.
@Table("search_fts")
public struct SearchText: FTS5 {
    public let rowid: Int64
    public let text: String
    @Column("lemma_text") public let lemmaText: String
}

/// FTS5 trigram index over `search_chunk.text` (substrings, German compounds, typos). `rowid` is
/// `SearchChunk.id`.
@Table("search_trigram")
public struct SearchTrigram: FTS5 {
    public let rowid: Int64
    public let text: String
}
