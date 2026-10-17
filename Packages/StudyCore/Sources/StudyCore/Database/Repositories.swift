import Foundation
import SQLiteData

// Small, focused repositories over `RecordStore`. Views should prefer SQLiteData's
// `@FetchAll` / `@FetchOne` for observation; these are for pipelines, agents and tests.

public struct CourseRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func all() async throws -> [Course] {
        try await store.database.read { db in
            try Course.order { ($0.sortOrder, $0.name) }.fetchAll(db)
        }
    }

    public func weeklySlots(courseID: Course.ID) async throws -> [WeeklySlot] {
        try await store.database.read { db in
            try WeeklySlot
                .where { $0.courseID.eq(courseID) }
                .order { ($0.weekday, $0.startMinute) }
                .fetchAll(db)
        }
    }

    /// Sessions starting in `[start, end)`, all courses.
    public func sessions(from start: Date, to end: Date) async throws -> [LectureSession] {
        try await store.database.read { db in
            try LectureSession
                .where { $0.startsAt.gte(start) && $0.startsAt.lt(end) }
                .order(by: \.startsAt)
                .fetchAll(db)
        }
    }
}

public struct LectureRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func lectures(courseID: Course.ID) async throws -> [Lecture] {
        try await store.database.read { db in
            try Lecture
                .where { $0.courseID.eq(courseID) }
                .order { ($0.heldAt, $0.number) }
                .fetchAll(db)
        }
    }

    public func spans(lectureID: Lecture.ID) async throws -> [LectureDeckSpan] {
        try await store.database.read { db in
            try LectureDeckSpan
                .where { $0.lectureID.eq(lectureID) }
                .order { ($0.startTime, $0.firstPage) }
                .fetchAll(db)
        }
    }

    /// Timed spans (aligner output: slide visits and off-slide stretches) of one recording, in time order.
    public func timedSpans(lectureID: Lecture.ID, recordingID: Recording.ID) async throws -> [LectureDeckSpan] {
        try await store.database.read { db in
            try LectureDeckSpan
                .where { $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID) && $0.startTime.isNot(nil) }
                .order(by: \.startTime)
                .fetchAll(db)
        }
    }

    /// Replaces every timed span of one recording of a lecture in one transaction. One aligner run
    /// yields a single consistent timeline that mixes automatic, stamp and manual spans, so all of
    /// them are rewritten together. Coarse spans (no times) are kept.
    @discardableResult
    public func replaceTimedSpans(
        lectureID: Lecture.ID,
        recordingID: Recording.ID,
        with spans: [LectureDeckSpan]
    ) async throws -> [LectureDeckSpan] {
        let stamped = spans.map(store.stamp)
        try await store.database.write { db in
            try LectureDeckSpan
                .where { $0.lectureID.eq(lectureID) && $0.recordingID.eq(recordingID) && $0.startTime.isNot(nil) }
                .delete()
                .execute(db)
            for span in stamped {
                try LectureDeckSpan.upsert { span }.execute(db)
            }
        }
        return stamped
    }

    /// Replaces all spans of `source` for a lecture (e.g. a new aligner run) in one transaction.
    /// Spans from other sources (stamps, manual) are kept.
    @discardableResult
    public func replaceSpans(
        lectureID: Lecture.ID,
        source: SpanSource,
        with spans: [LectureDeckSpan]
    ) async throws -> [LectureDeckSpan] {
        let stamped = spans.map(store.stamp)
        try await store.database.write { db in
            try LectureDeckSpan
                .where { $0.lectureID.eq(lectureID) && $0.source.eq(source) }
                .delete()
                .execute(db)
            for span in stamped {
                try LectureDeckSpan.upsert { span }.execute(db)
            }
        }
        return stamped
    }
}

public struct DeckRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Saves a deck and its pages in one transaction.
    public func save(deck: Deck, pages: [DeckPage]) async throws {
        let deck = store.stamp(deck)
        let pages = pages.map(store.stamp)
        try await store.database.write { db in
            try Deck.upsert { deck }.execute(db)
            for page in pages {
                try DeckPage.upsert { page }.execute(db)
            }
        }
    }

    public func pages(deckID: Deck.ID) async throws -> [DeckPage] {
        try await store.database.read { db in
            try DeckPage.where { $0.deckID.eq(deckID) }.order(by: \.pageNumber).fetchAll(db)
        }
    }

    public func decks(courseID: Course.ID) async throws -> [Deck] {
        try await store.database.read { db in
            try Deck.where { $0.courseID.eq(courseID) }.order(by: \.importedAt).fetchAll(db)
        }
    }
}

public struct RecordingRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func recordings(lectureID: Lecture.ID) async throws -> [Recording] {
        try await store.database.read { db in
            try Recording.where { $0.lectureID.eq(lectureID) }.order(by: \.startedAt).fetchAll(db)
        }
    }

    public func segments(recordingID: Recording.ID) async throws -> [RecordingSegment] {
        try await store.database.read { db in
            try RecordingSegment
                .where { $0.recordingID.eq(recordingID) }
                .order(by: \.sequence)
                .fetchAll(db)
        }
    }

    public func slideEvents(recordingID: Recording.ID) async throws -> [SlideEvent] {
        try await store.database.read { db in
            try SlideEvent
                .where { $0.recordingID.eq(recordingID) }
                .order { ($0.sampleTime, $0.wallClock) }
                .fetchAll(db)
        }
    }
}

public struct TranscriptRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func segments(recordingID: Recording.ID) async throws -> [TranscriptSegment] {
        try await store.database.read { db in
            try TranscriptSegment
                .where { $0.recordingID.eq(recordingID) }
                .order(by: \.startTime)
                .fetchAll(db)
        }
    }

    public func segments(lectureID: Lecture.ID) async throws -> [TranscriptSegment] {
        try await store.database.read { db in
            try TranscriptSegment
                .where { $0.lectureID.eq(lectureID) }
                .order(by: \.startTime)
                .fetchAll(db)
        }
    }

    /// Replaces a recording's transcript (e.g. a fresh transcription run) in one transaction.
    @discardableResult
    public func replaceSegments(
        recordingID: Recording.ID,
        with segments: [TranscriptSegment]
    ) async throws -> [TranscriptSegment] {
        let stamped = segments.map(store.stamp)
        try await store.database.write { db in
            try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.delete().execute(db)
            for segment in stamped {
                try TranscriptSegment.upsert { segment }.execute(db)
            }
        }
        return stamped
    }

    /// Applies a correction: replaces `text`, keeps `originalText`, bumps `revision`.
    @discardableResult
    public func applyCorrection(segmentID: TranscriptSegment.ID, text: String) async throws -> TranscriptSegment? {
        guard var segment = try await store.fetch(TranscriptSegment.self, id: segmentID) else {
            return nil
        }
        segment.text = text
        segment.revision += 1
        return try await store.save(segment)
    }
}

public struct AnnotationRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    public func annotations(lectureID: Lecture.ID, layer: AnnotationLayer? = nil) async throws -> [Annotation] {
        try await store.database.read { db in
            let all = try Annotation
                .where { $0.lectureID.eq(lectureID) }
                .order { ($0.pageNumber, $0.startTime) }
                .fetchAll(db)
            guard let layer else { return all }
            return all.filter { $0.layer == layer }
        }
    }

    public func notes(lectureID: Lecture.ID) async throws -> [Note] {
        try await store.database.read { db in
            try Note
                .where { $0.lectureID.eq(lectureID) }
                .order { ($0.pageNumber, $0.createdAt) }
                .fetchAll(db)
        }
    }
}

public struct TrackedItemRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Open items due at or after `date`, soonest first.
    public func upcoming(from date: Date) async throws -> [TrackedItem] {
        try await store.database.read { db in
            try TrackedItem
                .where { $0.status.eq(TrackedItemStatus.open) && $0.dueAt.gte(Date?.some(date)) }
                .order(by: \.dueAt)
                .fetchAll(db)
        }
    }
}

public struct APICallRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    @discardableResult
    public func log(_ call: APICall) async throws -> APICall {
        try await store.save(call)
    }

    /// Total cost in USD of calls made at or after `date`.
    public func totalCost(since date: Date) async throws -> Double {
        try await store.database.read { db in
            try APICall
                .where { $0.createdAt.gte(date) }
                .select { $0.costUSD.sum() }
                .fetchOne(db)?
                .flatMap { $0 } ?? 0
        }
    }
}

public struct JobRepository: Sendable {
    public let store: RecordStore
    private let now: @Sendable () -> Date

    public init(store: RecordStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    @discardableResult
    public func enqueue(
        _ stage: JobStage,
        lectureID: Lecture.ID? = nil,
        recordingID: Recording.ID? = nil
    ) async throws -> Job {
        try await store.save(Job(stage: stage, lectureID: lectureID, recordingID: recordingID, createdAt: now()))
    }

    /// Oldest queued job, optionally of one stage.
    public func nextQueued(stage: JobStage? = nil) async throws -> Job? {
        try await store.database.read { db in
            let queued = try Job
                .where { $0.state.eq(JobState.queued) }
                .order(by: \.createdAt)
                .fetchAll(db)
            guard let stage else { return queued.first }
            return queued.first { $0.stage == stage }
        }
    }

    /// Jobs that are queued or running.
    public func active() async throws -> [Job] {
        try await store.database.read { db in
            try Job
                .where { $0.state.eq(JobState.queued) || $0.state.eq(JobState.running) }
                .order(by: \.createdAt)
                .fetchAll(db)
        }
    }

    /// Jobs of a lecture, oldest first.
    public func jobs(lectureID: Lecture.ID) async throws -> [Job] {
        try await store.database.read { db in
            try Job.where { $0.lectureID.eq(lectureID) }.order(by: \.createdAt).fetchAll(db)
        }
    }

    /// Attempts after which a job that keeps being interrupted is failed instead of re-queued.
    /// A job that crashes the process (a Core ML trap, an iOS memory kill) would otherwise run
    /// again, and crash again, at every launch.
    public static let maximumInterruptedAttempts = 3

    /// Puts jobs left `running` by a previous process (quit or crash mid-job) back in the queue,
    /// keeping their attempt count. A job already started `maximumAttempts` times is marked
    /// failed instead (Retry queues a fresh one). Call once at launch, before any job runs.
    /// Returns the re-queued jobs.
    @discardableResult
    public func requeueInterrupted(maximumAttempts: Int = JobRepository.maximumInterruptedAttempts) async throws -> [Job] {
        let stamp = now()
        let store = store
        return try await store.database.write { db in
            var requeued: [Job] = []
            for var job in try Job.where({ $0.state.eq(JobState.running) }).fetchAll(db) {
                job.phase = nil
                if job.attempt >= maximumAttempts {
                    job.state = .failed
                    job.error = String(localized: "Interrupted \(job.attempt) times")
                    job.finishedAt = stamp
                } else {
                    job.state = .queued
                    job.progress = 0
                }
                let stamped = store.stamp(job)
                try Job.upsert { stamped }.execute(db)
                if stamped.state == .queued { requeued.append(stamped) }
            }
            return requeued
        }
    }

    /// Marks a queued job running. Returns nil (and changes nothing) when the job is gone or no
    /// longer queued, e.g. cancelled while the runner picked it.
    @discardableResult
    public func start(_ jobID: Job.ID) async throws -> Job? {
        try await update(jobID, from: [.queued]) { job, now in
            job.state = .running
            job.attempt += 1
            job.startedAt = now
            job.progress = 0
            job.phase = nil
            job.error = nil
        }
    }

    /// Records a running job's progress (of `phase`, or of the stage when nil). Ignored once the
    /// job has finished.
    @discardableResult
    public func reportProgress(_ jobID: Job.ID, _ progress: Double, phase: JobPhase? = nil) async throws -> Job? {
        try await update(jobID, from: [.running]) { job, _ in
            job.progress = min(max(progress, 0), 1)
            job.phase = phase
        }
    }

    public enum Outcome: Hashable, Sendable {
        case succeeded
        case failed(String)
        case cancelled
    }

    /// Finishes a job. With `onlyFrom`, only a job currently in one of those states changes;
    /// otherwise nil is returned.
    @discardableResult
    public func finish(_ jobID: Job.ID, _ outcome: Outcome, onlyFrom states: Set<JobState>? = nil) async throws -> Job? {
        try await update(jobID, from: states) { job, now in
            job.finishedAt = now
            job.phase = nil
            switch outcome {
            case .succeeded:
                job.state = .succeeded
                job.progress = 1
                job.error = nil
            case .failed(let message):
                job.state = .failed
                job.error = message
            case .cancelled:
                job.state = .cancelled
            }
        }
    }

    /// Reads, changes and writes a job in one transaction, so concurrent transitions (a cancel
    /// while the runner starts the job, a late progress report) never overwrite each other.
    private func update(
        _ jobID: Job.ID,
        from states: Set<JobState>? = nil,
        _ change: @escaping @Sendable (inout Job, Date) -> Void
    ) async throws -> Job? {
        let stamp = now()
        let store = store
        return try await store.database.write { db in
            guard var job = try Job.find(jobID).fetchOne(db) else { return nil }
            if let states, !states.contains(job.state) { return nil }
            change(&job, stamp)
            let stamped = store.stamp(job)
            try Job.upsert { stamped }.execute(db)
            return stamped
        }
    }
}
