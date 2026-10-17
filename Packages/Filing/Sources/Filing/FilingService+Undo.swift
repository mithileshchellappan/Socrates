import Foundation
import Processing
import StudyCore

extension FilingService {
    /// Removes exactly what a filing created, in one transaction:
    /// - a recording or capture: the recording with its segments, transcript, slide events, timed
    ///   spans and jobs (running ones are stopped through `cancelJobs` first); a capture's notes
    ///   and flags too, they came with it;
    /// - a deck: the deck and its pages, unless another lecture, capture or filing uses it or it
    ///   was in the library before (then only the link this filing made);
    /// - the lecture, when the filing created it and nothing else uses it now;
    /// - the filing row.
    /// Blob files stay (content-addressed; cleaned up later).
    public func undo(_ filingID: Filing.ID) async throws {
        guard let filing = try await store.fetch(Filing.self, id: filingID) else { throw FilingError.missing }
        if filing.kind != .deck, !filing.reusedExistingFile, let recordingID = filing.recordingID, let lectureID = filing.lectureID {
            let running = try await services.database.read { db in
                try Job.where { $0.recordingID.eq(recordingID) && $0.state.eq(JobState.running) }.fetchCount(db)
            }
            if running > 0 { await cancelJobs(lectureID) }
        }
        let now = now()
        let store = store
        try await services.database.write { db in
            try Self.undo(filing, in: db, store: store, now: now)
        }
        Log.importer.info("Undid filing \(filing.id, privacy: .public)")
    }

    static func undo(_ filing: Filing, in db: Database, store: RecordStore, now: Date) throws {
        let reused = filing.reusedExistingFile
        switch filing.kind {
        case .deck:
            guard let deckID = filing.deckID else { break }
            let removesDeck = try !reused && !deckIsUsedElsewhere(deckID, lectureID: filing.lectureID, filingID: filing.id, in: db)
            if let lectureID = filing.lectureID {
                // The link this filing made; a link that was there before stays.
                let ownLink = try LectureDeckSpan
                    .where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
                    .fetchAll(db)
                    .contains { removesDeck || $0.updatedAt >= filing.createdAt }
                if ownLink {
                    try unlinkDeck(deckID, from: lectureID, in: db, store: store, now: now)
                }
            }
            if removesDeck {
                try Deck.find(deckID).delete().execute(db)
            }
        default:
            guard let recordingID = filing.recordingID, !reused else { break }
            if filing.kind == .capture {
                let decks = try Set(SlideEvent.where { $0.recordingID.eq(recordingID) }.fetchAll(db).compactMap(\.deckID))
                try Note.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
                try Annotation.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
                if let lectureID = filing.lectureID {
                    for deckID in decks where try !deckLinkIsShared(deckID, lectureID: lectureID, recordingID: recordingID, in: db) {
                        try LectureDeckSpan
                            .where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
                            .delete()
                            .execute(db)
                    }
                }
            }
            try deleteRecording(recordingID, in: db)
        }
        if filing.createdLecture, let lectureID = filing.lectureID, try lectureIsUnused(lectureID, except: filing.id, in: db) {
            try Lecture.find(lectureID).delete().execute(db)
        }
        try Filing.find(filing.id).delete().execute(db)
    }

    /// Deletes a recording and everything only it uses. Timed spans and jobs reference it with
    /// SET NULL / CASCADE; spans are deleted explicitly so no orphan timeline remains.
    static func deleteRecording(_ recordingID: Recording.ID, in db: Database) throws {
        try LectureDeckSpan.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
        try Job.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
        try Recording.find(recordingID).delete().execute(db)
    }

    /// True when a deck is part of something besides this filing's lecture: another lecture's
    /// link, a capture's slide stamps, or another filing.
    static func deckIsUsedElsewhere(_ deckID: Deck.ID, lectureID: Lecture.ID?, filingID: Filing.ID, in db: Database) throws -> Bool {
        let otherLinks = try LectureDeckSpan
            .where { $0.deckID.eq(deckID) && $0.startTime.is(nil) }
            .fetchAll(db)
            .filter { $0.lectureID != lectureID }
            .count
        let stamps = try SlideEvent.where { $0.deckID.eq(deckID) }.fetchCount(db)
        let filings = try Filing.where { $0.deckID.eq(deckID) && $0.id.neq(filingID) }.fetchCount(db)
        return otherLinks + stamps + filings > 0
    }

    /// True when a capture's deck link on a lecture is also there for another reason: a deck
    /// filing, or another recording stamped on it.
    static func deckLinkIsShared(_ deckID: Deck.ID, lectureID: Lecture.ID, recordingID: Recording.ID, in db: Database) throws -> Bool {
        let deckFilings = try Filing.where { $0.deckID.eq(deckID) && $0.lectureID.eq(lectureID) && $0.kind.eq(FilingKind.deck) }.fetchCount(db)
        let otherStamps = try SlideEvent
            .where { $0.deckID.eq(deckID) && $0.lectureID.eq(lectureID) }
            .fetchAll(db)
            .filter { $0.recordingID != recordingID }
            .count
        return deckFilings + otherStamps > 0
    }

    /// Removes a deck from a lecture: the coarse link and the timed spans on it. The lecture's
    /// transcribed recordings are re-aligned when another deck remains.
    static func unlinkDeck(_ deckID: Deck.ID, from lectureID: Lecture.ID, in db: Database, store: RecordStore, now: Date) throws {
        try LectureDeckSpan.where { $0.lectureID.eq(lectureID) && $0.deckID.eq(deckID) }.delete().execute(db)
        let remaining = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) && $0.startTime.is(nil) }.fetchCount(db)
        if remaining > 0 {
            for job in try LectureImporter.alignmentJobs(lectureID: lectureID, in: db, now: now) {
                let stamped = store.stamp(job)
                try Job.upsert { stamped }.execute(db)
            }
        }
    }

    /// Nothing but this filing refers to the lecture: no recording, slides, notes, annotations
    /// or other filing.
    static func lectureIsUnused(_ lectureID: Lecture.ID, except filingID: Filing.ID, in db: Database) throws -> Bool {
        let recordings = try Recording.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let spans = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let notes = try Note.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let annotations = try Annotation.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let filings = try Filing.where { $0.lectureID.eq(lectureID) && $0.id.neq(filingID) }.fetchCount(db)
        return recordings + spans + notes + annotations + filings == 0
    }
}
