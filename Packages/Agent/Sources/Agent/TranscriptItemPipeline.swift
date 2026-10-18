import ClaudeKit
import Deadlines
import Foundation
import GRDB
import StudyCore

/// Reads deadlines and announcements said in class out of lecture transcripts (PRD #32) into the
/// deadline memory, as `transcript` sources at the moment they were said.
///
/// - **Queue**: a recording with transcript lines is pending when its `transcript_extraction` row
///   is missing or older than its oldest line (a replaced transcript is read again; corrections,
///   which touch only some lines, are not) and no job of
///   it is still queued or running. Calls run only with an available client (M3.5: Claude Code) and while the
///   daily guard allows; otherwise rows stay `pending` (no call, nothing on screen). At most one
///   call at a time. Service trouble (no key, rate limits, outages) does not count an attempt;
///   other failures do (three, then `failed` until the transcript changes).
/// - **Prefilter**: only windows of ±3 lines around cue lines are sent; no cue → `skipped`, no call.
/// - **Validation in code**: the quote must be in the window lines from the named line on (it may
///   run across lines; the original span is stored, 8–300 characters); its time is the first
///   word's start, else the line's (`Deadlines.TranscriptQuote`); `DateMentions` over the quote, relative to the class's day,
///   decides whether the date is verified; the lecture's course is the item's.
public actor TranscriptItemPipeline {
    /// What one pass did.
    public struct Report: Sendable, Equatable {
        public var skipped = 0
        public var done = 0
        public var failed = 0
        public var calls = 0
        public var itemsCreated = 0
        public var sourcesAdded = 0
        public var rejected = 0
        /// Recordings left pending (no key, guard, service trouble, still processing).
        public var waiting = 0

        public init() {}
    }

    /// Transcripts of classes older than this are not read (what they announced is past).
    static let windowDays = 30

    let services: StudyServices
    let client: ClaudeClient?
    let memory: DeadlineMemory
    let now: @Sendable () -> Date
    let costGuard: AgentCostGuard
    let timeZone = AgentDates.timeZone
    let debounce: Duration

    private var observation: AnyDatabaseCancellable?
    private var loop: Task<Void, Never>?
    private var running = false
    private var again = false
    /// A pass at the end of the usage pause.
    private var pauseWake: Task<Void, Never>?

    public init(
        services: StudyServices,
        client: ClaudeClient?,
        memory: DeadlineMemory,
        now: @escaping @Sendable () -> Date = { Date() },
        dailyLimitUSD: Double = AgentCostGuard.defaultDailyLimit,
        debounce: Duration = .seconds(2)
    ) {
        self.services = services
        self.client = client
        self.memory = memory
        self.now = now
        self.debounce = debounce
        costGuard = AgentCostGuard(database: services.database, dailyLimitUSD: dailyLimitUSD, now: now)
    }

    // MARK: - Entry points

    /// Starts following transcripts, their extraction rows and jobs; a first pass follows shortly
    /// (in the background, after the debounce).
    public func start() async {
        guard loop == nil else { return }
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        // New or replaced lines, extraction rows, and jobs that finish (not their progress).
        let regions: [any DatabaseRegionConvertible] = [
            SQLRequest<Row>(sql: "SELECT recording_id, updated_at FROM transcript_segment"),
            SQLRequest<Row>(sql: "SELECT recording_id, state, source_updated_at FROM transcript_extraction"),
            SQLRequest<Row>(sql: "SELECT recording_id, state FROM job"),
        ]
        observation = DatabaseRegionObservation(tracking: regions)
            .start(
                in: services.database,
                onError: { error in
                    AgentModule.log.error("Transcript observation failed: \(String(describing: error), privacy: .public)")
                },
                onChange: { _ in continuation.yield() }
            )
        let debounce = debounce
        loop = Task { [weak self] in
            for await _ in stream {
                // A transcription writes many lines: wait for a quiet moment.
                do { try await Task.sleep(for: debounce) } catch { return }
                await self?.wake()
            }
        }
        // The first pass runs in the background too: launch never waits for the model.
        continuation.yield()
    }

    /// Stops following (the app quits).
    public func stop() {
        observation?.cancel()
        observation = nil
        loop?.cancel()
        loop = nil
        pauseWake?.cancel()
        pauseWake = nil
    }

    /// A transcription finished, or Claude Code became available: read what waits. Runs a pass (model
    /// calls included) before it returns, or returns at once when a pass is running (it then runs
    /// once more); call it from a task.
    public func wake() async {
        if running {
            again = true
            return
        }
        running = true
        repeat {
            again = false
            do {
                _ = try await pass()
            } catch {
                AgentModule.log.error("Transcript extraction pass failed: \(String(describing: error), privacy: .public)")
            }
        } while again
        running = false
    }

    // MARK: - Pass

    struct Pending: Sendable {
        var recordingID: Recording.ID
        /// The newest line's `updated_at`: what the row's `source_updated_at` records.
        var newest: Date
        var row: TranscriptExtraction?
        /// The transcript was replaced since the row was written (attempts start again).
        var changed: Bool
    }

    /// One pass over every pending recording, one call at a time.
    @discardableResult
    func pass() async throws -> Report {
        var report = Report()
        let pending = try await pendingRecordings()
        var serviceTrouble = false
        for item in pending {
            guard let source = try await load(item.recordingID) else { continue }
            if source.day.days(to: CalendarDay(now(), in: timeZone)) > Self.windowDays {
                try await setRow(item, state: .skipped)
                report.skipped += 1
                continue
            }
            let windows = source.lines.windows(reference: source.reference)
            guard !windows.isEmpty else {
                try await setRow(item, state: .skipped)
                report.skipped += 1
                continue
            }
            guard !serviceTrouble, let client, await runsNow(client), await costGuard.allowsCalls() else {
                try await keepPending(item)
                report.waiting += 1
                continue
            }
            report.calls += 1
            switch await extract(item, source: source, windows: windows, client: client) {
            case .done(let applied):
                report.done += 1
                report.itemsCreated += applied.itemsCreated
                report.sourcesAdded += applied.sourcesAdded
                report.rejected += applied.rejected
            case .failed:
                report.failed += 1
            case .waiting:
                report.waiting += 1
                serviceTrouble = true
            }
        }
        // A call of this pass may have hit the usage limit.
        if serviceTrouble, let client { _ = await runsNow(client) }
        return report
    }

    /// Recordings whose transcript was not read since it was last replaced.
    ///
    /// Stale means the *oldest* line's `updated_at` is newer than `source_updated_at`: a
    /// transcription replaces every line, while a correction (M4's study pass patches, Revert
    /// Correction) touches only some, so corrections never trigger a deadline re-read.
    func pendingRecordings() async throws -> [Pending] {
        try await services.database.read { db in
            let stamps = try TranscriptSegment
                .group(by: \.recordingID)
                .select { ($0.recordingID, $0.updatedAt.min(), $0.updatedAt.max()) }
                .fetchAll(db)
            let rows = Dictionary(
                try TranscriptExtraction.all.fetchAll(db).map { ($0.recordingID, $0) }, uniquingKeysWith: { first, _ in first }
            )
            let busyStates: [JobState] = [.queued, .running]
            let busy = Set(try Job.where { $0.recordingID.isNot(nil) && $0.state.in(busyStates) }.select(\.recordingID).fetchAll(db).compactMap { $0 })
            return stamps.compactMap { recordingID, oldest, latest -> Pending? in
                guard let oldest, let latest, !busy.contains(recordingID) else { return nil }
                let row = rows[recordingID]
                let changed = row?.sourceUpdatedAt.map { $0 < oldest } ?? true
                guard changed || row?.state == .pending else { return nil }
                return Pending(recordingID: recordingID, newest: latest, row: row, changed: changed)
            }
        }
    }

    // MARK: - Sources

    struct Source: Sendable {
        var recording: Recording
        var lecture: Lecture?
        var course: Course?
        var lines: TranscriptLines
        /// When the class was held (the lecture's day, else the recording's start).
        var reference: Date
        var day: CalendarDay
    }

    func load(_ recordingID: Recording.ID) async throws -> Source? {
        let timeZone = timeZone
        return try await services.database.read { db in
            guard let recording = try Recording.find(recordingID).fetchOne(db) else { return nil }
            let lecture = try recording.lectureID.flatMap { try Lecture.find($0).fetchOne(db) }
            let courseID = lecture?.courseID ?? recording.courseID
            let course = try courseID.flatMap { try Course.find($0).fetchOne(db) }
            let segments = try TranscriptSegment
                .where { $0.recordingID.eq(recordingID) }
                .order(by: \.startTime)
                .fetchAll(db)
            let reference = lecture?.heldAt ?? recording.startedAt
            return Source(
                recording: recording, lecture: lecture, course: course, lines: TranscriptLines(segments), reference: reference,
                day: CalendarDay(reference, in: timeZone)
            )
        }
    }

    // MARK: - Calls

    enum Outcome: Sendable {
        case done(Applied)
        case failed
        case waiting
    }

    struct Applied: Sendable, Equatable {
        var itemsCreated = 0
        var sourcesAdded = 0
        var rejected = 0
    }

    func extract(_ item: Pending, source: Source, windows: [ClosedRange<Int>], client: ClaudeClient) async -> Outcome {
        var sent: [ClosedRange<Int>] = []
        var count = 0
        for window in windows where count + window.count <= TranscriptPrompt.maximumLines {
            sent.append(window)
            count += window.count
        }
        let lectureName = source.lecture.map { lecture in
            lecture.number.map { "Lecture \($0): \(lecture.title)" } ?? lecture.title
        } ?? "Recording"
        let courseName = source.course.map { CourseTokens.baseToken($0) + " (" + $0.name + ")" } ?? ""
        let text = TranscriptPrompt.text(lines: source.lines.lines, windows: sent, lecture: lectureName, course: courseName, day: source.day)
        let purpose = AgentModule.transcriptPurpose
        var apiCallID: APICall.ID?
        do {
            let message = try await client.streamMessage(
                TranscriptPrompt.request(text),
                context: CallContext(purpose: purpose, lectureID: source.lecture?.id, priority: .background)
            )
            apiCallID = try? await APICallRepository(store: services.records).call(requestID: message.requestID, purpose: purpose)
            let answer = try message.decodeJSON(TranscriptPrompt.Answer.self)
            let applied = try await apply(answer, to: item, source: source, windows: sent, apiCallID: apiCallID)
            return .done(applied)
        } catch let error as ClaudeError where Self.isServiceTrouble(error) {
            AgentModule.log.notice("Transcript extraction waits: \(error.description, privacy: .public)")
            try? await keepPending(item)
            return .waiting
        } catch is CancellationError {
            try? await keepPending(item)
            return .waiting
        } catch {
            AgentModule.log.error("Transcript extraction failed: \(String(describing: error), privacy: .public)")
            try? await countFailure(item, error: String(describing: error), apiCallID: apiCallID)
            return .failed
        }
    }

    static func isServiceTrouble(_ error: ClaudeError) -> Bool {
        error.isServiceTrouble
    }

    /// Calls can run now: a usage pause counts as no client (its calls would fail at once), and a
    /// pass follows when it ends.
    func runsNow(_ client: ClaudeClient) async -> Bool {
        let availability = await client.availability()
        if let until = availability.pausedUntil {
            if pauseWake == nil {
                pauseWake = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(until.timeIntervalSinceNow + 1)) } catch { return }
                    await self?.pauseEnded()
                }
            }
            return false
        }
        return availability.isReady
    }

    private func pauseEnded() async {
        pauseWake = nil
        await wake()
    }

    // MARK: - Validation

    /// A validated finding before it is written.
    func findings(from answer: TranscriptPrompt.Answer, source: Source, windows: [ClosedRange<Int>], apiCallID: APICall.ID?) -> ([ItemFinding], Int) {
        var findings: [ItemFinding] = []
        var rejected = 0
        let quoteLines = source.lines.lines.map { TranscriptQuote.Line(id: $0.id, text: $0.text, start: $0.start, words: $0.words) }
        for item in answer.items {
            let kind = TrackedItemKind(rawValue: item.kind.trimmingCharacters(in: .whitespaces).lowercased())
            let confidence = min(max(item.confidence.isFinite ? item.confidence : 0, 0), 1)
            let title = String(item.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            guard TranscriptPrompt.kinds.contains(kind.rawValue), confidence >= TranscriptPrompt.minimumConfidence, !title.isEmpty,
                  let found = TranscriptQuote.locate(item.quote, line: item.line, lines: quoteLines, windows: windows)
            else {
                rejected += 1
                continue
            }
            let mentions = DateMentions.parse(found.quote, reference: source.reference, timeZone: timeZone)
            var draft = DeadlineDraft(
                kind: kind, title: title, details: DeadlineTools.Tools.details(item.details), courseID: source.course?.id,
                relevance: item.relevance.flatMap { ["exam_admission", "bonus"].contains($0) ? ItemRelevance(rawValue: $0) : nil },
                room: item.room?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            var verified = false
            if let due = AgentDates.parse(item.due, allDay: item.allDay) {
                let checked = AgentDates.verify(due, in: found.quote, reference: source.reference)
                draft.dueAt = checked.date
                draft.isAllDay = checked.allDay
                verified = checked.verified
            }
            findings.append(ItemFinding(
                draft: draft,
                source: .transcript(lectureID: source.lecture?.id, recordingID: source.recording.id, time: found.time),
                quote: found.quote, confidence: confidence, dateVerified: verified, trusted: true, createdBy: .agent,
                apiCallID: apiCallID, mentions: mentions
            ))
        }
        return (findings, rejected)
    }

    // MARK: - Writing

    /// Validates `answer` and writes its items, their sources and the recording's `done` row in one
    /// transaction.
    func apply(_ answer: TranscriptPrompt.Answer, to item: Pending, source: Source, windows: [ClosedRange<Int>], apiCallID: APICall.ID?) async throws -> Applied {
        let (findings, rejected) = findings(from: answer, source: source, windows: windows, apiCallID: apiCallID)
        let store = services.records
        let date = now()
        var applied = try await services.database.write { db -> Applied in
            var applied = Applied()
            for finding in findings {
                let result = try DeadlineMemory.record(finding, in: db, store: store, now: date)
                applied.itemsCreated += result.created ? 1 : 0
                applied.sourcesAdded += result.source == nil ? 0 : 1
            }
            var row = item.row ?? TranscriptExtraction(recordingID: item.recordingID, createdAt: date)
            row.state = .done
            row.sourceUpdatedAt = item.newest
            row.extractedAt = date
            row.error = nil
            row.apiCallID = apiCallID
            if item.changed { row.attempts = 0 }
            let stamped = store.stamp(row)
            try TranscriptExtraction.upsert { stamped }.execute(db)
            return applied
        }
        applied.rejected = rejected
        if !findings.isEmpty { await memory.didChange() }
        return applied
    }

    /// Done without a call (nothing to read): `skipped`.
    func setRow(_ item: Pending, state: ExtractionState) async throws {
        var row = item.row ?? TranscriptExtraction(recordingID: item.recordingID, createdAt: now())
        row.state = state
        row.sourceUpdatedAt = item.newest
        row.extractedAt = now()
        if item.changed { row.attempts = 0 }
        try await services.records.save(row)
    }

    /// Waits for a key, the guard or the service: a `pending` row (written once). The row keeps the
    /// newest line it waits for, so a later change of the transcript starts the attempts again.
    func keepPending(_ item: Pending) async throws {
        if let row = item.row, row.state == .pending, !item.changed { return }
        var row = item.row ?? TranscriptExtraction(recordingID: item.recordingID, createdAt: now())
        row.state = .pending
        row.sourceUpdatedAt = item.newest
        if item.changed { row.attempts = 0 }
        try await services.records.save(row)
    }

    /// A failed attempt; the third gives up until the transcript changes.
    func countFailure(_ item: Pending, error: String, apiCallID: APICall.ID?) async throws {
        var row = item.row ?? TranscriptExtraction(recordingID: item.recordingID, createdAt: now())
        let attempts = (item.changed ? 0 : row.attempts) + 1
        row.attempts = attempts
        row.error = String(error.prefix(300))
        row.apiCallID = apiCallID
        row.state = attempts >= TranscriptExtraction.maximumAttempts ? .failed : .pending
        row.sourceUpdatedAt = item.newest
        try await services.records.save(row)
    }
}
