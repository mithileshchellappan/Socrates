import Foundation
import Processing
import StudyCore

extension FilingSignal.Kind {
    /// What was said in the recording matches a deck of the course (`evidence`: the deck's file).
    public static let spokenContent: Self = "spoken_content"
}

extension FilingService {
    /// A second look at a recording smart import was unsure about, once it has a transcript:
    /// what was said is held against the slides of every course (`SpokenContent`). When one
    /// course's deck clearly matches, an unfiled recording is filed to the lecture with that deck
    /// (one without a recording yet, nearest in date; else wherever the matcher puts it in that
    /// course), a recording filed for review to another course moves there, and one already in
    /// the right place is confirmed. The filing stays `auto`. Filings the user made, captures and
    /// recordings filed with confidence are never touched; each recording gets this look once.
    ///
    /// Returns the filing when it changed.
    @discardableResult
    public func fileBySpokenContent(recordingID: Recording.ID) async throws -> Filing? {
        guard let filing = try await FilingRepository(store: store).latest(recordingID: recordingID),
              Self.wantsSecondLook(filing)
        else { return nil }
        let (transcript, decks) = try await services.database.read { db in
            let lines = try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.fetchAll(db)
            return (lines.map(\.text).joined(separator: " "), try Self.deckWords(db))
        }
        guard let match = SpokenContent.match(transcript: SpokenContent.words(transcript), decks: decks),
              let deck = try await store.fetch(Deck.self, id: match.deckID)
        else {
            Log.importer.info("Spoken content does not settle the filing of \(recordingID, privacy: .public)")
            return nil
        }
        let signal = FilingSignal(kind: .spokenContent, evidence: deck.fileName, weight: match.weight)
        Log.importer.info(
            "Spoken content of \(recordingID, privacy: .public): \(match.similarity, privacy: .public) vs \(match.runnerUp, privacy: .public)"
        )

        let library = try await loadLibrary()
        // Already where the slides are: confirm.
        if filing.courseID == match.courseID, let lectureID = filing.lectureID,
           let info = library.lecture(lectureID), info.deckIDs.isEmpty || info.deckIDs.contains(match.deckID) {
            var confirmed = filing
            confirmed.signals.append(signal)
            confirmed.confidence = 1 - (1 - filing.confidence) * (1 - signal.weight)
            confirmed.candidates = []
            return try await store.save(confirmed)
        }

        guard let course = library.course(match.courseID) else { return nil }
        let recording = try await store.fetch(Recording.self, id: recordingID)
        let target: LectureTarget
        let fit: Double
        let open = library.lectures(courseID: course.id).filter {
            $0.deckIDs.contains(match.deckID) && !$0.hasRecording && $0.lecture.id != filing.lectureID
        }
        if let lecture = Self.nearest(open, to: recording?.startedAt) {
            target = .lecture(lecture.lecture.id)
            fit = 1
        } else {
            let evidence = try await storedEvidence(of: filing)
            guard let choice = FilingMatcher(library: library).lectureChoices(course, evidence, contested: []).first else { return nil }
            target = choice.target
            fit = choice.place.confidence
        }
        return try await move(
            filing, to: target, courseID: course.id,
            reason: .evidence([signal], confidence: signal.weight * fit)
        )
    }

    /// Gives every unsure recording that has a transcript its look by spoken content (at launch,
    /// after slides arrive). Returns the filings that changed.
    @discardableResult
    public func fileUnsureRecordingsBySpokenContent() async -> [Filing] {
        let candidates: [Recording.ID]
        do {
            candidates = try await services.database.read { db in
                try Filing.where { $0.kind.eq(FilingKind.recording) && $0.source.eq(FilingSource.auto) }
                    .fetchAll(db)
                    .filter(Self.wantsSecondLook)
                    .compactMap(\.recordingID)
                    .filter { id in try TranscriptSegment.where { $0.recordingID.eq(id) }.fetchCount(db) > 0 }
            }
        } catch {
            Log.importer.error("Listing unsure recordings failed: \(String(describing: error), privacy: .public)")
            return []
        }
        var changed: [Filing] = []
        for recordingID in Set(candidates) {
            do {
                if let filing = try await fileBySpokenContent(recordingID: recordingID) { changed.append(filing) }
            } catch {
                Log.importer.error("Filing by spoken content failed: \(String(describing: error), privacy: .public)")
            }
        }
        return changed
    }

    /// Unfiled, or filed on its own for review, and not looked at by content before.
    static func wantsSecondLook(_ filing: Filing) -> Bool {
        filing.kind == .recording && filing.source == .auto
            && (filing.lectureID == nil || filing.needsReview)
            && !filing.signals.contains { $0.kind == .spokenContent }
    }

    /// Word counts of every deck that belongs to a course.
    static func deckWords(_ db: Database) throws -> [SpokenContent.DeckWords] {
        let decks = try Deck.where { $0.courseID.isNot(nil) }.fetchAll(db)
        return try decks.compactMap { deck in
            guard let courseID = deck.courseID else { return nil }
            let text = try DeckPage.where { $0.deckID.eq(deck.id) }.fetchAll(db).map(\.text).joined(separator: " ")
            let counts = SpokenContent.words(text)
            return counts.isEmpty ? nil : SpokenContent.DeckWords(deckID: deck.id, courseID: courseID, counts: counts)
        }
    }

    /// The lecture dated nearest to `date` (undated lectures last, then in creation order).
    static func nearest(_ lectures: [FilingLibrary.LectureInfo], to date: Date?) -> FilingLibrary.LectureInfo? {
        guard let date else { return lectures.first }
        return lectures.min { lhs, rhs in
            let left = lhs.lecture.heldAt.map { abs($0.timeIntervalSince(date)) } ?? .infinity
            let right = rhs.lecture.heldAt.map { abs($0.timeIntervalSince(date)) } ?? .infinity
            return left < right
        }
    }
}
