import Foundation
import StudyCore

/// Manual "slide starts here" markers (PRD #9): `slide_event` rows of kind `manual` that the
/// aligner uses as given. Setting or removing one re-runs alignment for the recording at once
/// through `realign` (the app passes `Processing.Realigner.realign`), which rewrites the timed
/// spans; the screen picks them up through observation.
public struct AnchorEditor: Sendable {
    public typealias Realign = @Sendable (Lecture.ID, Recording.ID) async throws -> Void

    public let store: RecordStore
    public let realign: Realign

    public init(store: RecordStore, realign: @escaping Realign) {
        self.store = store
        self.realign = realign
    }

    /// "Slide `page` starts here" at `seconds` (`page` nil = not on the slides from here),
    /// replacing manual markers within a second of it, then re-aligns.
    @discardableResult
    public func setStart(
        page: Int?,
        at seconds: Double,
        lectureID: Lecture.ID,
        recordingID: Recording.ID,
        deckID: Deck.ID?
    ) async throws -> SlideEvent? {
        let event = try await RecordingRepository(store: store).setManualAnchor(
            recordingID: recordingID, lectureID: lectureID, deckID: deckID, page: page, at: seconds
        )
        try await realign(lectureID, recordingID)
        return event
    }

    /// Removes markers, then re-aligns.
    public func remove(_ markerIDs: [SlideEvent.ID], lectureID: Lecture.ID, recordingID: Recording.ID) async throws {
        guard !markerIDs.isEmpty else { return }
        try await store.database.write { db in
            try SlideEvent
                .where { $0.id.in(markerIDs) && $0.kind.eq(SlideEventKind.manual) }
                .delete()
                .execute(db)
        }
        try await realign(lectureID, recordingID)
    }

    /// Manual markers at `[start, end)` on the clock (a transcript line that "has a marker").
    public static func markers(in events: [SlideEvent], from start: Double, to end: Double, sampleRate: Double) -> [SlideEvent] {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        return events.filter { event in
            guard event.kind == .manual, let sample = event.sampleTime else { return false }
            let time = Double(sample) / rate
            return time >= start && time < end
        }
    }

    /// Seconds on the clock of an event.
    public static func time(of event: SlideEvent, sampleRate: Double) -> Double? {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        return event.sampleTime.map { Double($0) / rate }
    }
}
