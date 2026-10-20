import Foundation
import SQLiteData

/// mr (docs/plan-actions.md §3–4): a lecture's slides as a page range of a deck, read and written
/// in one place. A lecture's slides are its coarse `lecture_deck_span` rows (no times); the newest
/// (by `updated_at`) is the one Review shows and alignment, search, the study pass and the coach
/// read (`current`). One deck may be linked to several lectures, each with its own range, and a
/// lecture holds at most one coarse span per deck.
///
/// Every reader of "the lecture's deck" goes through `current` / `pages(of:)`; every writer of a
/// lecture ↔ deck link that is not a filing (the agent's `link_deck_pages` / `unlink_deck`,
/// continuation detection, Undo of those) through `link` / `unlink` / `undo`, inside the caller's
/// write transaction, together with the change row (`DeckLinkResult.change`).
public enum LectureSlides {
    // MARK: - Reading

    /// The lecture's ranges (one per deck it links), oldest first; the last is `current`.
    public static func ranges(lectureID: Lecture.ID, in db: Database) throws -> [LectureSlideRange] {
        let spans = try LectureDeckSpan
            .where { $0.lectureID.eq(lectureID) && $0.startTime.is(nil) }
            .order(by: \.updatedAt)
            .fetchAll(db)
        guard !spans.isEmpty else { return [] }
        let decks = try decks(Set(spans.map(\.deckID)), in: db)
        return spans.compactMap { span in decks[span.deckID].flatMap { LectureSlideRange(span: span, deck: $0) } }
    }

    /// The lecture's slides: its newest coarse span's deck and range. Nil: the lecture has no
    /// slides (continuation detection may find them).
    public static func current(lectureID: Lecture.ID, in db: Database) throws -> LectureSlideRange? {
        try ranges(lectureID: lectureID, in: db).last
    }

    /// `current(lectureID:in:)` in a read of its own.
    public static func current(lectureID: Lecture.ID, database: any DatabaseReader) async throws -> LectureSlideRange? {
        try await database.read { db in try current(lectureID: lectureID, in: db) }
    }

    /// The range's deck pages, in page order (deck page numbers kept).
    public static func pages(of range: LectureSlideRange, in db: Database) throws -> [DeckPage] {
        let deckID = range.deckID
        let first = range.firstPage
        let last = range.lastPage
        return try DeckPage
            .where { $0.deckID.eq(deckID) && $0.pageNumber.gte(first) && $0.pageNumber.lte(last) }
            .order(by: \.pageNumber)
            .fetchAll(db)
    }

    /// Every lecture's range of a deck, by when the lecture was held (undated last).
    public static func lectures(usingDeck deckID: Deck.ID, in db: Database) throws -> [LectureSlideRange] {
        guard let deck = try Deck.find(deckID).fetchOne(db) else { return [] }
        let spans = try LectureDeckSpan.where { $0.deckID.eq(deckID) && $0.startTime.is(nil) }.order(by: \.updatedAt).fetchAll(db)
        let lectureIDs = Array(Set(spans.map(\.lectureID)))
        let lectures = Dictionary(
            try Lecture.where { $0.id.in(lectureIDs) }.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
        )
        // One range per lecture: its newest span of the deck.
        var newest: [Lecture.ID: LectureSlideRange] = [:]
        for span in spans {
            if let range = LectureSlideRange(span: span, deck: deck) { newest[span.lectureID] = range }
        }
        return newest.values.sorted { lhs, rhs in
            let left = order(lectures[lhs.lectureID])
            let right = order(lectures[rhs.lectureID])
            return left == right ? lhs.lectureID.uuidString < rhs.lectureID.uuidString : left < right
        }
    }

    /// The decks the student turned down for this lecture: unlinked (a `deck_unlink` change not
    /// undone) or a link they undid (a `deck_link` change undone). Continuation detection never
    /// links them to it again.
    public static func declinedDeckIDs(lectureID: Lecture.ID, in db: Database) throws -> Set<Deck.ID> {
        let changes = try AgentChange.where { $0.targetTable.eq(AgentChangeTarget.deckSpan) }.fetchAll(db)
        var declined: Set<Deck.ID> = []
        for change in changes {
            let lecture = change.after?.lectureID ?? change.before?.lectureID
            let deck = change.after?.deckID ?? change.before?.deckID
            guard lecture == lectureID, let deck else { continue }
            if change.kind == .deckUnlink, change.undoneAt == nil { declined.insert(deck) }
            if change.kind == .deckLink, change.undoneAt != nil { declined.insert(deck) }
        }
        return declined
    }

    /// `align` jobs (not saved) for the lecture's recordings that have a transcript and no queued
    /// or running transcription or alignment: the lecture's slides changed, so alignment must run
    /// again. Recordings still waiting for their transcript get alignment from the transcription.
    public static func alignmentJobs(lectureID: Lecture.ID, in db: Database, now: Date = Date()) throws -> [Job] {
        let recordings = try Recording.where { $0.lectureID.eq(lectureID) }.fetchAll(db)
        var jobs: [Job] = []
        for recording in recordings {
            let recordingID = recording.id
            let lines = try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.fetchCount(db)
            guard lines > 0 else { continue }
            let pending = try Job
                .where {
                    $0.recordingID.eq(recordingID)
                        && ($0.state.eq(JobState.queued) || $0.state.eq(JobState.running))
                        && ($0.stage.eq(JobStage.align) || $0.stage.eq(JobStage.transcribe))
                }
                .fetchCount(db)
            guard pending == 0 else { continue }
            jobs.append(Job(stage: .align, lectureID: lectureID, recordingID: recordingID, createdAt: now))
        }
        return jobs
    }

    // MARK: - Writing (inside the caller's write transaction)

    /// Makes or changes `lectureID`'s range of `deckID` (other lectures' ranges of the deck stay;
    /// the lecture's other decks stay, this one becomes `current`). Queues alignment of its
    /// transcribed recordings. Unchanged (`changed == false`, nothing written) when the lecture
    /// already has exactly this range. A deck without a course takes the lecture's.
    public static func link(
        lectureID: Lecture.ID, deckID: Deck.ID, firstPage: Int, lastPage: Int, source: SpanSource = .manual, confidence: Double = 1,
        in db: Database, store: RecordStore, now: Date
    ) throws -> DeckLinkResult {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { throw DeckLinkError.missingLecture }
        guard let deck = try Deck.find(deckID).fetchOne(db) else { throw DeckLinkError.missingDeck }
        if let course = deck.courseID, course != lecture.courseID { throw DeckLinkError.otherCourse }
        let count = max(deck.pageCount, 1)
        guard 1 <= firstPage, firstPage <= lastPage, lastPage <= count else { throw DeckLinkError.pagesOutOfRange(pageCount: count) }

        let existing = try LectureDeckSpan
            .where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
            .order(by: \.updatedAt)
            .fetchAll(db)
        let before = existing.last.flatMap { LectureSlideRange(span: $0, deck: deck) }
        if let before, existing.count == 1, before.firstPage == firstPage, before.lastPage == lastPage {
            let text = try text(lecture: lecture, deck: deck, range: before, linked: true, in: db)
            return DeckLinkResult(
                lectureID: lectureID, deckID: deckID, before: before, after: before, changed: false, alignJobs: [], title: text.title,
                summary: text.summary
            )
        }
        // One coarse span per lecture and deck.
        for extra in existing.dropLast() {
            try LectureDeckSpan.find(extra.id).delete().execute(db)
        }
        let span = store.stamp(LectureDeckSpan(
            id: existing.last?.id ?? UUID(), lectureID: lectureID, deckID: deckID, firstPage: firstPage, lastPage: lastPage,
            source: source, confidence: confidence
        ))
        try LectureDeckSpan.upsert { span }.execute(db)
        if deck.courseID == nil {
            let courseID: Course.ID? = lecture.courseID
            try Deck.find(deckID).update { $0.courseID = courseID; $0.updatedAt = now }.execute(db)
        }
        let after = LectureSlideRange(span: span, deck: deck)
        let jobs = try queueAlignment(lectureID: lectureID, in: db, store: store, now: now)
        let text = try text(lecture: lecture, deck: deck, range: after, linked: true, in: db)
        return DeckLinkResult(
            lectureID: lectureID, deckID: deckID, before: before, after: after, changed: true, alignJobs: jobs, title: text.title,
            summary: text.summary
        )
    }

    /// Removes `lectureID`'s link to `deckID`: its coarse span and the timed spans of its
    /// recordings on that deck. The deck stays (other lectures' ranges too). Alignment is queued
    /// again only when the lecture's current slides changed and it still has slides.
    public static func unlink(lectureID: Lecture.ID, deckID: Deck.ID, in db: Database, store: RecordStore, now: Date) throws -> DeckLinkResult {
        guard let lecture = try Lecture.find(lectureID).fetchOne(db) else { throw DeckLinkError.missingLecture }
        guard let deck = try Deck.find(deckID).fetchOne(db) else { throw DeckLinkError.missingDeck }
        let existing = try LectureDeckSpan
            .where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
            .order(by: \.updatedAt)
            .fetchAll(db)
        guard let before = existing.last.flatMap({ LectureSlideRange(span: $0, deck: deck) }) else { throw DeckLinkError.notLinked }
        let previous = try current(lectureID: lectureID, in: db)
        try removeLink(lectureID: lectureID, deckID: deckID, in: db)
        let jobs = try queueAlignmentIfCurrentChanged(lectureID: lectureID, from: previous, in: db, store: store, now: now)
        let text = try text(lecture: lecture, deck: deck, range: before, linked: false, in: db)
        return DeckLinkResult(
            lectureID: lectureID, deckID: deckID, before: before, after: nil, changed: true, alignJobs: jobs, title: text.title,
            summary: text.summary
        )
    }

    /// Undo of a `deck_link` / `deck_unlink` change, only while the link is still what the change
    /// made of it (else `DeckLinkError.changedSince`): a link the change made is removed, a range
    /// it changed goes back, a link it removed comes back with its range. A link that comes back
    /// keeps the `updated_at` it had (`spanUpdatedAt`), so a deck that was not the lecture's
    /// current one does not become it; rows without that value get now. Alignment is queued only
    /// when the lecture's current slides changed. Returns the `align` jobs queued. The caller
    /// marks the change undone in the same transaction.
    @discardableResult
    public static func undo(_ change: AgentChange, in db: Database, store: RecordStore, now: Date) throws -> [Job] {
        guard change.targetTable == .deckSpan, let before = change.before, let after = change.after,
              let lectureID = after.lectureID ?? before.lectureID, let deckID = after.deckID ?? before.deckID
        else { throw DeckLinkError.changedSince }
        guard try Lecture.find(lectureID).fetchCount(db) > 0, let deck = try Deck.find(deckID).fetchOne(db) else {
            throw DeckLinkError.changedSince
        }
        let link = try LectureDeckSpan
            .where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
            .order(by: \.updatedAt)
            .fetchAll(db)
            .last
            .flatMap { LectureSlideRange(span: $0, deck: deck) }
        let previous = try current(lectureID: lectureID, in: db)
        let restoredAt: Date = before.spanUpdatedAt ?? now
        switch change.kind {
        case .deckLink:
            guard let link, link.firstPage == after.firstPage, link.lastPage == after.lastPage else { throw DeckLinkError.changedSince }
            if before.exists == false {
                try removeLink(lectureID: lectureID, deckID: deckID, in: db)
                return try queueAlignmentIfCurrentChanged(lectureID: lectureID, from: previous, in: db, store: store, now: now)
            }
            guard let first = before.firstPage, let last = before.lastPage else { throw DeckLinkError.changedSince }
            let source = before.spanSource ?? link.source
            try LectureDeckSpan.find(link.spanID).update {
                $0.firstPage = Int?.some(first)
                $0.lastPage = Int?.some(last)
                $0.source = source
                $0.updatedAt = restoredAt
            }
            .execute(db)
            return try queueAlignmentIfCurrentChanged(lectureID: lectureID, from: previous, in: db, store: store, now: now)
        case .deckUnlink:
            guard link == nil, let first = before.firstPage, let last = before.lastPage else { throw DeckLinkError.changedSince }
            var span = store.stamp(LectureDeckSpan(
                id: change.targetID ?? UUID(), lectureID: lectureID, deckID: deckID, firstPage: first, lastPage: last,
                source: before.spanSource ?? .manual
            ))
            span.updatedAt = restoredAt
            try LectureDeckSpan.upsert { span }.execute(db)
            return try queueAlignmentIfCurrentChanged(lectureID: lectureID, from: previous, in: db, store: store, now: now)
        default:
            throw DeckLinkError.changedSince
        }
    }

    // MARK: - Helpers

    /// The lecture's spans on the deck (coarse and timed, OFF stretches included).
    static func removeLink(lectureID: Lecture.ID, deckID: Deck.ID, in db: Database) throws {
        try LectureDeckSpan.where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) }.delete().execute(db)
    }

    static func queueAlignment(lectureID: Lecture.ID, in db: Database, store: RecordStore, now: Date) throws -> [Job] {
        let jobs = try alignmentJobs(lectureID: lectureID, in: db, now: now).map(store.stamp)
        for job in jobs { try Job.upsert { job }.execute(db) }
        return jobs
    }

    /// Alignment again only when the lecture's current slides are no longer `previous` (another
    /// deck or range) and it still has slides (else continuation detection would run on it): a
    /// change to a deck that is not current leaves its recordings' alignment as it is.
    static func queueAlignmentIfCurrentChanged(
        lectureID: Lecture.ID, from previous: LectureSlideRange?, in db: Database, store: RecordStore, now: Date
    ) throws -> [Job] {
        guard let slides = try current(lectureID: lectureID, in: db) else { return [] }
        if let previous, previous.deckID == slides.deckID, previous.firstPage == slides.firstPage, previous.lastPage == slides.lastPage {
            return []
        }
        return try queueAlignment(lectureID: lectureID, in: db, store: store, now: now)
    }

    static func decks(_ ids: Set<Deck.ID>, in db: Database) throws -> [Deck.ID: Deck] {
        Dictionary(try Deck.where { $0.id.in(Array(ids)) }.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func order(_ lecture: Lecture?) -> Date { lecture?.heldAt ?? lecture?.createdAt ?? .distantFuture }

    /// The change row's title ("DC Lecture 5") and summary ("Uses DC L4's slides 21–40", "No
    /// longer uses …"): the deck named by the earliest other lecture that uses it, else by its title.
    static func text(lecture: Lecture, deck: Deck, range: LectureSlideRange?, linked: Bool, in db: Database) throws -> (title: String, summary: String) {
        var shorts: [Course.ID: String] = [:]
        func short(_ courseID: Course.ID) throws -> String {
            if let known = shorts[courseID] { return known }
            let course = try Course.find(courseID).fetchOne(db)
            let name = course.map { $0.shortName.isEmpty ? $0.name : $0.shortName } ?? ""
            shorts[courseID] = name
            return name
        }
        let course = try short(lecture.courseID)
        let title: String
        if let number = lecture.number {
            title = course.isEmpty ? "Lecture \(number)" : "\(course) Lecture \(number)"
        } else if !lecture.title.isEmpty {
            title = course.isEmpty ? lecture.title : "\(course) · \(lecture.title)"
        } else {
            title = course.isEmpty ? "Lecture" : "\(course) lecture"
        }
        let pages = range?.pagesText ?? "slides"
        let others = try lectures(usingDeck: deck.id, in: db).filter { $0.lectureID != lecture.id }
        var whose = ""
        if let other = others.first, let owner = try Lecture.find(other.lectureID).fetchOne(db), let number = owner.number {
            let ownerCourse = try short(owner.courseID)
            whose = "\(ownerCourse.isEmpty ? "" : ownerCourse + " ")L\(number)’s \(pages)"
        } else {
            let name = deck.title.isEmpty ? deck.fileName : deck.title
            whose = name.isEmpty ? pages : "\(pages) of \(name)"
        }
        return (title, linked ? "Uses \(whose)" : "No longer uses \(whose)")
    }
}
