import Foundation
import Processing
import StudyCore

extension FilingService {
    /// Takes back what a filing did, in one transaction.
    ///
    /// - A dropped recording: the recording with its segments, transcript, slide events, timed
    ///   spans and jobs (its own running job is stopped through `cancelJobs` first; the lecture's
    ///   other recordings go on), and its audio file once nothing else uses it.
    /// - A capture is never deleted: once filed, its audio exists nowhere else (the live package
    ///   gave it up). Undo un-files it instead: the recording with its transcript, stamps, notes
    ///   and flags leaves the lecture and course, and the filing stays, without a lecture, for
    ///   Change… to file it again. Returns that filing.
    /// - A deck: the deck and its pages (and its PDF once nothing else uses it), unless another
    ///   lecture, capture or filing uses it or it was in the library before (then only the link
    ///   this filing made, and a deck it moved goes back to its course).
    /// - The lecture, when the filing created it and nothing else uses it now; a lecture the
    ///   filing dated gets its earlier date back while it still has the recording's.
    /// - The filing row.
    ///
    /// Returns the filing when it stays (an un-filed capture), nil when it is gone.
    @discardableResult
    public func undo(_ filingID: Filing.ID) async throws -> Filing? {
        guard let filing = try await store.fetch(Filing.self, id: filingID) else { throw FilingError.missing }
        if filing.kind == .capture {
            return try await unfileCapture(filing)
        }
        if filing.kind != .deck, !filing.reusedExistingFile, let recordingID = filing.recordingID {
            let running = try await services.database.read { db in
                try Job.where { $0.recordingID.eq(recordingID) && $0.state.eq(JobState.running) }.fetchCount(db)
            }
            if running > 0 { await cancelJobs(recordingID) }
        }
        let now = now()
        let store = store
        let orphans = try await services.database.write { db in
            try Self.undo(filing.id, in: db, store: store, now: now)
        }
        // Content-addressed files nothing points to any more (a private file dropped by mistake
        // must not stay in the library after Undo).
        for blob in orphans {
            do {
                try services.blobs.remove(blob)
            } catch {
                Log.importer.error("Removing an undone file failed: \(String(describing: error), privacy: .public)")
            }
        }
        Log.importer.info("Undid filing \(filing.id, privacy: .public)")
        return nil
    }

    /// The transaction body of Undo for decks and recordings. Returns the blobs no row uses now.
    static func undo(_ filingID: Filing.ID, in db: Database, store: RecordStore, now: Date) throws -> [BlobRef] {
        guard var filing = try Filing.find(filingID).fetchOne(db) else { throw FilingError.missing }
        let reused = filing.reusedExistingFile
        var blobs: [BlobRef] = []
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
                if let blob = try Deck.find(deckID).fetchOne(db)?.blob { blobs.append(blob) }
                try Deck.find(deckID).delete().execute(db)
            } else {
                try restorePriorDeckCourse(filing, deckID: deckID, in: db, stamp: now)
            }
        default:
            guard let recordingID = filing.recordingID, !reused else { break }
            let recording = try Recording.find(recordingID).fetchOne(db)
            if let lectureID = filing.lectureID {
                try restorePriorHeldAt(&filing, lectureID: lectureID, recordingStart: recording?.startedAt, in: db, stamp: now)
            }
            blobs += try RecordingSegment.where { $0.recordingID.eq(recordingID) }.fetchAll(db).compactMap(\.blob)
            try deleteRecording(recordingID, in: db)
        }
        if filing.createdLecture, let lectureID = filing.lectureID, try lectureIsUnused(lectureID, except: filing.id, in: db) {
            try Lecture.find(lectureID).delete().execute(db)
        }
        try Filing.find(filing.id).delete().execute(db)
        return try unreferenced(blobs, in: db)
    }

    /// Un-files a capture (Undo of a capture): keeps every row, takes them out of the lecture
    /// and course, and leaves the filing without a lecture.
    func unfileCapture(_ filing: Filing) async throws -> Filing {
        let now = now()
        let store = store
        let unfiled = try await services.database.write { db -> Filing in
            guard var current = try Filing.find(filing.id).fetchOne(db), let recordingID = current.recordingID else {
                throw FilingError.missing
            }
            let oldLectureID = current.lectureID
            let started = try Recording.find(recordingID).fetchOne(db)?.startedAt
            if let oldLectureID {
                try Self.restorePriorHeldAt(&current, lectureID: oldLectureID, recordingStart: started, in: db, stamp: now)
            }
            try Self.unfileRecording(recordingID, from: oldLectureID, in: db, store: store, now: now)
            let createdLecture = current.createdLecture
            current.courseID = nil
            current.lectureID = nil
            current.lectureSessionID = nil
            current.createdLecture = false
            current.source = .manual
            current.confidence = 0
            // Written before the lecture goes: deleting it would take the filing along.
            let stamped = store.stamp(current)
            try Filing.upsert { stamped }.execute(db)
            if createdLecture, let oldLectureID, try Self.lectureIsUnused(oldLectureID, except: current.id, in: db) {
                try Lecture.find(oldLectureID).delete().execute(db)
            }
            return stamped
        }
        Log.importer.info("Un-filed capture \(filing.id, privacy: .public)")
        await afterImport()
        return unfiled
    }

    /// Takes a recording and what hangs off it out of its lecture and course: transcript, stamps,
    /// notes, flags and jobs stay, without a lecture; its timed spans and queued alignment go (they
    /// belong to the lecture's slides), and so does a capture's deck link when nothing else
    /// needs it.
    static func unfileRecording(_ recordingID: Recording.ID, from oldLectureID: Lecture.ID?, in db: Database, store: RecordStore, now: Date) throws {
        guard var recording = try Recording.find(recordingID).fetchOne(db) else { throw FilingError.missing }
        let noLecture: Lecture.ID? = nil
        let noCourse: Course.ID? = nil
        if let oldLectureID { try dropStudyPass(of: oldLectureID, builtOn: recordingID, in: db) }
        recording.lectureID = nil
        recording.courseID = nil
        let stamped = store.stamp(recording)
        try Recording.upsert { stamped }.execute(db)

        if let oldLectureID {
            let decks = try Set(SlideEvent.where { $0.recordingID.eq(recordingID) }.fetchAll(db).compactMap(\.deckID))
            for deckID in decks where try !deckLinkIsShared(deckID, lectureID: oldLectureID, recordingID: recordingID, in: db) {
                try LectureDeckSpan
                    .where { $0.lectureID.eq(oldLectureID) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
                    .delete()
                    .execute(db)
            }
        }
        try TranscriptSegment.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = noLecture; $0.updatedAt = now }.execute(db)
        try SlideEvent.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = noLecture; $0.updatedAt = now }.execute(db)
        try Note.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = noLecture; $0.courseID = noCourse; $0.updatedAt = now }.execute(db)
        try Annotation.where { $0.recordingID.eq(recordingID) && $0.studyUnitID.is(nil) }
            .update { $0.lectureID = noLecture; $0.updatedAt = now }.execute(db)
        try LectureDeckSpan.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
        try Job.where { $0.recordingID.eq(recordingID) && $0.stage.eq(JobStage.align) && $0.state.eq(JobState.queued) }
            .delete().execute(db)
        try Job.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = noLecture; $0.updatedAt = now }.execute(db)
    }

    /// Deletes a recording and everything only it uses. Timed spans and jobs reference it with
    /// SET NULL / CASCADE; spans are deleted explicitly so no orphan timeline remains.
    static func deleteRecording(_ recordingID: Recording.ID, in db: Database) throws {
        try LectureDeckSpan.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
        try Job.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
        try Recording.find(recordingID).delete().execute(db)
    }

    /// The blobs among `blobs` that no recording segment or deck refers to any more.
    static func unreferenced(_ blobs: [BlobRef], in db: Database) throws -> [BlobRef] {
        var seen = Set<String>()
        return try blobs.filter { blob in
            guard seen.insert(blob.sha256).inserted else { return false }
            let sha = blob.sha256
            let segments = try RecordingSegment.where { $0.blobSHA256.eq(sha) }.fetchCount(db)
            let decks = try Deck.where { $0.blobSHA256.eq(sha) }.fetchCount(db)
            return segments + decks == 0
        }
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
    /// of the student's own or other filing (the study pass's rows go with the lecture).
    static func lectureIsUnused(_ lectureID: Lecture.ID, except filingID: Filing.ID, in db: Database) throws -> Bool {
        let recordings = try Recording.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let spans = try LectureDeckSpan.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let notes = try Note.where { $0.lectureID.eq(lectureID) }.fetchCount(db)
        let annotations = try Annotation.where { $0.lectureID.eq(lectureID) && $0.studyUnitID.is(nil) }.fetchCount(db)
        let filings = try Filing.where { $0.lectureID.eq(lectureID) && $0.id.neq(filingID) }.fetchCount(db)
        return recordings + spans + notes + annotations + filings == 0
    }
}
