import Foundation
import GRDB
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
        try await fileBySpokenContent(recordingID: recordingID, decks: nil)
    }

    /// `decks`: the slides' words, computed once for a batch (nil: read now).
    func fileBySpokenContent(recordingID: Recording.ID, decks given: [SpokenContent.DeckWords]?) async throws -> Filing? {
        guard let filing = try await FilingRepository(store: store).latest(recordingID: recordingID), Self.isUnsure(filing) else {
            return nil
        }
        let stamp = try await services.database.read { db in try Self.transcriptStamp(recordingID, in: db) }
        guard let stamp, Self.wantsSecondLook(filing, transcript: stamp) else { return nil }
        let lines = try await services.database.read { db in
            try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.fetchAll(db).map(\.text)
        }
        let decks: [SpokenContent.DeckWords]
        if let given {
            decks = given
        } else {
            decks = try await deckWords()
        }
        guard let match = SpokenContent.match(transcript: SpokenContent.words(lines.joined(separator: " ")), decks: decks),
              let deck = try await store.fetch(Deck.self, id: match.deckID)
        else {
            Log.importer.info("Spoken content does not settle the filing of \(recordingID, privacy: .public)")
            try await noteLook(filing, transcript: stamp)
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
            let store = store
            return try await services.database.write { db -> Filing? in
                // Only if nobody changed it while the transcript and slides were read.
                guard var confirmed = try Filing.find(filing.id).fetchOne(db), confirmed.updatedAt == filing.updatedAt else { return nil }
                confirmed.signals.append(signal)
                confirmed.confidence = 1 - (1 - confirmed.confidence) * (1 - signal.weight)
                confirmed.candidates = []
                let stamped = store.stamp(confirmed)
                try Filing.upsert { stamped }.execute(db)
                return stamped
            }
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
        do {
            return try await move(
                filing, to: target, courseID: course.id,
                reason: .evidence([signal], confidence: signal.weight * fit)
            )
        } catch is Superseded {
            Log.importer.info("Filing of \(recordingID, privacy: .public) changed meanwhile; the second look gives way")
            return nil
        }
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
                    .filter(Self.isUnsure)
                    .compactMap { filing -> Recording.ID? in
                        guard let id = filing.recordingID, let stamp = try Self.transcriptStamp(id, in: db),
                              Self.wantsSecondLook(filing, transcript: stamp) else { return nil }
                        return id
                    }
            }
        } catch {
            Log.importer.error("Listing unsure recordings failed: \(String(describing: error), privacy: .public)")
            return []
        }
        guard !candidates.isEmpty else { return [] }
        // The slides' words once for the batch (every deck of the library is tokenized).
        let decks: [SpokenContent.DeckWords]
        do {
            decks = try await deckWords()
        } catch {
            Log.importer.error("Reading the slides' words failed: \(String(describing: error), privacy: .public)")
            return []
        }
        var changed: [Filing] = []
        for recordingID in Set(candidates) {
            do {
                if let filing = try await fileBySpokenContent(recordingID: recordingID, decks: decks) { changed.append(filing) }
            } catch {
                Log.importer.error("Filing by spoken content failed: \(String(describing: error), privacy: .public)")
            }
        }
        return changed
    }

    /// Unfiled, or filed on its own for review.
    static func isUnsure(_ filing: Filing) -> Bool {
        filing.kind == .recording && filing.source == .auto && (filing.lectureID == nil || filing.needsReview)
    }

    /// Unsure, and not looked at by content before: never after a look that settled it, and
    /// after one that did not only once the transcript changed (`transcript` is its stamp).
    static func wantsSecondLook(_ filing: Filing, transcript stamp: String) -> Bool {
        guard isUnsure(filing) else { return false }
        let looks = filing.signals.filter { $0.kind == .spokenContent }
        if looks.isEmpty { return true }
        guard looks.allSatisfy({ $0.weight == 0 }) else { return false }
        return !looks.contains { $0.evidence == unsettledEvidence(stamp) }
    }

    /// The evidence of a look that did not settle the filing: the transcript it read.
    static func unsettledEvidence(_ stamp: String) -> String { "unsettled " + stamp }

    /// The transcript's version (its line count and newest change); nil without one.
    static func transcriptStamp(_ recordingID: Recording.ID, in db: Database) throws -> String? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS lines, max("updated_at") AS changed FROM "transcript_segment" WHERE "recording_id" = ?
            """, arguments: [recordingID.uuidString.lowercased()]) else { return nil }
        let lines: Int = row["lines"]
        guard lines > 0 else { return nil }
        let changed: String? = row["changed"]
        return "\(lines) \(changed ?? "")"
    }

    /// Records a look that did not settle the filing (a `spokenContent` signal of weight 0), so
    /// launches and drops do not look again until the transcript changes. Only while nobody
    /// changed the filing meanwhile.
    func noteLook(_ filing: Filing, transcript stamp: String) async throws {
        let store = store
        let signal = FilingSignal(kind: .spokenContent, evidence: Self.unsettledEvidence(stamp), weight: 0)
        try await services.database.write { db in
            guard var current = try Filing.find(filing.id).fetchOne(db), current.updatedAt == filing.updatedAt else { return }
            current.signals.removeAll { $0.kind == .spokenContent && $0.weight == 0 }
            current.signals.append(signal)
            let stamped = store.stamp(current)
            try Filing.upsert { stamped }.execute(db)
        }
    }

    /// Word counts of every deck that belongs to a course: the pages are read in one go, the
    /// words counted after the read (it never holds a reader while it tokenizes).
    func deckWords() async throws -> [SpokenContent.DeckWords] {
        let texts = try await services.database.read { db -> [(Deck.ID, Course.ID, String)] in
            try Deck.where { $0.courseID.isNot(nil) }.fetchAll(db).compactMap { deck in
                guard let courseID = deck.courseID else { return nil }
                let text = try DeckPage.where { $0.deckID.eq(deck.id) }.fetchAll(db).map(\.text).joined(separator: " ")
                return (deck.id, courseID, text)
            }
        }
        return texts.compactMap { deckID, courseID, text in
            let counts = SpokenContent.words(text)
            return counts.isEmpty ? nil : SpokenContent.DeckWords(deckID: deckID, courseID: courseID, counts: counts)
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
