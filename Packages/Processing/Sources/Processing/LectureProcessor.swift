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
    /// The engine returned no text although the recording has speech.
    case nothingTranscribed
    case unknownStage(String)

    public var errorDescription: String? {
        switch self {
        case .missingRecording: String(localized: "The recording is gone.")
        case .missingLecture: String(localized: "The lecture is gone.")
        case .noAudio: String(localized: "The recording has no audio files.")
        case .noTranscript: String(localized: "There is no transcript to align.")
        case .nothingTranscribed: String(localized: "No text came out of the transcription.")
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
    /// Jobs a cancel found already marked running before `run` had their task: `run` cancels
    /// them as soon as `start` returns.
    private var pendingCancels: Set<Job.ID> = []

    /// A transcription that comes back empty although the voice activity detector found at least
    /// this much speech (seconds) fails instead of saving an empty transcript.
    static let minimumSpeechForEmptyTranscript = 30.0

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

    /// Re-queues jobs a previous process left running (failing ones interrupted too often),
    /// queues alignment for lectures whose transcription finished just before a crash, and
    /// transcription for recordings filed without a job (the app quit between importing a
    /// capture and queuing it). Call once at launch, before `wake()`.
    @discardableResult
    public func recover() async throws -> [Job] {
        let requeued = try await jobs.requeueInterrupted()
        let unqueued: [Recording] = try await services.database.read { db in
            try Recording.where { $0.lectureID.isNot(nil) }.fetchAll(db).filter { recording in
                try RecordingSegment.where { $0.recordingID.eq(recording.id) }.fetchCount(db) > 0
                    && Job.where { $0.recordingID.eq(recording.id) }.fetchCount(db) == 0
            }
        }
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
        for recording in unqueued {
            queued.append(try await jobs.enqueue(.transcribe, lectureID: recording.lectureID, recordingID: recording.id))
        }
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

    /// Re-queues the last failed or cancelled stage of a lecture's recording. A later stage whose
    /// recording has no transcript (it failed or came back empty) re-queues transcription instead.
    @discardableResult
    public func retry(lectureID: Lecture.ID) async throws -> Job? {
        guard let last = try await jobs.jobs(lectureID: lectureID).last,
              last.state == .failed || last.state == .cancelled
        else { return nil }
        var stage = last.stage
        if stage != .transcribe, let recordingID = last.recordingID {
            let lines = try await services.database.read { db in
                try TranscriptSegment.where { $0.recordingID.eq(recordingID) }.fetchCount(db)
            }
            if lines == 0 { stage = .transcribe }
        }
        let job = try await jobs.enqueue(stage, lectureID: last.lectureID, recordingID: last.recordingID)
        wake()
        return job
    }

    /// Cancels the running job of a lecture (it is marked cancelled) and drops its queued ones.
    public func cancel(lectureID: Lecture.ID) async throws {
        for job in try await jobs.jobs(lectureID: lectureID) where !job.state.isFinished {
            if let currentJob, currentJob.id == job.id {
                currentJob.task.cancel()
            } else if try await jobs.finish(job.id, .cancelled, onlyFrom: [.queued]) == nil {
                // No longer queued: `run` is starting it right now.
                pendingCancels.insert(job.id)
            }
        }
    }

    private func drain() async {
        var didWork = false
        while needsAnotherPass {
            needsAnotherPass = false
            while !Task.isCancelled, let job = try? await nextJob() {
                guard await run(job) else {
                    // The job could not be marked running (e.g. the disk is full). Picking it
                    // again at once would spin; the next `wake()` tries again.
                    needsAnotherPass = false
                    break
                }
                didWork = true
            }
            // `loop` is still set here, so a `wake()` during `onIdle` only asks for another pass
            // and never starts a second drain that loads the model while it is being unloaded.
            if didWork, !needsAnotherPass {
                didWork = false
                await onIdle()
            }
        }
        loop = nil
    }

    /// The stages this processor runs; queued jobs of other stages belong to other runners.
    public static let stages: Set<JobStage> = [.transcribe, .align]

    /// Oldest queued job of one of `stages`.
    private func nextJob() async throws -> Job? {
        try await jobs.active().first { $0.state == .queued && Self.stages.contains($0.stage) }
    }

    /// Runs one queued job. Returns false when it could not be marked running.
    private func run(_ queued: Job) async -> Bool {
        let started = ContinuousClock.now
        let job: Job
        do {
            // Nil: cancelled (or deleted) since it was picked.
            guard let running = try await jobs.start(queued.id) else { return true }
            job = running
        } catch {
            Log.jobs.error("Could not start job \(queued.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        if pendingCancels.remove(job.id) != nil {
            _ = try? await jobs.finish(job.id, .cancelled)
            return true
        }
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
        return true
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
                case .downloadingModel: report(.downloadingModel, progress.fractionCompleted)
                case .loadingModel: report(.loadingModel, progress.fractionCompleted)
                default: report(nil, progress.fractionCompleted)
                }
            }
        }
        try Task.checkCancellation()
        if transcript.segments.isEmpty, transcript.speechSeconds >= Self.minimumSpeechForEmptyTranscript {
            throw ProcessingError.nothingTranscribed
        }
        if transcript.failedChunks > 0 {
            Log.jobs.error(
                "\(transcript.failedChunks) chunk(s) of \(recording.id, privacy: .public) failed to decode; gaps: \(transcript.gaps.filter { !$0.recovered }.count) unrecovered"
            )
        }

        let rows = transcript.records(recordingID: recording.id, lectureID: lecture?.id).map(store.stamp)
        let finishedJob = finished(job)
        let store = store
        let startedLectureID = lecture?.id
        try await services.database.write { db in
            // Filed (or moved) while it was transcribed: the lines and the alignment follow the
            // lecture the recording is in now.
            let lectureID = try Recording.find(recording.id).fetchOne(db).map(\.lectureID) ?? startedLectureID
            try TranscriptSegment.where { $0.recordingID.eq(recording.id) }.delete().execute(db)
            for var row in rows {
                row.lectureID = lectureID
                try TranscriptSegment.upsert { row }.execute(db)
            }
            var done = finishedJob
            done.lectureID = lectureID
            try Job.upsert { done }.execute(db)
            if let lectureID, try Realigner.deckID(lectureID: lectureID, recordingID: recording.id, in: db) != nil {
                let next = store.stamp(Job(stage: .align, lectureID: lectureID, recordingID: recording.id, createdAt: Date()))
                try Job.upsert { next }.execute(db)
            }
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
        guard let plan = try await Realigner(services: services, aligner: aligner).plan(lecture: lecture, recording: recording) else {
            // Nothing to align against: done.
            try await store.save(finished(job))
            return
        }
        let done = finished(job)
        try await services.database.write { db in
            try Realigner.write(plan, in: db)
            try Job.upsert { done }.execute(db)
        }
        Log.jobs.info(
            "Aligned \(recording.id, privacy: .public): \(plan.spans.count) spans, \(plan.anchorsUsed) of \(plan.anchorsGiven) anchors"
        )
    }

    // MARK: - Helpers

    /// The deck a lecture's recording is aligned against (see `Realigner.deckID`).
    func deckID(lectureID: Lecture.ID, recordingID: Recording.ID) async throws -> Deck.ID? {
        try await Realigner.deckID(lectureID: lectureID, recordingID: recordingID, database: services.database)
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
        _ work: (@escaping @Sendable (JobPhase?, Double) -> Void) async throws -> T
    ) async throws -> T {
        let latest = ProgressBox()
        let jobs = jobs
        let observer = observer
        let interval = progressInterval
        let writer = Task {
            var written = ProgressBox.Value(phase: nil, fraction: 0)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                let value = latest.value
                guard value.phase != written.phase || value.fraction - written.fraction >= 0.001 else { continue }
                written = value
                _ = try? await jobs.reportProgress(job.id, value.fraction, phase: value.phase)
                // Tools follow the stage itself; model preparation only shows in the job row.
                if value.phase == nil { observer(.progress(job.id, value.fraction)) }
            }
        }
        defer { writer.cancel() }
        return try await work { phase, fraction in
            latest.raise(to: fraction, phase: phase)
        }
    }
}

/// The latest progress a job reported, shared between the reporting thread and the writer task.
final class ProgressBox: Sendable {
    struct Value: Equatable, Sendable {
        var phase: JobPhase?
        var fraction: Double
    }

    private let storage = Mutex(Value(phase: nil, fraction: 0))

    var value: Value { storage.withLock { $0 } }

    /// Progress never goes backwards within a phase (repairs report their own sub-phases); a new
    /// phase (model download → model load → transcription) starts its own fraction.
    func raise(to fraction: Double, phase: JobPhase? = nil) {
        storage.withLock { value in
            if value.phase == phase {
                value.fraction = max(value.fraction, fraction)
            } else {
                value = Value(phase: phase, fraction: fraction)
            }
        }
    }
}
