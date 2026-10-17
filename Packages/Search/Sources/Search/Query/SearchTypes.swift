import Foundation
import StudyCore

/// What to search for.
public struct SearchQuery: Hashable, Sendable {
    /// Which kinds of hits to show (the All | Lectures | Notes filter).
    public enum Scope: String, CaseIterable, Hashable, Sendable {
        case all
        /// Transcripts and slides.
        case lectures
        case notes

        var kinds: [SearchChunkKind] {
            switch self {
            case .all: [.transcript, .slide, .note]
            case .lectures: [.transcript, .slide]
            case .notes: [.note]
            }
        }
    }

    /// As typed: words (prefix-matched while typing), "quoted phrases", hyphenated-words.
    public var text: String
    public var scope: Scope
    /// Only this course; nil = all courses.
    public var courseID: Course.ID?
    /// Other phrasings searched along with `text` and fused by rank ("Also searched"). The M5
    /// query planner (DE↔EN, Haiku) fills these through `QueryPlanning`.
    public var alternatives: [String]
    /// At most this many hits.
    public var limit: Int

    public init(
        _ text: String,
        scope: Scope = .all,
        courseID: Course.ID? = nil,
        alternatives: [String] = [],
        limit: Int = 100
    ) {
        self.text = text
        self.scope = scope
        self.courseID = courseID
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
}

/// Hits of one lecture (or of one deck no lecture uses, or the student's notes), best first.
public struct SearchGroup: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case lecture(Lecture.ID)
        case deck(Deck.ID)
        /// "Your notes".
        case notes
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
    /// "Your notes".
    public var groups: [SearchGroup]
    /// Course of every group and hit, for labels (lecturer surname, short name).
    public var courses: [Course.ID: Course]
    /// Lectures of the hits (a note's "DC L2").
    public var lectures: [Lecture.ID: Lecture]
    /// Decks of the slide hits (thumbnails).
    public var decks: [Deck.ID: Deck]
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

/// Supplies "Also searched" phrasings for a query: the hook for M5's DE↔EN Haiku query planner
/// and course-glossary expansion. M1 ships none.
public protocol QueryPlanning: Sendable {
    func alternatives(for query: SearchQuery) async throws -> [String]
}

extension Course {
    /// The lecturer's surname for transcript hits ("Prof. Dr. Ada Example" → "Example").
    public var lecturerSurname: String? {
        guard let name = professors.first else { return nil }
        let parts = name.split(whereSeparator: \.isWhitespace).filter { !$0.hasSuffix(".") }
        return parts.last.map(String.init)
    }
}
