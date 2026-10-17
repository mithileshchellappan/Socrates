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
    public func plan(lecture: Lecture, recording: Recording) async throws -> Plan? {
        let store = services.records
        guard let deckID = try await Self.deckID(lectureID: lecture.id, recordingID: recording.id, database: services.database) else {
            return nil
        }
        let course = try await store.fetch(Course.self, id: lecture.courseID)
        let pages = try await DeckRepository(store: store).pages(deckID: deckID)
        let segments = try await TranscriptRepository(store: store).segments(recordingID: recording.id)
        guard !segments.isEmpty else { throw ProcessingError.noTranscript }
        let events = try await RecordingRepository(store: store).slideEvents(recordingID: recording.id)

        let slides = AlignmentMapping.slides(pages)
        let anchors = AlignmentMapping.anchors(
            events: events, sampleRate: recording.sampleRate, deckID: deckID, validPages: Set(slides.map(\.page))
        )
        let result = aligner.align(
            slides: slides,
            transcript: AlignmentMapping.transcript(segments),
            anchors: anchors,
            duration: recording.duration > 0 ? recording.duration : nil,
            glossary: Glossary(text: course?.glossary ?? "")
        )
        let spans = AlignmentMapping.spans(result, lectureID: lecture.id, deckID: deckID, recordingID: recording.id)
            .map(store.stamp)
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

    /// The deck a lecture's recording is aligned against: the lecture's newest coarse span, else
    /// the deck its slide stamps were taken on.
    public static func deckID(lectureID: Lecture.ID, recordingID: Recording.ID, database: any DatabaseReader) async throws -> Deck.ID? {
        try await database.read { db in try deckID(lectureID: lectureID, recordingID: recordingID, in: db) }
    }

    /// `deckID(lectureID:recordingID:database:)` inside the caller's transaction.
    public static func deckID(lectureID: Lecture.ID, recordingID: Recording.ID, in db: Database) throws -> Deck.ID? {
        if let coarse = try LectureDeckSpan
            .where({ $0.lectureID.eq(lectureID) && $0.startTime.is(nil) })
            .order(by: \.updatedAt)
            .fetchAll(db)
            .last {
            return coarse.deckID
        }
        return try SlideEvent
            .where { $0.recordingID.eq(recordingID) && $0.deckID.isNot(nil) }
            .fetchOne(db)?
            .deckID
    }
}
