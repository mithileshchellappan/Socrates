import Foundation
import Processing
import StudyCore

extension FilingService {
    /// Moves a filed file to another lecture in one transaction and marks the filing `manual`.
    ///
    /// - A recording or capture moves with its transcript, slide events, notes, annotations and
    ///   jobs; its timed spans move when the new lecture aligns against the same deck, else they
    ///   are dropped and `align` is queued (or `transcribe`, for a recording that had no course).
    ///   A capture's deck link moves along.
    /// - A deck moves its coarse span and `deck.course_id`; the lectures it left and joined are
    ///   re-aligned.
    /// - The lecture the filing created is removed when nothing is left in it.
    ///
    /// `.course` re-runs the matcher inside that course on what the library knows about the
    /// file (slide text, recording start); `.lecture` / `.session` go exactly there.
    @discardableResult
    public func change(_ filingID: Filing.ID, to destination: FilingDestination) async throws -> Filing {
        guard let filing = try await store.fetch(Filing.self, id: filingID) else { throw FilingError.missing }
        let library = try await loadLibrary()
        let target: LectureTarget
        let courseID: Course.ID
        switch destination {
        case .lecture(let id):
            guard let info = library.lecture(id) else { throw FilingError.missing }
            target = .lecture(id)
            courseID = info.lecture.courseID
        case .session(let id):
            guard let session = library.session(id) else { throw FilingError.missing }
            // A lecture held in the session but not linked to it yet is linked by the move.
            target = library.lecture(sessionID: id).flatMap { $0.lecture.lectureSessionID == id ? .lecture($0.lecture.id) : nil }
                ?? .session(id)
            courseID = session.courseID
        case .course(let id):
            let evidence = try await storedEvidence(of: filing)
            guard let choice = FilingMatcher(library: library).decide(evidence, destination: .course(id)).best else {
                throw FilingError.missing
            }
            target = choice.target
            courseID = id
        }
        return try await move(filing, to: target, courseID: courseID)
    }

    /// Moves a filed file into a new lecture of `courseID` (the change sheet's New Lecture).
    @discardableResult
    public func changeToNewLecture(_ filingID: Filing.ID, courseID: Course.ID) async throws -> Filing {
        guard let filing = try await store.fetch(Filing.self, id: filingID) else { throw FilingError.missing }
        return try await move(filing, to: .new, courseID: courseID)
    }

    /// Why a filing moves: the user's choice (it becomes `manual`), or smart import's own second
    /// look (it stays `auto`, with the evidence that moved it).
    enum MoveReason: Sendable {
        case user
        case evidence([FilingSignal], confidence: Double)
        /// The filing advisor decided: it stays `auto`, reviewed (confidence 1), its signal first.
        case advice(FilingSignal)

        var givesWay: Bool {
            switch self {
            case .user: false
            case .evidence, .advice: true
            }
        }
    }

    /// Runs inside a move's transaction with the filing as it was, as it is now, and its lecture.
    typealias MoveHook = @Sendable (Database, _ before: Filing, _ after: Filing, _ lecture: Lecture) throws -> Void

    /// A second look found the filing changed since it read it (the user filed it meanwhile).
    struct Superseded: Error {}

    /// Moves `filing` (as the caller read it). The move itself works on the filing as it is when
    /// the transaction runs: a move by evidence gives way (`Superseded`) to any change made since
    /// it was read, and never touches a filing the user made.
    func move(
        _ filing: Filing, to target: LectureTarget, courseID: Course.ID, reason: MoveReason = .user, hook: MoveHook? = nil
    ) async throws -> Filing {
        guard let course = try await store.fetch(Course.self, id: courseID) else { throw FilingError.missing }
        let now = now()
        let store = store
        let recording: Recording? = try await filing.recordingID.asyncMap { try await store.fetch(Recording.self, id: $0) } ?? nil
        let zone = try await loadLibrary().zone
        let moved = try await services.database.write { db -> Filing in
            guard let current = try Filing.find(filing.id).fetchOne(db) else { throw FilingError.missing }
            if reason.givesWay, current.source == .manual || current.updatedAt != filing.updatedAt || current.lectureID != filing.lectureID {
                throw Superseded()
            }
            // The destination lecture, created when needed.
            var created = false
            var redated: Date?? = nil
            let lecture: Lecture
            switch target {
            case .lecture(let id):
                guard var existing = try Lecture.find(id).fetchOne(db) else { throw FilingError.missing }
                // A lecture without a session that is undated, or dated only by day (a title
                // slide), takes the recording's start, as an import into it does.
                if current.kind != .deck, let started = recording?.startedAt, existing.lectureSessionID == nil, existing.id != current.lectureID {
                    let sameDay = existing.heldAt.map { CalendarDay($0, in: zone) == CalendarDay(started, in: zone) } ?? true
                    if existing.heldAt == nil || (sameDay && LectureImporter.isWholeDay(existing.heldAt, in: zone)) {
                        redated = .some(existing.heldAt)
                        let dated: Date? = started
                        try Lecture.find(id).update { $0.heldAt = dated; $0.updatedAt = now }.execute(db)
                        existing = try Lecture.find(id).fetchOne(db) ?? existing
                    }
                }
                lecture = existing
            case .session(let id):
                guard let session = try LectureSession.find(id).fetchOne(db) else { throw FilingError.missing }
                // Filed to the session, or held in it before it existed (linked now).
                if let existing = try SessionLectures.resolve(sessionID: id, in: db, stamp: now) {
                    lecture = existing
                } else {
                    lecture = store.stamp(Lecture(
                        courseID: session.courseID, lectureSessionID: session.id, number: session.number,
                        heldAt: session.startsAt, language: course.language, createdAt: now
                    ))
                    try Lecture.upsert { lecture }.execute(db)
                    created = true
                }
            case .newLecture(let number, let heldAt, let sessionID):
                lecture = store.stamp(Lecture(
                    courseID: course.id, lectureSessionID: sessionID, number: number,
                    heldAt: heldAt ?? recording?.startedAt, language: course.language, createdAt: now
                ))
                try Lecture.upsert { lecture }.execute(db)
                created = true
            }

            var updated = current
            let oldLectureID = current.lectureID
            if oldLectureID != lecture.id {
                // The lecture it leaves gets back the date this filing gave it.
                if let oldLectureID {
                    try Self.restorePriorHeldAt(&updated, lectureID: oldLectureID, recordingStart: recording?.startedAt, in: db, stamp: now)
                }
                switch current.kind {
                case .deck:
                    if let deckID = current.deckID {
                        let before = try Deck.find(deckID).fetchOne(db)?.courseID
                        try Self.moveDeck(deckID, from: oldLectureID, to: lecture, in: db, store: store, now: now)
                        if updated.priorDeckCourseID == nil, before != lecture.courseID {
                            updated.signals.append(.priorDeckCourse(before))
                        }
                    }
                default:
                    if let recordingID = current.recordingID {
                        try Self.moveRecording(
                            recordingID, kind: current.kind, from: oldLectureID, to: lecture, in: db, store: store, now: now
                        )
                    }
                }
                if current.createdLecture, let oldLectureID, try Self.lectureIsUnused(oldLectureID, except: current.id, in: db) {
                    try Lecture.find(oldLectureID).delete().execute(db)
                }
                updated.createdLecture = created
                if let redated {
                    updated.signals.removeAll { $0.kind == .priorHeldAt }
                    updated.signals.append(.priorHeldAt(redated))
                }
            }
            updated.courseID = lecture.courseID
            updated.lectureID = lecture.id
            updated.lectureSessionID = lecture.lectureSessionID
            switch reason {
            case .user:
                updated.source = .manual
                updated.confidence = 1
                if !updated.signals.contains(where: { $0.kind == .user }) {
                    updated.signals.append(FilingSignal(kind: .user, evidence: course.name, weight: 1))
                }
            case .evidence(let signals, let confidence):
                updated.source = .auto
                updated.confidence = confidence
                updated.signals = signals + updated.signals.filter(\.isPrior)
                updated.candidates = []
            case .advice(let signal):
                updated.source = .auto
                updated.confidence = 1
                updated.signals = [signal] + updated.signals.filter { $0.kind != .advisor && $0.kind != .user }
                updated.candidates = []
            }
            let stamped = store.stamp(updated)
            try Filing.upsert { stamped }.execute(db)
            try hook?(db, current, stamped, lecture)
            return stamped
        }
        Log.importer.info("Moved filing \(filing.id, privacy: .public)")
        await afterImport()
        return moved
    }

    // MARK: - Moving rows

    /// A recording leaves a lecture whose study pass was built on it: the lecture's study units
    /// go, and with them (CASCADE) every row the pass wrote for it (summaries, exam hints, said in
    /// class, topics, further reading, its internal notes). The pass builds the lecture again
    /// from what stays; the recording's new lecture gets its own pass.
    static func dropStudyPass(of lectureID: Lecture.ID, builtOn recordingID: Recording.ID, in db: Database) throws {
        let built = try Annotation
            .where { $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID) && $0.studyUnitID.isNot(nil) }
            .fetchCount(db)
        guard built > 0 else { return }
        try StudyUnit.where { $0.lectureID.eq(lectureID) }.delete().execute(db)
    }

    static func moveRecording(
        _ recordingID: Recording.ID, kind: FilingKind, from oldLectureID: Lecture.ID?, to lecture: Lecture,
        in db: Database, store: RecordStore, now: Date
    ) throws {
        guard var recording = try Recording.find(recordingID).fetchOne(db) else { throw FilingError.missing }
        let newID: Lecture.ID? = lecture.id
        let courseID: Course.ID? = lecture.courseID
        let oldDeck = try oldLectureID.flatMap { try alignmentDeck(lectureID: $0, recordingID: recordingID, in: db) }

        if let oldLectureID { try dropStudyPass(of: oldLectureID, builtOn: recordingID, in: db) }
        recording.lectureID = lecture.id
        recording.courseID = lecture.courseID
        let stampedRecording = store.stamp(recording)
        try Recording.upsert { stampedRecording }.execute(db)
        try TranscriptSegment.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        try SlideEvent.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        try Note.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = newID; $0.courseID = courseID; $0.updatedAt = now }.execute(db)
        // The student's own rows move; the study pass's stay with their lecture's units.
        try Annotation.where { $0.recordingID.eq(recordingID) && $0.studyUnitID.is(nil) }
            .update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)
        try Job.where { $0.recordingID.eq(recordingID) }
            .update { $0.lectureID = newID; $0.updatedAt = now }.execute(db)

        // A capture's slides come along: its deck link moves with the stamps.
        if kind == .capture {
            let decks = try Set(SlideEvent.where { $0.recordingID.eq(recordingID) }.fetchAll(db).compactMap(\.deckID))
            for deckID in decks {
                let old = try oldLectureID.flatMap { id in
                    try LectureDeckSpan.where { $0.lectureID.eq(id) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }.fetchOne(db)
                }
                let present = try LectureDeckSpan
                    .where { $0.lectureID.eq(lecture.id) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
                    .fetchCount(db)
                if present == 0, let pageCount = try Deck.find(deckID).fetchOne(db)?.pageCount {
                    let span = store.stamp(LectureDeckSpan(
                        lectureID: lecture.id, deckID: deckID, firstPage: old?.firstPage ?? 1, lastPage: old?.lastPage ?? pageCount,
                        source: old?.source ?? .manual
                    ))
                    try LectureDeckSpan.upsert { span }.execute(db)
                }
                if let oldLectureID, let old, try !deckLinkIsShared(deckID, lectureID: oldLectureID, recordingID: recordingID, in: db) {
                    try LectureDeckSpan.find(old.id).delete().execute(db)
                }
            }
        }

        let newDeck = try alignmentDeck(lectureID: lecture.id, recordingID: recordingID, in: db)
        if newDeck != nil, newDeck == oldDeck {
            try LectureDeckSpan.where { $0.recordingID.eq(recordingID) }
                .update { $0.lectureID = lecture.id; $0.updatedAt = now }.execute(db)
        } else {
            try LectureDeckSpan.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
        }
        let lines = try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.fetchCount(db)
        let pending = try Job
            .where { $0.recordingID.eq(recordingID) && ($0.state.eq(JobState.queued) || $0.state.eq(JobState.running)) }
            .fetchCount(db)
        if lines == 0, pending == 0 {
            // Never transcribed (it had no course): start now that it has one.
            let job = store.stamp(Job(stage: .transcribe, lectureID: lecture.id, recordingID: recordingID, createdAt: now))
            try Job.upsert { job }.execute(db)
        } else if lines > 0, newDeck != nil, newDeck != oldDeck, pending == 0 {
            let job = store.stamp(Job(stage: .align, lectureID: lecture.id, recordingID: recordingID, createdAt: now))
            try Job.upsert { job }.execute(db)
        }
    }

    /// mr: moves only this filing's lecture link (`oldLectureID` → `lecture`); other lectures that
    /// use the deck keep their ranges. A deck other lectures use never changes course
    /// (`FilingError.sharedDeck`).
    static func moveDeck(_ deckID: Deck.ID, from oldLectureID: Lecture.ID?, to lecture: Lecture, in db: Database, store: RecordStore, now: Date) throws {
        guard var deck = try Deck.find(deckID).fetchOne(db) else { throw FilingError.missing }
        if deck.courseID != lecture.courseID {
            let others = try LectureSlides.lectures(usingDeck: deckID, in: db)
                .filter { $0.lectureID != oldLectureID && $0.lectureID != lecture.id }
            if !others.isEmpty { throw FilingError.sharedDeck }
        }
        let old = try oldLectureID.flatMap { id in
            try LectureDeckSpan.where { $0.lectureID.eq(id) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }.fetchOne(db)
        }
        if let oldLectureID {
            try unlinkDeck(deckID, from: oldLectureID, in: db, store: store, now: now)
        }
        deck.courseID = lecture.courseID
        let stampedDeck = store.stamp(deck)
        try Deck.upsert { stampedDeck }.execute(db)
        let present = try LectureDeckSpan
            .where { $0.lectureID.eq(lecture.id) && $0.deckID.eq(deckID) && $0.startTime.is(nil) }
            .fetchOne(db)
        let span = store.stamp(LectureDeckSpan(
            id: present?.id ?? old?.id ?? UUID(), lectureID: lecture.id, deckID: deckID,
            firstPage: old?.firstPage ?? 1, lastPage: old?.lastPage ?? deck.pageCount, source: old?.source ?? .manual
        ))
        try LectureDeckSpan.upsert { span }.execute(db)
        for job in try LectureImporter.alignmentJobs(lectureID: lecture.id, in: db, now: now) {
            let stamped = store.stamp(job)
            try Job.upsert { stamped }.execute(db)
        }
    }

    /// The deck a lecture's recording aligns against (`Realigner.deckID`, inside a transaction).
    static func alignmentDeck(lectureID: Lecture.ID, recordingID: Recording.ID, in db: Database) throws -> Deck.ID? {
        if let coarse = try LectureDeckSpan
            .where({ $0.lectureID.eq(lectureID) && $0.startTime.is(nil) })
            .order(by: \.updatedAt)
            .fetchAll(db)
            .last {
            return coarse.deckID
        }
        return try SlideEvent.where { $0.recordingID.eq(recordingID) && $0.deckID.isNot(nil) }.fetchOne(db)?.deckID
    }

    // MARK: - Evidence from the library

    /// What the library knows about a filed file (for re-matching inside another course without
    /// the original file): the deck's stored slide text, the recording's start and length.
    func storedEvidence(of filing: Filing) async throws -> FileEvidence {
        let number = Numbering.fileNumber(filing.fileName)
        var evidence = FileEvidence(
            url: URL(filePath: filing.fileName), fileName: filing.fileName, kind: filing.kind,
            fileNumber: number?.number, fileNumberEvidence: number?.evidence
        )
        if filing.kind == .deck, let deckID = filing.deckID, let deck = try await store.fetch(Deck.self, id: deckID) {
            let numbers = DeckProbe.sample(pageCount: deck.pageCount, size: DeckProbe.sampleSize).map { $0 + 1 }
            let pages = try await services.database.read { db in
                try DeckPage.where { $0.deckID.eq(deckID) && $0.pageNumber.in(numbers) }.order(by: \.pageNumber).fetchAll(db)
            }
            evidence.deck = FileEvidence.deckEvidence(DeckProbe(
                pageCount: deck.pageCount, pdfTitle: nil, pdfAuthor: nil,
                pages: pages.map { DeckProbe.Page(number: $0.pageNumber, text: $0.text) }
            ))
        } else if let recordingID = filing.recordingID, let recording = try await store.fetch(Recording.self, id: recordingID) {
            evidence.recording = FileEvidence.RecordingEvidence(
                startedAt: recording.startedAt, startSource: .metadata, duration: recording.duration
            )
        }
        return evidence
    }
}

extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        guard let self else { return nil }
        return try await transform(self)
    }
}
