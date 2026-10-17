import Alignment
import Foundation
import StudyCore
import Synchronization
import Transcription

public enum ProcessingError: Error, Equatable, Sendable, LocalizedError {
    case missingRecording
    case missingLecture
    case noAudio
    case noTranscript
    case unknownStage(String)

    public var errorDescription: String? {
        switch self {
        case .missingRecording: String(localized: "The recording is gone.")
        case .missingLecture: String(localized: "The lecture is gone.")
        case .noAudio: String(localized: "The recording has no audio files.")
        case .noTranscript: String(localized: "There is no transcript to align.")
        case .unknownStage(let stage): String(localized: "Unknown processing step “\(stage)”.")
        }
    }
}

/// What the processor is doing, for command-line tools and logs. The app observes `job` rows
/// in the database instead.
public enum ProcessingEvent: Sendable {
    case started(Job)
    case progress(Job.ID, Double)
    case finished(Job, seconds: Double)
}

/// Runs queued lecture jobs one at a time: transcribe, then align.
///
/// State lives in `job` rows, so processing survives quits and crashes: `recover()` puts jobs
/// that were running back in the queue (a transcription restarts from the beginning; finished
/// stages are never redone). Progress is written to the job row about twice a second.
///
/// - transcribe: the recording's segment files → `TranscriptionEngine` (course languages,
///   glossary) → `transcript_segment` rows. On success, in the same transaction, the align job
///   is queued when the lecture has slides.
/// - align: deck pages + transcript + stamps/manual anchors → `SlideAligner` → timed
///   `lecture_deck_span` rows (OFF spans without pages), replacing the recording's earlier ones.
public actor LectureProcessor {
    public let services: StudyServices
    public let engine: any TranscriptionEngine
    public let aligner: SlideAligner
    private let onIdle: @Sendable () async -> Void
    private let observer: @Sendable (ProcessingEvent) -> Void
    private let progressInterval: Duration

    private var loop: Task<Void, Never>?
    private var needsAnotherPass = false
    private var currentJob: (id: Job.ID, task: Task<Void, any Error>)?

    /// - Parameters:
    ///   - onIdle: called when the queue runs dry after doing work, e.g. to unload the model.
    ///   - observer: progress callback for tools; called on the processor's executor.
    public init(
        services: StudyServices,
        engine: any TranscriptionEngine,
        aligner: SlideAligner = SlideAligner(),
        progressInterval: Duration = .milliseconds(500),
        onIdle: @escaping @Sendable () async -> Void = {},
        observer: @escaping @Sendable (ProcessingEvent) -> Void = { _ in }
    ) {
        self.services = services
        self.engine = engine
        self.aligner = aligner
        self.progressInterval = progressInterval
        self.onIdle = onIdle
        self.observer = observer
    }

    private var store: RecordStore { services.records }
    private var jobs: JobRepository { JobRepository(store: store) }

    // MARK: - Running

    /// Re-queues jobs a previous process left running, and queues alignment for lectures whose
    /// transcription finished just before a crash. Call once at launch, before `wake()`.
    @discardableResult
    public func recover() async throws -> [Job] {
        let requeued = try await jobs.requeueInterrupted()
        let orphans: [Job] = try await services.database.read { db in
            let transcribed = try Job
                .where { $0.stage.eq(JobStage.transcribe) && $0.state.eq(JobState.succeeded) }
                .fetchAll(db)
            return try transcribed.filter { job in
                guard let recordingID = job.recordingID else { return false }
                let later = try Job
                    .where { $0.recordingID.eq(recordingID) && $0.createdAt.gt(job.createdAt) }
                    .fetchCount(db)
                return later == 0
            }
        }
        var queued: [Job] = []
        for job in orphans {
            guard let lectureID = job.lectureID, let recordingID = job.recordingID,
                  try await deckID(lectureID: lectureID, recordingID: recordingID) != nil
            else { continue }
            queued.append(try await jobs.enqueue(.align, lectureID: lectureID, recordingID: recordingID))
        }
        if !requeued.isEmpty || !queued.isEmpty {
            Log.jobs.info("Recovered \(requeued.count) interrupted and \(queued.count) follow-up jobs")
        }
        return requeued + queued
    }

    /// Starts working through the queue in the background if it is not already.
    public func wake() {
        needsAnotherPass = true
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Works through the queue and returns once it is empty.
    public func runUntilIdle() async {
        wake()
        await loop?.value
    }

    /// Re-queues the last failed or cancelled stage of a lecture's recording.
    @discardableResult
    public func retry(lectureID: Lecture.ID) async throws -> Job? {
        guard let last = try await jobs.jobs(lectureID: lectureID).last,
              last.state == .failed || last.state == .cancelled
        else { return nil }
        let job = try await jobs.enqueue(last.stage, lectureID: last.lectureID, recordingID: last.recordingID)
        wake()
        return job
    }

    /// Cancels the running job of a lecture (it is marked cancelled) and drops its queued ones.
    public func cancel(lectureID: Lecture.ID) async throws {
        for job in try await jobs.jobs(lectureID: lectureID) where job.state == .queued {
            try await jobs.finish(job.id, .cancelled)
        }
        if let currentJob, try await store.fetch(Job.self, id: currentJob.id)?.lectureID == lectureID {
            currentJob.task.cancel()
        }
    }

    private func drain() async {
        var didWork = false
        while needsAnotherPass {
            needsAnotherPass = false
            while let job = try? await nextJob(), !Task.isCancelled {
                await run(job)
                didWork = true
            }
        }
        loop = nil
        if didWork { await onIdle() }
    }

    /// The stages this processor runs; queued jobs of other stages belong to other runners.
    public static let stages: Set<JobStage> = [.transcribe, .align]

    /// Oldest queued job of one of `stages`.
    private func nextJob() async throws -> Job? {
        try await jobs.active().first { $0.state == .queued && Self.stages.contains($0.stage) }
    }

    private func run(_ queued: Job) async {
        let started = ContinuousClock.now
        guard let job = try? await jobs.start(queued.id) else { return }
        observer(.started(job))
        Log.jobs.info("Job \(job.stage.rawValue, privacy: .public) \(job.id, privacy: .public) attempt \(job.attempt)")

        let task = Task { [self] in
            switch job.stage {
            case .transcribe: try await transcribe(job)
            case .align: try await align(job)
            default: throw ProcessingError.unknownStage(job.stage.rawValue)
            }
        }
        currentJob = (job.id, task)
        let outcome: JobRepository.Outcome
        do {
            try await task.value
            outcome = .succeeded
        } catch is CancellationError {
            outcome = .cancelled
        } catch {
            Log.jobs.error("Job \(job.stage.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            outcome = .failed(error.localizedDescription)
        }
        currentJob = nil
        // Transcribe and align finish their job inside their result transaction on success.
        if outcome != .succeeded {
            _ = try? await jobs.finish(job.id, outcome)
        }
        let elapsed = (ContinuousClock.now - started).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        if let finished = try? await store.fetch(Job.self, id: job.id) {
            observer(.finished(finished, seconds: seconds))
        }
    }

    // MARK: - Transcribe

    private func transcribe(_ job: Job) async throws {
        guard let recordingID = job.recordingID,
              let recording = try await store.fetch(Recording.self, id: recordingID)
        else { throw ProcessingError.missingRecording }
        var lecture: Lecture?
        if let lectureID = job.lectureID ?? recording.lectureID {
            lecture = try await store.fetch(Lecture.self, id: lectureID)
        }
        var course: Course?
        if let courseID = lecture?.courseID ?? recording.courseID {
            course = try await store.fetch(Course.self, id: courseID)
        }

        let segments = try await RecordingRepository(store: store).segments(recordingID: recording.id)
        let blobs = services.blobs
        let audio = TranscriptionAudio(recording: recording, segments: segments) { segment in
            segment.blobPath.isEmpty ? nil : blobs.url(forRelativePath: segment.blobPath)
        }
        guard !audio.parts.isEmpty else { throw ProcessingError.noAudio }
        let options = course.map { TranscriptionOptions(course: $0) } ?? TranscriptionOptions()

        let transcript = try await withProgress(job) { report in
            try await engine.transcribe(audio, options: options) { progress in
                switch progress.phase {
                case .downloadingModel, .loadingModel: break
                default: report(progress.fractionCompleted)
                }
            }
        }
        try Task.checkCancellation()

        let rows = transcript.records(recordingID: recording.id, lectureID: lecture?.id).map(store.stamp)
        var follow: Job?
        if let lecture, try await deckID(lectureID: lecture.id, recordingID: recording.id) != nil {
            follow = store.stamp(Job(stage: .align, lectureID: lecture.id, recordingID: recording.id, createdAt: Date()))
        }
        let done = finished(job)
        let next = follow
        try await services.database.write { db in
            try TranscriptSegment.where { $0.recordingID.eq(recording.id) }.delete().execute(db)
            for row in rows { try TranscriptSegment.upsert { row }.execute(db) }
            try Job.upsert { done }.execute(db)
            if let next { try Job.upsert { next }.execute(db) }
        }
        let languages = transcript.languageSeconds.map { "\($0.language) \(Int($0.seconds)) s" }.joined(separator: ", ")
        Log.jobs.info(
            "Transcribed \(recording.id, privacy: .public): \(rows.count) segments (\(languages, privacy: .public)) in \(transcript.wallTime, privacy: .public) s"
        )
    }

    // MARK: - Align

    private func align(_ job: Job) async throws {
        guard let recordingID = job.recordingID,
              let recording = try await store.fetch(Recording.self, id: recordingID)
        else { throw ProcessingError.missingRecording }
        guard let lectureID = job.lectureID ?? recording.lectureID,
              let lecture = try await store.fetch(Lecture.self, id: lectureID)
        else { throw ProcessingError.missingLecture }
        guard let deckID = try await deckID(lectureID: lecture.id, recordingID: recording.id) else {
            // Nothing to align against: done.
            try await store.save(finished(job))
            return
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
        let duration = recording.duration > 0 ? recording.duration : nil
        let result = aligner.align(
            slides: slides,
            transcript: AlignmentMapping.transcript(segments),
            anchors: anchors,
            duration: duration,
            glossary: Glossary(text: course?.glossary ?? "")
        )
        let spans = AlignmentMapping.spans(result, lectureID: lecture.id, deckID: deckID, recordingID: recording.id)
            .map(store.stamp)
        let done = finished(job)
        try await services.database.write { db in
            try LectureDeckSpan
                .where { $0.lectureID.eq(lecture.id) && $0.recordingID.eq(recording.id) && $0.startTime.isNot(nil) }
                .delete()
                .execute(db)
            for span in spans { try LectureDeckSpan.upsert { span }.execute(db) }
            try Job.upsert { done }.execute(db)
        }
        Log.jobs.info(
            "Aligned \(recording.id, privacy: .public): \(spans.count) spans, \(result.anchors.count) of \(anchors.count) anchors"
        )
    }

    // MARK: - Helpers

    /// The deck a lecture's recording is aligned against: the lecture's coarse span, else the
    /// deck its slide stamps were taken on.
    func deckID(lectureID: Lecture.ID, recordingID: Recording.ID) async throws -> Deck.ID? {
        try await services.database.read { db in
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

    private func finished(_ job: Job) -> Job {
        var job = job
        job.state = .succeeded
        job.progress = 1
        job.error = nil
        job.finishedAt = Date()
        return store.stamp(job)
    }

    /// Runs `work`, persisting the progress it reports at most every `progressInterval`.
    private func withProgress<T: Sendable>(
        _ job: Job,
        _ work: (@escaping @Sendable (Double) -> Void) async throws -> T
    ) async throws -> T {
        let latest = ProgressBox()
        let jobs = jobs
        let observer = observer
        let interval = progressInterval
        let writer = Task {
            var written = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let value = latest.value
                guard value - written >= 0.001 else { continue }
                written = value
                _ = try? await jobs.reportProgress(job.id, value)
                observer(.progress(job.id, value))
            }
        }
        defer { writer.cancel() }
        return try await work { value in
            latest.raise(to: value)
        }
    }
}

/// The latest progress a job reported, shared between the reporting thread and the writer task.
final class ProgressBox: Sendable {
    private let storage = Mutex<Double>(0)

    var value: Double { storage.withLock { $0 } }

    /// Progress never goes backwards (model loading and repairs report their own phases).
    func raise(to value: Double) {
        storage.withLock { $0 = max($0, value) }
    }
}
