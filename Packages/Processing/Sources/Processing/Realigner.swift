import Alignment
import Foundation
import StudyCore

/// Slide alignment of one recording of a lecture: deck pages + transcript + slide stamps and manual
/// "slide starts here" markers → timed `lecture_deck_span` rows (OFF spans have no pages).
///
/// `LectureProcessor` runs it as the queued `align` stage. The review screen calls `realign` right
/// after the user sets or removes a manual marker: it runs at once, outside the job queue (a
/// transcription may hold the queue for minutes), and takes about 10 ms for a 90-minute lecture.
public struct Realigner: Sendable {
    public let services: StudyServices
    public let aligner: SlideAligner

    public init(services: StudyServices, aligner: SlideAligner = SlideAligner()) {
        self.services = services
        self.aligner = aligner
    }

    /// The outcome of one alignment run, not yet written.
    public struct Plan: Sendable {
        public var lectureID: Lecture.ID
        public var recordingID: Recording.ID
        public var deckID: Deck.ID
        public var spans: [LectureDeckSpan]
        /// Anchors the decoder kept, of those given (stamps + manual markers).
        public var anchorsUsed: Int
        public var anchorsGiven: Int
    }

    /// Re-aligns a recording now and replaces its timed spans in one transaction. Returns the new
    /// spans; empty when the lecture has no deck (nothing is written then).
    @discardableResult
    public func realign(lectureID: Lecture.ID, recordingID: Recording.ID) async throws -> [LectureDeckSpan] {
        guard let recording = try await services.records.fetch(Recording.self, id: recordingID) else {
            throw ProcessingError.missingRecording
        }
        guard let lecture = try await services.records.fetch(Lecture.self, id: lectureID) else {
            throw ProcessingError.missingLecture
        }
        guard let plan = try await plan(lecture: lecture, recording: recording) else { return [] }
        try await services.database.write { db in
            try Self.write(plan, in: db)
        }
        Log.alignment.info("Re-aligned \(recording.id, privacy: .public): \(plan.spans.count) spans, \(plan.anchorsUsed) of \(plan.anchorsGiven) anchors")
        return plan.spans
    }

    /// Computes the spans for a recording without writing them. Nil when the lecture has no deck.
    /// Throws `ProcessingError.noTranscript` when the recording has no transcript yet.
    ///
    /// mr: only the lecture's pages (`LectureSlides.current`): the aligner never sees a page
    /// outside the range, and stamps or markers on such a page are dropped.
    public func plan(lecture: Lecture, recording: Recording) async throws -> Plan? {
        let store = services.records
        let lectureID = lecture.id
        let recordingID = recording.id
        let read: (slides: Slides, pages: [DeckPage])? = try await services.database.read { db in
            guard let slides = try Self.slides(lectureID: lectureID, recordingID: recordingID, in: db) else { return nil }
            let pages = try Self.pages(of: slides, in: db)
            return (slides, pages)
        }
        guard let read else { return nil }
        let course = try await store.fetch(Course.self, id: lecture.courseID)
        let segments = try await TranscriptRepository(store: store).segments(recordingID: recording.id)
        guard !segments.isEmpty else { throw ProcessingError.noTranscript }
        let events = try await RecordingRepository(store: store).slideEvents(recordingID: recording.id)
        return plan(
            lecture: lecture, recording: recording, deckID: read.slides.deckID, pages: read.pages, segments: segments, events: events,
            glossary: Glossary(text: course?.glossary ?? "")
        )
    }

    /// The alignment of `segments` against `pages` (already the lecture's range) with the
    /// recording's stamps and markers on them. Pure: continuation detection uses it inside its
    /// own write.
    func plan(
        lecture: Lecture, recording: Recording, deckID: Deck.ID, pages: [DeckPage], segments: [TranscriptSegment], events: [SlideEvent],
        glossary: Glossary
    ) -> Plan {
        let store = services.records
        let slides = AlignmentMapping.slides(pages)
        let validPages = Set(slides.map(\.page))
        let anchors = AlignmentMapping.anchors(events: events, sampleRate: recording.sampleRate, deckID: deckID, validPages: validPages)
        let duration: Double? = recording.duration > 0 ? recording.duration : nil
        let result = aligner.align(
            slides: slides, transcript: AlignmentMapping.transcript(segments), anchors: anchors, duration: duration, glossary: glossary
        )
        let spans = AlignmentMapping.spans(result, lectureID: lecture.id, deckID: deckID, recordingID: recording.id).map(store.stamp)
        return Plan(
            lectureID: lecture.id, recordingID: recording.id, deckID: deckID, spans: spans,
            anchorsUsed: result.anchors.count, anchorsGiven: anchors.count
        )
    }

    /// Replaces the recording's timed spans with the plan's, inside the caller's transaction.
    public static func write(_ plan: Plan, in db: Database) throws {
        try LectureDeckSpan
            .where { $0.lectureID.eq(plan.lectureID) && $0.recordingID.eq(plan.recordingID) && $0.startTime.isNot(nil) }
            .delete()
            .execute(db)
        for span in plan.spans { try LectureDeckSpan.upsert { span }.execute(db) }
    }

    /// What a lecture's recording is aligned against (mr): the lecture's slides
    /// (`LectureSlides.current`: one deck's page range), else the deck its slide stamps were taken
    /// on, whole (a capture whose deck link is gone).
    public struct Slides: Hashable, Sendable {
        public var deckID: Deck.ID
        /// Nil: the whole deck (the stamps' deck without a link).
        public var range: LectureSlideRange?
    }

    /// `Slides` of a lecture's recording inside the caller's transaction; nil: nothing to align
    /// against (continuation detection may find the slides).
    public static func slides(lectureID: Lecture.ID, recordingID: Recording.ID, in db: Database) throws -> Slides? {
        if let range = try LectureSlides.current(lectureID: lectureID, in: db) {
            return Slides(deckID: range.deckID, range: range)
        }
        guard let stamped = try stampedDeckID(recordingID: recordingID, in: db) else { return nil }
        return Slides(deckID: stamped, range: nil)
    }

    /// The deck pages `slides` covers, in page order (deck page numbers kept).
    public static func pages(of slides: Slides, in db: Database) throws -> [DeckPage] {
        if let range = slides.range { return try LectureSlides.pages(of: range, in: db) }
        let deckID = slides.deckID
        return try DeckPage.where { $0.deckID.eq(deckID) }.order(by: \.pageNumber).fetchAll(db)
    }

    /// The deck the recording's slide stamps were taken on, if any.
    public static func stampedDeckID(recordingID: Recording.ID, in db: Database) throws -> Deck.ID? {
        try SlideEvent
            .where { $0.recordingID.eq(recordingID) && $0.deckID.isNot(nil) }
            .fetchOne(db)?
            .deckID
    }

    /// The deck a lecture's recording is aligned against: the lecture's current range's deck,
    /// else the deck its slide stamps were taken on.
    public static func deckID(lectureID: Lecture.ID, recordingID: Recording.ID, database: any DatabaseReader) async throws -> Deck.ID? {
        try await database.read { db in try deckID(lectureID: lectureID, recordingID: recordingID, in: db) }
    }

    /// `deckID(lectureID:recordingID:database:)` inside the caller's transaction.
    public static func deckID(lectureID: Lecture.ID, recordingID: Recording.ID, in db: Database) throws -> Deck.ID? {
        try slides(lectureID: lectureID, recordingID: recordingID, in: db)?.deckID
    }
}
