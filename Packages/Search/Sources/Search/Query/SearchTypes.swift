import Foundation
import StudyCore

/// What to search for.
public struct SearchQuery: Hashable, Sendable {
    /// Which kinds of hits to show (the All | Lectures | Notes | Mail filter).
    public enum Scope: String, CaseIterable, Hashable, Sendable {
        case all
        /// Transcripts and slides.
        case lectures
        case notes
        /// University mail (the chunks MailIntelligence indexes), one hit per message.
        case mail
        /// M5: the student's study material for the tutor: transcripts, slides, notes and verified
        /// further reading. Never mail (the tutor has web tools; PRD: the web agent never sees mail).
        case material
        /// M5: the verified further reading the study pass found (Search's Web segment).
        case web
        /// md: the student's kept documents (the agent's `search_documents`; the Documents group of
        /// All once the engine handles them). Never part of `material`: documents hold personal
        /// data and untrusted text, and the tutor's material reaches web tools.
        case documents

        public var kinds: [SearchChunkKind] {
            switch self {
            case .all: [.transcript, .slide, .note, .furtherReading, .mail]
            case .lectures: [.transcript, .slide]
            case .notes: [.note]
            case .mail: [.mail]
            case .material: [.transcript, .slide, .note, .furtherReading]
            case .web: [.furtherReading]
            case .documents: [.document]
            }
        }
    }

    /// As typed: words (prefix-matched while typing), "quoted phrases", hyphenated-words.
    public var text: String
    public var scope: Scope
    /// Only this course; nil = all courses.
    public var courseID: Course.ID?
    /// M5: only this lecture's chunks (`search_chunk.lecture_id`); nil = any. The tutor's
    /// `search_lectures {lecture}`.
    public var lectureID: Lecture.ID?
    /// Other phrasings searched along with `text` and fused by rank ("Also searched"). The M5
    /// query planner (DE↔EN, Haiku) fills these through `QueryPlanning`.
    public var alternatives: [String]
    /// At most this many hits.
    public var limit: Int

    public init(
        _ text: String,
        scope: Scope = .all,
        courseID: Course.ID? = nil,
        lectureID: Lecture.ID? = nil,
        alternatives: [String] = [],
        limit: Int = 100
    ) {
        self.text = text
        self.scope = scope
        self.courseID = courseID
        self.lectureID = lectureID
        self.alternatives = alternatives
        self.limit = limit
    }

    /// True when there is nothing to search for (an empty query shows nothing).
    public var isEmpty: Bool { Tokenizer.tokens(in: text).isEmpty }
}

/// Where a hit opens. SearchUI maps it to `StudyDestination`.
public enum SearchTarget: Hashable, Sendable {
    /// A lecture's review screen at a slide and/or second on a recording's clock (`recording`;
    /// nil: the lecture's first).
    case lecture(Lecture.ID, page: Int?, time: Double?, plays: Bool, recording: Recording.ID? = nil)
    /// A course page (a slide of a deck no lecture uses yet, a course-level note).
    case course(Course.ID)
    /// A mail message (the Mail screen, Inbox, with it selected).
    case mail(MailMessage.ID)
    /// M6: a note that is not on a slide (a lecture's or a course's): the Notes screen with it
    /// selected, scoped to its course (all notes when it has none).
    case note(Note.ID, course: Course.ID?)
    /// md: a kept document at a page (the Documents screen with it selected).
    case document(StudyDocument.ID, page: Int?)
}

/// Marks the matched words in a `SearchHit.snippet`; SearchUI highlights these runs.
public enum SearchMatchAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "StudyPortal.SearchMatch"
}

/// One search result: a transcript line, a slide or a note.
public struct SearchHit: Identifiable, Hashable, Sendable {
    /// The `search_chunk` row.
    public let id: Int64
    public var kind: SearchChunkKind
    public var courseID: Course.ID?
    /// The lecture the hit belongs to (for a slide: the lecture that showed it first).
    public var lectureID: Lecture.ID?
    public var deckID: Deck.ID?
    /// 1-based deck page: the slide on screen for a transcript line, the slide itself, a note's slide.
    public var page: Int?
    public var recordingID: Recording.ID?
    public var noteID: Note.ID?
    /// Seconds on the recording clock: a line's start, a slide's first visit, a note's moment.
    public var time: Double?
    /// The matched stretch of text; matched words carry `SearchMatchAttribute`.
    public var snippet: AttributedString
    /// Every query term matched (directly or through the slide on screen), not just some.
    public var matchesAllTerms: Bool
    public var target: SearchTarget?
    /// A note's own title (its first heading), a mail's subject; nil for other hits and untitled notes.
    public var title: String? = nil
    /// A mail hit's message and its sender's name (else address).
    public var mailMessageID: MailMessage.ID? = nil
    public var sender: String? = nil
    /// M5, a further-reading hit (`kind == .furtherReading`, `title` its title): the byline
    /// ("Barham et al. · SOSP 2003"), the page it links to and its annotation.
    public var byline: String? = nil
    public var url: URL? = nil
    public var annotationID: Annotation.ID? = nil
    /// md: a document hit's document (`kind == .document`; `title` its title, `page` its page).
    public var documentID: StudyDocument.ID? = nil
    /// M5: the chunk's whole text (the line, the slide's text, the note, "title · byline"), for
    /// the tutor's sources (`snippet` may be a window of it).
    public var text: String = ""
}

/// Hits of one lecture (or of one deck no lecture uses, or the student's notes), best first.
public struct SearchGroup: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case lecture(Lecture.ID)
        case deck(Deck.ID)
        /// "Your notes".
        case notes
        /// M5: "Web", the verified further reading (after the notes, before mail).
        case web
        /// Mail, one hit per message.
        case mail
        /// md: "Documents", the kept documents (after the notes, before Web).
        case documents
    }

    public var kind: Kind
    public var course: Course?
    public var lecture: Lecture?
    public var deck: Deck?
    public var hits: [SearchHit]

    public var id: Kind { kind }
}

public struct SearchResults: Hashable, Sendable {
    public var query: SearchQuery
    /// Courses with hits in order of their best hit, each course's lectures/decks likewise, then
    /// "Your notes", then Web (M5), then Mail.
    public var groups: [SearchGroup]
    /// Course of every group and hit, for labels (lecturer surname, short name).
    public var courses: [Course.ID: Course]
    /// Lectures of the hits (a note's "DC L2").
    public var lectures: [Lecture.ID: Lecture]
    /// Decks of the slide hits (thumbnails).
    public var decks: [Deck.ID: Deck]
    /// M5: what was also searched ("Also searched"): the query's alternatives that went into this
    /// search, in order, without the query itself; empty without a plan.
    public var alternatives: [String] = []
    /// M5: the semantic list was not ready within the search's `semanticWait` and is left out:
    /// search again without a limit to fuse it.
    public var semanticPending = false
    /// Wall time of the search.
    public var duration: Duration

    public init(
        query: SearchQuery,
        groups: [SearchGroup] = [],
        courses: [Course.ID: Course] = [:],
        lectures: [Lecture.ID: Lecture] = [:],
        decks: [Deck.ID: Deck] = [:],
        duration: Duration = .zero
    ) {
        self.query = query
        self.groups = groups
        self.courses = courses
        self.lectures = lectures
        self.decks = decks
        self.duration = duration
    }

    /// All hits in display order.
    public var hits: [SearchHit] { groups.flatMap(\.hits) }
    public var count: Int { groups.reduce(0) { $0 + $1.hits.count } }
    public var isEmpty: Bool { groups.isEmpty }

    public func hit(id: SearchHit.ID) -> SearchHit? {
        for group in groups { if let hit = group.hits.first(where: { $0.id == id }) { return hit } }
        return nil
    }
}

/// Supplies "Also searched" phrasings for a query: M5's `HaikuQueryPlanner` (DE↔EN and the
/// slides' terms). `SearchEngine.search` never calls it; `SearchEngine.plannedAlternatives(for:)`
/// does (after the cache), and the caller searches again with the answer.
public protocol QueryPlanning: Sendable {
    func alternatives(for query: SearchQuery) async throws -> [String]
}

/// On-device semantic retrieval (M5, docs/plan-m5.md §5.1): the chunks nearest in meaning to a
/// query. `SearchEngine` fuses this list with its keyword lists (RRF). The app's one is Search's
/// `SemanticIndex`; nil in an engine means keyword search only.
public protocol SemanticSearching: Sendable {
    /// Up to `limit` `search_chunk` ids in `query`'s scope (its kinds, `courseID`, `lectureID`),
    /// nearest to any of `texts` (the query and its alternatives) first. Empty while the model or
    /// the index is not ready; never waits for a download.
    func nearest(to texts: [String], query: SearchQuery, limit: Int) async throws -> [SemanticMatch]
}

/// One semantic neighbour of a query.
public struct SemanticMatch: Hashable, Sendable {
    /// The `search_chunk` row the vector stands for.
    public var chunkID: Int64
    /// Cosine similarity, -1…1 (vectors are L2-normalised).
    public var score: Double

    public init(chunkID: Int64, score: Double) {
        self.chunkID = chunkID
        self.score = score
    }
}

extension Note {
    /// The note's own title: its first heading, when it has one.
    var searchTitle: String? {
        guard let heading = blocks.first(where: { $0.type == .heading }) else { return nil }
        let text = heading.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

extension Course {
    /// The lecturer's surname for transcript hits ("Prof. Dr. Ada Example" → "Example").
    public var lecturerSurname: String? {
        guard let name = professors.first else { return nil }
        let parts = name.split(whereSeparator: \.isWhitespace).filter { !$0.hasSuffix(".") }
        return parts.last.map(String.init)
    }
}
