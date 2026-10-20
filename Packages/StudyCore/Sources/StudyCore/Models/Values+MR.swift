import Foundation

// mr (docs/plan-actions.md §3): shared decks. A lecture's slides are a page range of a deck (its
// coarse `lecture_deck_span`, no times); one deck may be linked to several lectures, each with its
// own range. No schema change: new values of `agent_change.kind` / `target_table` and new fields
// of `AgentChangeValues` (JSON).

extension AgentChangeKind {
    /// A lecture's page range of a deck made or changed: the agent's `link_deck_pages`, or
    /// continuation detection after a recording of a lecture without slides was transcribed
    /// (model ""). Undo removes the link it made, or puts the range back.
    public static let deckLink: Self = "deck_link"
    /// A lecture's link to a deck removed (the agent's `unlink_deck`). Undo links it again with
    /// the range it had.
    public static let deckUnlink: Self = "deck_unlink"
}

extension AgentChangeTarget {
    /// A coarse `lecture_deck_span` row (a lecture's page range of a deck). `before` / `after`
    /// hold `lectureID`, `deckID`, `firstPage`, `lastPage`, `spanSource`, `spanUpdatedAt`; `exists:
    /// false` = no link.
    public static let deckSpan: Self = "lecture_deck_span"
}

/// A lecture's slides: one deck's pages `firstPage...lastPage` (deck page numbers: slide 21 of the
/// deck is S21 in every lecture that shows it). Read from the lecture's coarse span; a span
/// without pages is the whole deck; pages are clamped to the deck.
public struct LectureSlideRange: Hashable, Sendable {
    /// The coarse span the range is read from.
    public var spanID: LectureDeckSpan.ID
    public var lectureID: Lecture.ID
    public var deckID: Deck.ID
    public var firstPage: Int
    public var lastPage: Int
    /// The deck's page count (the range is never outside `1...pageCount`).
    public var pageCount: Int
    /// `manual`: filed or linked at the student's word; `auto`: smart import or continuation
    /// detection (with its `confidence`).
    public var source: SpanSource
    public var confidence: Double
    public var updatedAt: Date

    public init(
        spanID: LectureDeckSpan.ID, lectureID: Lecture.ID, deckID: Deck.ID, firstPage: Int, lastPage: Int, pageCount: Int,
        source: SpanSource, confidence: Double, updatedAt: Date
    ) {
        self.spanID = spanID
        self.lectureID = lectureID
        self.deckID = deckID
        self.firstPage = firstPage
        self.lastPage = lastPage
        self.pageCount = pageCount
        self.source = source
        self.confidence = confidence
        self.updatedAt = updatedAt
    }

    /// The range of a coarse span on `deck`; nil for a timed span or another deck's.
    public init?(span: LectureDeckSpan, deck: Deck) {
        guard !span.isTimed, span.deckID == deck.id else { return nil }
        let count = max(deck.pageCount, 1)
        let first = min(max(span.firstPage ?? 1, 1), count)
        let last = min(max(span.lastPage ?? count, first), count)
        self.init(
            spanID: span.id, lectureID: span.lectureID, deckID: deck.id, firstPage: first, lastPage: last, pageCount: count,
            source: span.source, confidence: span.confidence, updatedAt: span.updatedAt
        )
    }

    public var pages: ClosedRange<Int> { firstPage...lastPage }
    public var count: Int { lastPage - firstPage + 1 }
    /// The whole deck.
    public var isWholeDeck: Bool { firstPage == 1 && lastPage == pageCount }

    public func contains(_ page: Int) -> Bool { pages.contains(page) }

    /// "slides 21–40", "slide 7" (DESIGN 9 "Range": an en dash).
    public var pagesText: String {
        firstPage == lastPage ? "slide \(firstPage)" : "slides \(firstPage)–\(lastPage)"
    }
}

/// Why a deck link was not written (`LectureSlides.link` / `unlink` / `undo`).
public enum DeckLinkError: Error, Hashable, Sendable, CustomStringConvertible {
    case missingLecture
    case missingDeck
    /// The deck belongs to another course than the lecture.
    case otherCourse
    /// The pages are not `1 <= first <= last <= pageCount`.
    case pagesOutOfRange(pageCount: Int)
    /// `unlink`: the lecture has no link to that deck.
    case notLinked
    /// Undo: the link is no longer what the change made of it.
    case changedSince

    public var description: String {
        switch self {
        case .missingLecture: "Unknown lecture."
        case .missingDeck: "Unknown deck."
        case .otherCourse: "The deck belongs to another course."
        case .pagesOutOfRange(let count): "Pages must be 1 to \(count), first before last."
        case .notLinked: "The lecture does not use that deck."
        case .changedSince: "Changed since; nothing undone."
        }
    }
}

/// What `LectureSlides.link` / `unlink` wrote, and the `agent_change` row that logs it.
public struct DeckLinkResult: Sendable {
    public var lectureID: Lecture.ID
    public var deckID: Deck.ID
    /// The lecture's range of the deck before (nil: no link).
    public var before: LectureSlideRange?
    /// …and after (nil: unlinked).
    public var after: LectureSlideRange?
    /// False when the link was already exactly so (nothing written, no change row).
    public var changed: Bool
    /// The `align` jobs queued with it (saved): the processor must be woken.
    public var alignJobs: [Job]
    /// The lecture as Today names it: "DC Lecture 5".
    public var title: String
    /// "Uses DC L4's slides 21–40", "No longer uses DC L4's slides 21–40".
    public var summary: String

    public init(
        lectureID: Lecture.ID, deckID: Deck.ID, before: LectureSlideRange?, after: LectureSlideRange?, changed: Bool,
        alignJobs: [Job], title: String, summary: String
    ) {
        self.lectureID = lectureID
        self.deckID = deckID
        self.before = before
        self.after = after
        self.changed = changed
        self.alignJobs = alignJobs
        self.title = title
        self.summary = summary
    }

    /// `before` / `after` as the change row keeps them.
    public var values: (before: AgentChangeValues, after: AgentChangeValues) {
        (Self.values(before, lectureID: lectureID, deckID: deckID), Self.values(after, lectureID: lectureID, deckID: deckID))
    }

    static func values(_ range: LectureSlideRange?, lectureID: Lecture.ID, deckID: Deck.ID) -> AgentChangeValues {
        guard let range else { return AgentChangeValues(exists: false, lectureID: lectureID, deckID: deckID) }
        return AgentChangeValues(
            exists: true, lectureID: lectureID, deckID: deckID, firstPage: range.firstPage, lastPage: range.lastPage,
            spanSource: range.source, spanUpdatedAt: range.updatedAt
        )
    }

    /// The change row of this result (nil when nothing changed): kind `deck_link` (a link made
    /// or changed) or `deck_unlink`, target the coarse span, `lecture_id` = the lecture. The
    /// caller sets the source columns it has (conversation, task, recording and time of a
    /// transcript quote, `api_call_id`) and inserts it in the SAME transaction
    /// (`AgentChangeRepository.insert`).
    public func change(
        sourceKind: SourceRef.Kind, quote: String, confidence: Double, model: String, now: Date
    ) -> AgentChange? {
        guard changed else { return nil }
        let (old, new) = values
        return AgentChange(
            kind: after == nil ? .deckUnlink : .deckLink, targetTable: .deckSpan, targetID: after?.spanID ?? before?.spanID,
            title: title, summary: summary, before: old, after: new, sourceKind: sourceKind, lectureID: lectureID, quote: quote,
            confidence: confidence, model: model, appliedAt: now, createdAt: now, updatedAt: now
        )
    }
}
