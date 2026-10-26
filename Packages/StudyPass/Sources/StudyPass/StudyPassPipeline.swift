import ClaudeKit
import Foundation
import GRDB
import os
import StudyCore

/// The study pass's constants. Logs through `Log.logger(category: "study-pass")`; never logs
/// transcript text, quotes or slide text at `.public`.
public enum StudyPass {
    public static let moduleName = "StudyPass"

    /// Part of every unit's `input_hash`: bump it when a prompt or schema changes, so every unit
    /// is read again once.
    public static let promptVersion = 1

    /// Notional dollars one generation of a lecture's units may cost (`api_call.cost_usd`, purpose
    /// `study.*`, the calls since its units last went pending); over it, its remaining units are
    /// failed "Over budget" (`StudyUnit.overBudget`; they run again once their inputs change, or
    /// when the student retries: `retryFailed`).
    public static let lectureBudgetUSD = 1.50

    /// A lecture whose lines, spans, deck pages or prompt header (title, number, language,
    /// glossary) changed more recently waits (a realign burst or a run of edits settles first).
    public static let settleInterval: TimeInterval = 5 * 60

    /// A stage whose calls hit service trouble of their own (the CLI process failed, e.g. a CLI
    /// too old for the model; overload; a server or network error) waits this long, doubling up
    /// to `longestBackoff`, while the other stages and lectures go on.
    static let firstBackoff: TimeInterval = 30 * 60
    static let longestBackoff: TimeInterval = 4 * 60 * 60

    /// A cut-off answer is asked once more with twice the room, never above this.
    static let largestMaxTokens = 32_000

    static let log = Log.logger(category: "study-pass")
}

/// Runs the study pass over eligible lectures, one unit at a time, every call
/// `CallContext(purpose: stage.callPurpose, lectureID:, priority: .background)`. docs/plan-m4.md §3.
///
/// Contract for the app (integrator, Mac only): one instance with `ClaudeClient.socrates`;
/// `start()` in `startBackgroundWork` after the transcript pipeline; `wake()` when processing
/// finishes a lecture, after `Realigner.realign` and when availability turns ready;
/// `prefer(_:)` when a lecture opens in Review; `stop()` at quit. A nil client does nothing.
///
/// - **Eligible**: `client.isAvailable()` (and no usage pause), the lecture has transcript lines,
///   none of its jobs is queued or running, and none of its lines (a re-transcription, seen as
///   the oldest line's `updated_at`), spans or deck pages changed in the last 5 minutes.
/// - **Order**: the preferred lecture, then newest `held_at`. Per lecture: plan (one
///   transaction), then read units in page order, synthesis once no read unit is pending,
///   research once synthesis is not pending.
/// - **Failures**: service trouble (`ClaudeError.isServiceTrouble`) counts no attempt. Usage
///   limit, not installed, signed out or the account end the pass until `wake()` (a usage pause
///   wakes it at the reset); the rest (the CLI process, overload, server, network) holds only
///   that stage for 30 min, doubling up to 4 h, cleared by a success, a new CLI version or
///   availability turning ready. An answer cut off at its cap is asked once more with twice the
///   room, then `failed`; a refusal is `failed` at once; other failures count (3, then
///   `failed`). A generation over its budget fails its remaining units.
public actor StudyPassPipeline {
    let services: StudyServices
    let client: ClaudeClient?
    let now: @Sendable () -> Date
    /// The lecture open in Review: its units go first.
    private(set) var preferred: Lecture.ID?

    let writer: StudyWriter
    let webCheck = WebCheck()
    let debounce: Duration = .seconds(2)

    private var observation: AnyDatabaseCancellable?
    private var follower: Task<Void, Never>?
    private var passTask: Task<Void, Never>?
    private var again = false
    private var stopped = false
    private var pauseWake: Task<Void, Never>?
    private var settleWake: (at: Date, task: Task<Void, Never>)?
    private var backoffWake: (at: Date, task: Task<Void, Never>)?

    struct Backoff: Sendable {
        var until: Date
        var delay: TimeInterval
    }

    /// Stages held by their own service trouble (in memory).
    private var backoffs: [StudyStage: Backoff] = [:]
    /// Lectures left while a stage was held: planned again when it ends.
    private var waitingOnBackoff: Set<Lecture.ID> = []
    /// The availability seen last: a new CLI version or a turn to ready clears the backoffs.
    private var lastReady = false
    private var lastVersion: String?
    private var backoffVersion: String?
    /// The prompt header's columns per lecture as last seen, and when they last changed (in
    /// memory; a change counts as a lecture change for the settle).
    private var headers: [Lecture.ID: (key: String, changedAt: Date?)] = [:]
    /// When a lecture's current generation began (its units went from none to some pending): its
    /// budget counts the calls since.
    private var generationStart: [Lecture.ID: Date] = [:]
    /// What a lecture's inputs and rows looked like when a pass last found nothing to do for it;
    /// it is planned again only once that changes. Kept across launches in `settledFile` (M5: no
    /// launch burst), except the lectures in `transient`.
    private var settled: [Lecture.ID: Fingerprint] = [:]
    /// Lectures settled for a reason that ends with the launch (a stage's backoff, the run cap, an
    /// unreadable state): settled now, planned again after a relaunch, so never written down.
    private var transient: Set<Lecture.ID> = []
    /// What `settledFile` holds (nil: not read yet).
    private var persistedSettled: [Lecture.ID: Fingerprint]?
    /// Units (lecture/stage/key) that reached `done` since launch, and how often.
    private var completedRuns: [String: Int] = [:]
    static let maximumRunsPerLaunch = 5
    /// mt: the course materials' passages (Search's retriever; nil: no cover units).
    private var passages: (any MaterialPassages)?
    /// mt: lectures whose notes wait for their cover unit (queued when it settles).
    private var notesAfterCover: Set<Lecture.ID> = []
    /// mt: the cover input gathered per lecture, by what it was gathered from.
    private var coverCache: [Lecture.ID: (signature: String, input: CoverInput)] = [:]

    /// - Parameter passages: mt: the course materials' passages (Search's `MaterialRetriever`);
    ///   nil: no `cover` units (an existing one stays as it is).
    public init(
        services: StudyServices, client: ClaudeClient?, passages: (any MaterialPassages)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.client = client
        self.passages = passages
        self.now = now
        writer = StudyWriter(database: services.database, store: services.records)
    }

    /// mt: sets the course materials' passages after launch (the app makes the retriever later).
    public func setMaterialPassages(_ passages: (any MaterialPassages)?) {
        self.passages = passages
        coverCache = [:]
    }

    /// mt: a course's materials got their sections (`MaterialLibrary`'s `onSectionsReady`): its
    /// lectures with a written synthesis get their `cover` unit, one Haiku call each, in the
    /// background, one at a time. Returns at once.
    public func queueCoverBackfill(courseID: Course.ID) async {
        let lectures = (try? await services.database.read { db in
            try Lecture.where { $0.courseID.eq(courseID) }.select(\.id).fetchAll(db)
        }) ?? []
        for id in lectures {
            coverCache[id] = nil
            settled[id] = nil
            transient.remove(id)
        }
        Task { await self.wake() }
    }

    /// `settled` across launches: `AppPaths.caches/StudyPass/settled.json`.
    var settledFile: SettledFile {
        SettledFile(url: services.paths.caches.appending(path: "StudyPass/settled.json"))
    }

    // MARK: - Entry points

    /// Starts following lectures (transcripts, spans, deck pages, jobs, the prompt header's course
    /// and lecture columns); a first pass follows in the background. Returns at once.
    public func start() async {
        guard client != nil, observation == nil, !stopped else { return }
        restoreSettled()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let regions: [any DatabaseRegionConvertible] = [
            SQLRequest<Row>(sql: "SELECT lecture_id, updated_at FROM transcript_segment"),
            SQLRequest<Row>(sql: "SELECT lecture_id, updated_at FROM lecture_deck_span"),
            SQLRequest<Row>(sql: "SELECT deck_id, updated_at FROM deck_page"),
            SQLRequest<Row>(sql: "SELECT lecture_id, state FROM job"),
            SQLRequest<Row>(sql: "SELECT glossary, language FROM course"),
            SQLRequest<Row>(sql: "SELECT title, number, language FROM lecture"),
        ]
        observation = DatabaseRegionObservation(tracking: regions)
            .start(
                in: services.database,
                onError: { error in
                    StudyPass.log.error("Study pass observation failed: \(String(describing: error), privacy: .public)")
                },
                onChange: { _ in continuation.yield() }
            )
        let debounce = debounce
        follower = Task { [weak self] in
            for await _ in stream {
                // A transcription or realign writes many rows: wait for a quiet moment.
                do { try await Task.sleep(for: debounce) } catch { return }
                await self?.wake()
            }
        }
        // The first pass runs in the background too: launch never waits for the model.
        continuation.yield()
    }

    /// Looks for work again (after processing, a realign, or the end of a usage pause). Runs a
    /// pass (model calls included) before it returns, or returns at once when one is running (it
    /// then runs once more); call it from a task.
    public func wake() async {
        guard let task = startPass() else { return }
        await task.value
    }

    /// Starts a pass in the background, owned by `passTask` (`stop()` cancels it), unless one
    /// runs: that one then runs once more. Returns the new pass, nil when none started.
    @discardableResult
    private func startPass() -> Task<Void, Never>? {
        guard client != nil, !stopped else { return nil }
        if passTask != nil {
            again = true
            return nil
        }
        // Background work: nobody waits for it (the calls themselves queue behind the chat).
        let task = Task(priority: .utility) { await self.runPasses() }
        passTask = task
        return task
    }

    /// Puts this lecture's units first (the lecture open in Review); nil clears it.
    public func prefer(_ lectureID: Lecture.ID?) async {
        preferred = lectureID
        await wake()
    }

    /// ma: runs the lecture's study pass again (the app agent's `rerun_study_pass`, a `study_pass`
    /// task): its done and failed units (the pass's own stages; the coach's `quiz` units stay as
    /// they are) go back to `pending` (attempts 0; their rows stay until
    /// the new answers replace them), it is no longer settled and goes first, and a pass runs.
    /// The number of units reset.
    @discardableResult
    public func rerun(lectureID: Lecture.ID) async throws -> Int {
        let store = services.records
        let stamp = now()
        let stages = StudyPlanner.stages
        let reset = try await services.database.write { db -> Int in
            let units = try StudyUnit
                .where {
                    $0.lectureID.eq(lectureID) && $0.stage.in(stages)
                        && ($0.state.eq(ExtractionState.done) || $0.state.eq(ExtractionState.failed))
                }
                .fetchAll(db)
            for var unit in units {
                unit.state = .pending
                unit.attempts = 0
                unit.error = nil
                unit.finishedAt = nil
                let stamped = store.stamp(unit)
                try StudyUnit.upsert { stamped }.execute(db)
            }
            return units.count
        }
        reopen(lectureID, at: stamp)
        Task { await self.wake() }
        return reset
    }

    /// Retry on the lecture's Summary (and its Write Again), the student's own act: the pass's
    /// `failed` units of the lecture (a read, the synthesis, the cover unit, a research pick; never
    /// a done or skipped one) go back to `pending` (attempts 0), with a fresh budget window (the
    /// student's override of the automatic budget: after a relaunch the window starts at their
    /// `updated_at`). The lecture is no longer settled and goes first, its units' runs since
    /// launch count from zero (`reopen`, as `rerun`), and a pass starts. Writes no
    /// notes itself: the replace-once rules do when the synthesis lands
    /// (`LectureNotesRepository.queueAfterStudyPass`). Returns the number of units reset (0:
    /// nothing failed, nothing changes).
    @discardableResult
    public func retryFailed(lectureID: Lecture.ID) async throws -> Int {
        let store = services.records
        let stamp = now()
        let stages = StudyPlanner.stages
        let reset = try await services.database.write { db -> Int in
            let units = try StudyUnit
                .where { $0.lectureID.eq(lectureID) && $0.stage.in(stages) && $0.state.eq(ExtractionState.failed) }
                .fetchAll(db)
            for var unit in units {
                unit.state = .pending
                unit.attempts = 0
                unit.error = nil
                unit.finishedAt = nil
                let stamped = store.stamp(unit)
                try StudyUnit.upsert { stamped }.execute(db)
            }
            return units.count
        }
        guard reset > 0 else { return 0 }
        StudyPass.log.notice("Study pass retried: \(reset) failed units pending again")
        reopen(lectureID, at: stamp)
        startPass()
        return reset
    }

    /// The student asked for the lecture's pass again (`rerun`, `retryFailed`): it is no longer
    /// settled and goes first, its budget window starts now, and its units' runs since launch
    /// count from zero (a unit held by `maximumRunsPerLaunch` runs again).
    private func reopen(_ lectureID: Lecture.ID, at stamp: Date) {
        settled[lectureID] = nil
        transient.remove(lectureID)
        generationStart[lectureID] = stamp
        completedRuns = completedRuns.filter { !$0.key.hasPrefix(lectureID.uuidString) }
        preferred = lectureID
    }

    /// Stops following and ends the loop; a unit in flight stays `pending` (nothing half-written).
    public func stop() {
        stopped = true
        observation?.cancel()
        observation = nil
        follower?.cancel()
        follower = nil
        passTask?.cancel()
        pauseWake?.cancel()
        pauseWake = nil
        settleWake?.task.cancel()
        settleWake = nil
        backoffWake?.task.cancel()
        backoffWake = nil
    }

    // MARK: - Passes

    private func runPasses() async {
        repeat {
            again = false
            do {
                try await pass()
            } catch {
                StudyPass.log.error("Study pass failed: \(String(describing: error), privacy: .public)")
            }
            persistSettled()
        } while again && !stopped && !Task.isCancelled
        passTask = nil
    }

    /// Reads what the last launch had settled, once (at `start()`, or the first pass if a wake came
    /// first): the first pass then plans only lectures whose cheap fingerprint changed since,
    /// instead of loading every lecture at launch.
    private func restoreSettled() {
        guard persistedSettled == nil else { return }
        let restored = settledFile.read()
        settled.merge(restored) { current, _ in current }
        persistedSettled = restored
    }

    /// Writes `settled` (minus `transient`) when it changed since the file was last read or
    /// written.
    private func persistSettled() {
        let lasting = settled.filter { !transient.contains($0.key) }
        guard let persisted = persistedSettled, persisted != lasting else { return }
        if settledFile.write(lasting) { persistedSettled = lasting }
    }

    enum WorkOutcome: Sendable {
        /// Nothing left to run for the lecture (done, skipped, failed, over budget).
        case finished
        /// Nothing to run for now for a reason that ends with the launch (the run cap, an
        /// unreadable state or plan): settled, but not kept across launches.
        case finishedForNow
        /// Its inputs moved during the pass, or it is busy: planned again in a later pass (not
        /// marked settled).
        case unsettled
        /// Its next unit's stage is held by a backoff: planned again when it ends.
        case blocked
        case serviceTrouble
        /// Another lecture became preferred: the next pass starts with it.
        case preempted
        case stopped
    }

    /// One pass over the eligible lectures, one unit at a time.
    func pass() async throws {
        guard let client, await runsNow(client) else { return }
        restoreSettled()
        let states = try await lectureStates()
        // Lectures gone (or without lines) leave the settled set.
        let present = Set(states.map(\.id))
        settled = settled.filter { present.contains($0.key) }
        let date = now()
        var settleAt: Date?
        var ran: Set<String> = []
        let order = states.sorted { first, second in
            let firstPreferred = first.id == preferred
            let secondPreferred = second.id == preferred
            if firstPreferred != secondPreferred { return firstPreferred }
            switch (first.heldAt, second.heldAt) {
            case let (a?, b?) where a != b: return a > b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return first.id.uuidString < second.id.uuidString
            }
        }
        for state in order {
            if stopped || Task.isCancelled { return }
            guard !state.busy else { continue }
            if let changed = state.lastChange, date.timeIntervalSince(changed) < StudyPass.settleInterval {
                let ready = changed.addingTimeInterval(StudyPass.settleInterval)
                settleAt = min(settleAt ?? ready, ready)
                continue
            }
            if settled[state.id] == state.fingerprint { continue }
            switch await work(on: state.id, client: client, ran: &ran) {
            case .finished:
                if let fresh = try await lectureStates(only: state.id).first { settled[state.id] = fresh.fingerprint }
                transient.remove(state.id)
            case .finishedForNow:
                if let fresh = try await lectureStates(only: state.id).first { settled[state.id] = fresh.fingerprint }
                transient.insert(state.id)
            case .blocked:
                // Observation wakes leave it alone until the backoff ends.
                if let fresh = try await lectureStates(only: state.id).first { settled[state.id] = fresh.fingerprint }
                waitingOnBackoff.insert(state.id)
                transient.insert(state.id)
            case .unsettled:
                settled[state.id] = nil
                transient.remove(state.id)
            case .serviceTrouble:
                _ = await runsNow(client)
                return
            case .preempted:
                again = true
                return
            case .stopped:
                return
            }
        }
        if let settleAt { scheduleSettleWake(at: settleAt) }
        if let until = backoffs.values.map(\.until).filter({ $0 > now() }).min() { scheduleBackoffWake(at: until) }
    }

    /// Runs a lecture's units until none is runnable.
    func work(on lectureID: Lecture.ID, client: ClaudeClient, ran: inout Set<String>) async -> WorkOutcome {
        let startedPreferred = preferred
        while true {
            if stopped || Task.isCancelled { return .stopped }
            if preferred != startedPreferred, let preferred, preferred != lectureID { return .preempted }
            let date = now()
            // Before every unit: a job started, or an edit (a realign, a glossary term) came in,
            // while the last one ran.
            do {
                if let state = try await lectureStates(only: lectureID).first {
                    if state.busy { return .unsettled }
                    if let changed = state.lastChange, date.timeIntervalSince(changed) < StudyPass.settleInterval {
                        scheduleSettleWake(at: changed.addingTimeInterval(StudyPass.settleInterval))
                        return .unsettled
                    }
                }
            } catch {
                StudyPass.log.error("Study lecture state unreadable: \(String(describing: error), privacy: .public)")
                return .finishedForNow
            }
            let planned: (LectureMaterial, PassRows, [(StudyUnit, UnitSpec)])?
            do {
                planned = try await plan(lectureID, now: date)
            } catch {
                StudyPass.log.error("Study pass planning failed: \(String(describing: error), privacy: .public)")
                return .finishedForNow
            }
            guard case let (material, rows, units)? = planned else {
                await flushNotesAfterCover(lectureID)
                return .finished
            }
            // mt: notes that waited for a cover unit that will not run now (skipped, failed, gone).
            if notesAfterCover.contains(lectureID), !units.contains(where: { $0.0.stage == .cover && $0.0.state == .pending && !$0.1.skip }) {
                await flushNotesAfterCover(lectureID)
            }
            guard case let (unit, spec)? = Self.next(units, blocked: blockedStages(at: date)) else {
                if Self.next(units) != nil { return .blocked }
                generationStart[lectureID] = nil
                return .finished
            }
            let mark = "\(lectureID)/\(unit.stage.rawValue)/\(unit.key)"
            if ran.contains(mark) {
                // Its inputs moved again within this pass: leave it for a later one.
                StudyPass.log.notice("Study unit \(unit.stage.rawValue, privacy: .public) \(unit.key, privacy: .public) pending again in the same pass")
                return .unsettled
            }
            if completedRuns[mark, default: 0] >= Self.maximumRunsPerLaunch {
                // A unit that keeps coming back would spend the student's usage: never more than
                // this per launch.
                StudyPass.log.error("Study unit \(unit.stage.rawValue, privacy: .public) \(unit.key, privacy: .public) ran \(Self.maximumRunsPerLaunch) times since launch; held until the next launch")
                return .finishedForNow
            }
            // The budget is per generation: the calls since its units went pending (a prompt
            // change or a glossary edit starts a new one).
            let pendingSince = units.filter { $0.0.state == .pending && !$0.1.skip }.map(\.0.updatedAt).min() ?? date
            let since = min(generationStart[lectureID] ?? pendingSince, pendingSince)
            generationStart[lectureID] = since
            do {
                let spent = try await writer.spent(lectureID: lectureID, since: since)
                if spent >= StudyPass.lectureBudgetUSD {
                    let failed = try await writer.failPending(lectureID: lectureID, error: StudyUnit.overBudget)
                    StudyPass.log.notice("Lecture over its study budget (\(spent, format: .fixed(precision: 2)) USD): \(failed) units failed")
                    // The generation ended: a later one (new inputs, Retry) counts from its own start.
                    generationStart[lectureID] = nil
                    return .finished
                }
            } catch {
                StudyPass.log.error("Study budget unreadable: \(String(describing: error), privacy: .public)")
                return .finishedForNow
            }
            switch await run(unit, spec: spec, material: material, rows: rows, client: client) {
            case .done:
                ran.insert(mark)
                completedRuns[mark, default: 0] += 1
            case .discarded:
                return .unsettled
            case .failed, .stageTrouble:
                // A held stage: the lecture's other runnable units go on (none, when it held
                // its reads or synthesis).
                continue
            case .serviceTrouble:
                return .serviceTrouble
            case .stopped:
                return .stopped
            }
        }
    }

    /// Loads the lecture, plans its units and reconciles `study_unit` (one transaction). Nil when
    /// the lecture is gone or has no lines.
    func plan(_ lectureID: Lecture.ID, now date: Date) async throws -> (LectureMaterial, PassRows, [(StudyUnit, UnitSpec)])? {
        let loaded = try await services.database.read { db -> (LectureMaterial, PassRows)? in
            guard let material = try LectureMaterial.load(lectureID, in: db) else { return nil }
            return (material, try PassRows.load(lectureID, in: db))
        }
        guard case let (material, rows)? = loaded else { return nil }
        let cover = try await coverPlan(material, rows: rows)
        let specs = StudyPlanner.plan(material, rows: rows, cover: cover)
        let store = services.records
        let units = try await services.database.write { db in
            try StudyPlanner.reconcile(specs, lectureID: lectureID, in: db, store: store, now: date)
        }
        return (material, rows, Array(zip(units, specs)))
    }

    /// The next unit to run: the first pending read; the synthesis once no read is pending;
    /// research once the synthesis is not pending. Nil when that unit's stage is `blocked`. mt:
    /// the cover unit once the synthesis is not pending, research once it is not pending either
    /// (book first).
    static func next(_ units: [(StudyUnit, UnitSpec)], blocked: Set<StudyStage> = []) -> (StudyUnit, UnitSpec)? {
        let pending = units.filter { $0.0.state == .pending && !$0.1.skip }
        if let read = pending.first(where: { $0.0.stage == .read }) { return blocked.contains(.read) ? nil : read }
        if let synthesis = pending.first(where: { $0.0.stage == .synthesize }) {
            return blocked.contains(.synthesize) ? nil : synthesis
        }
        let synthesisPending = units.contains { $0.0.stage == .synthesize && $0.0.state == .pending }
        guard !synthesisPending else { return nil }
        if let cover = pending.first(where: { $0.0.stage == .cover }) { return blocked.contains(.cover) ? nil : cover }
        guard !blocked.contains(.research) else { return nil }
        return pending.first { $0.0.stage == .research }
    }

    // MARK: - Running a unit

    enum RunOutcome: Sendable {
        case done
        /// The unit's inputs changed during the call: nothing written, it runs again.
        case discarded
        case failed
        /// Service trouble that stops every call: the pass ends.
        case serviceTrouble
        /// Service trouble of this stage's calls: the stage backs off.
        case stageTrouble
        case stopped
    }

    func run(_ unit: StudyUnit, spec: UnitSpec, material: LectureMaterial, rows: PassRows, client: ClaudeClient) async -> RunOutcome {
        guard let prompt = spec.prompt else { return .done }
        let purpose = unit.stage.callPurpose
        let context = CallContext(purpose: purpose, lectureID: material.lecture.id, priority: .background)
        let system = MessageRequest.systemPrompt(prompt.system)
        var images: [(page: Int, data: Data)] = []
        var request: MessageRequest
        switch spec.work {
        case .read:
            images = SlideImages.jpegs(pages: prompt.imagePages, deck: material.deck, blobs: services.blobs)
            var blocks: [ContentBlock] = []
            for image in images {
                blocks.append(.text("Image of slide \(image.page):"))
                blocks.append(.image(image.data, mediaType: "image/jpeg"))
            }
            blocks.append(.text(prompt.text))
            request = MessageRequest(
                model: ReadStage.model, maxTokens: ReadStage.maxTokens, effort: ReadStage.effort, messages: [.user(blocks)],
                system: system, outputFormat: .jsonSchema(prompt.schema))
        case .synthesize:
            request = MessageRequest(
                model: SynthesisStage.model, maxTokens: SynthesisStage.maxTokens, effort: SynthesisStage.effort,
                messages: [.user(prompt.text)], system: system, outputFormat: .jsonSchema(prompt.schema))
        case .research:
            request = MessageRequest(
                model: ResearchStage.model, maxTokens: ResearchStage.maxTokens, effort: ResearchStage.effort,
                messages: [.user(prompt.text)], system: system, tools: ResearchStage.tools,
                outputFormat: .jsonSchema(prompt.schema))
        case .cover:
            request = MessageRequest(
                model: CoverStage.model, maxTokens: CoverStage.maxTokens, effort: CoverStage.effort,
                messages: [.user(prompt.text)], system: system, outputFormat: .jsonSchema(prompt.schema))
        }
        let firstMaxTokens = request.maxTokens
        var apiCallID: APICall.ID?
        let started = ContinuousClock.now
        while true {
            do {
                let message = try await client.streamMessage(request, context: context)
                apiCallID = try? await APICallRepository(store: services.records).call(requestID: message.requestID, purpose: purpose)
                let result: UnitResult
                switch spec.work {
                case .read(let block):
                    let answer = try message.decodeJSON(ReadStage.Answer.self)
                    result = ReadStage.verify(answer, block: block, material: material, imagePages: images.map(\.page), apiCallID: apiCallID)
                case .synthesize:
                    let answer = try message.decodeJSON(SynthesisStage.Answer.self)
                    result = SynthesisStage.verify(answer, material: material, rows: rows, apiCallID: apiCallID)
                case .research(let pick):
                    let answer = try message.decodeJSON(ResearchStage.Answer.self)
                    result = await ResearchStage.verify(answer, pick: pick, material: material, check: webCheck, apiCallID: apiCallID)
                case .cover(let input):
                    let answer = try message.decodeJSON(CoverStage.Answer.self)
                    result = input.map { CoverStage.verify(answer, input: $0, material: material, apiCallID: apiCallID) } ?? UnitResult()
                }
                if stopped || Task.isCancelled { return .stopped }
                let written = try await writer.finish(unit.id, expectedHash: unit.inputHash, result: result, apiCallID: apiCallID, now: now())
                backoffs[unit.stage] = nil
                let seconds = (ContinuousClock.now - started).components.seconds
                guard written else {
                    StudyPass.log.notice("\(purpose, privacy: .public) \(unit.key, privacy: .public): inputs changed during the call; not written")
                    return .discarded
                }
                // ln: the lecture's notes are written after its synthesis (the first time, once more
                // when they came from the slides alone or without the topics, or after the student
                // re-ran the pass).
                // mt: when the lecture gets a cover unit, its notes wait for it (their book passages).
                if case .synthesize = spec.work {
                    if await coverFollows(material.lecture) {
                        notesAfterCover.insert(material.lecture.id)
                    } else {
                        await queueNotes(material.lecture.id)
                    }
                }
                if case .cover = spec.work {
                    notesAfterCover.remove(material.lecture.id)
                    await queueNotes(material.lecture.id)
                }
                // ma: a synthesis with said-in-class admin or deadline rows is a new fact for the
                // app agent's triage (dates, rooms, rules said in class); one event per version.
                if case .synthesize = spec.work,
                   result.annotations.contains(where: { $0.kind == .notOnSlides && ($0.category == .admin || $0.category == .deadline) }) {
                    _ = try? await AgentEventRepository(store: services.records).record(AgentEvent(
                        kind: .studyPass, sourceKey: "study_pass:\(material.lecture.id.uuidString.lowercased()):\(unit.inputHash)",
                        courseID: material.lecture.courseID, lectureID: material.lecture.id
                    ))
                }
                let patchedLines = (result.patches ?? [:]).values.filter { !$0.isEmpty }.count
                StudyPass.log.info(
                    "\(purpose, privacy: .public) \(unit.key, privacy: .public) done in \(seconds)s: \(result.annotations.count) rows, \(patchedLines) corrected lines; dropped \(result.drops.summary, privacy: .public)"
                )
                return .done
            } catch ClaudeError.truncated where request.maxTokens == firstMaxTokens && firstMaxTokens < StudyPass.largestMaxTokens {
                // Cut off at the cap: once more with twice the room (never three identical asks).
                if stopped || Task.isCancelled { return .stopped }
                request.maxTokens = min(firstMaxTokens * 2, StudyPass.largestMaxTokens)
                StudyPass.log.notice("\(purpose, privacy: .public) \(unit.key, privacy: .public) cut off at \(firstMaxTokens) tokens; asking once more with \(request.maxTokens)")
                continue
            } catch ClaudeError.turnLimit(let reason) where spec.work.isResearch {
                // The web run kept searching until its turn limit: asking again would end the same
                // way. Done without sources (no attempt counted, never retried; its inputs changing
                // plans it again).
                if stopped || Task.isCancelled { return .stopped }
                var result = UnitResult()
                result.drops.drop("research.turn_limit")
                do {
                    let written = try await writer.finish(unit.id, expectedHash: unit.inputHash, result: result, apiCallID: nil, now: now())
                    backoffs[unit.stage] = nil
                    guard written else { return .discarded }
                } catch {
                    StudyPass.log.error("Study unit result not recorded: \(String(describing: error), privacy: .public)")
                    return .stopped
                }
                StudyPass.log.notice("\(purpose, privacy: .public) \(unit.key, privacy: .public) done without sources: \(reason, privacy: .public)")
                return .done
            } catch let error as ClaudeError where error.isServiceTrouble {
                StudyPass.log.notice("\(purpose, privacy: .public) \(unit.key, privacy: .public) waits: \(error.description, privacy: .public)")
                guard !error.stopsEveryCall else { return .serviceTrouble }
                backOff(unit.stage)
                return .stageTrouble
            } catch is CancellationError {
                return .stopped
            } catch {
                if stopped || Task.isCancelled { return .stopped }
                StudyPass.log.error("\(purpose, privacy: .public) \(unit.key, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                // A cut-off answer at twice the cap, or a refusal, would only repeat.
                let final: Bool
                switch error as? ClaudeError {
                case .truncated?, .refused?: final = true
                default: final = false
                }
                do {
                    try await writer.countFailure(unit.id, error: String(describing: error), apiCallID: apiCallID, final: final)
                } catch {
                    StudyPass.log.error("Study unit failure not recorded: \(String(describing: error), privacy: .public)")
                    return .stopped
                }
                return .failed
            }
        }
    }

    // MARK: - Cover (mt)

    /// Whether a lecture's `cover` unit will be planned (a retriever and a coverable material).
    private func coverFollows(_ lecture: Lecture) async -> Bool {
        guard passages != nil else { return false }
        let courseID = lecture.courseID
        let coverable = (try? await services.database.read { db in try MaterialRepository.coverable(courseID: courseID, in: db) }) ?? []
        return !coverable.isEmpty
    }

    private func flushNotesAfterCover(_ lectureID: Lecture.ID) async {
        guard notesAfterCover.remove(lectureID) != nil else { return }
        await queueNotes(lectureID)
    }

    /// The lecture's cover unit: none, the existing one kept (no retriever), or its input
    /// gathered on device (cached while the topics and the course's materials stay the same).
    func coverPlan(_ material: LectureMaterial, rows: PassRows) async throws -> CoverPlan {
        let existing = rows.units(.cover).first
        guard let passages else { return existing.map { .keep($0) } ?? .none }
        let topics = rows.annotations(.topic, of: .synthesize)
        guard !topics.isEmpty else { return .none }
        let courseID = material.lecture.courseID
        let loaded = try await services.database.read { db in
            let coverable = try MaterialRepository.coverable(courseID: courseID, in: db)
            var sections: [CourseMaterial.ID: [MaterialSection]] = [:]
            for item in coverable { sections[item.id] = try MaterialRepository.sections(of: item.id, in: db) }
            return (coverable, sections)
        }
        let (coverable, sections) = loaded
        guard !coverable.isEmpty else { return .none }
        let signature = (topics.map { "\($0.id)|\($0.body)|\($0.pageNumber ?? 0)-\($0.lastPage ?? 0)" }
            + coverable.map { "\($0.id)|\($0.updatedAt.timeIntervalSince1970)|\(sections[$0.id]?.count ?? 0)" })
            .joined(separator: "\n")
        if let cached = coverCache[material.lecture.id], cached.signature == signature { return .input(cached.input) }
        var summaries: [Int: String] = [:]
        for row in rows.annotations(.summary, of: .read) {
            if let page = row.pageNumber, summaries[page] == nil { summaries[page] = row.body }
        }
        let database = services.database
        let input = try await CoverInput.gather(
            material: material, rows: rows, coverable: coverable, sections: sections, summaries: summaries, passages: passages,
            openings: { item, section in
                guard let documentID = item.documentID else { return "" }
                let page = section.firstPage
                return (try? await database.read { db in
                    try StudyDocumentPage.where { $0.documentID.eq(documentID) && $0.pageNumber.eq(page) }.select(\.text).fetchOne(db)
                }) ?? ""
            }
        )
        guard let input else { return .none }
        coverCache[material.lecture.id] = (signature, input)
        return .input(input)
    }

    /// ln: `LectureNotesRepository.queueAfterStudyPass` once a synthesis unit is written (a re-run
    /// the student asked for is read from its `study_pass` task there).
    private func queueNotes(_ lectureID: Lecture.ID) async {
        do {
            if try await LectureNotesRepository(store: services.records).queueAfterStudyPass(lectureID: lectureID) != nil {
                StudyPass.log.info("Lecture notes queued after the study pass")
            }
        } catch {
            StudyPass.log.error("Queueing lecture notes failed: \(ReadableError.kind(of: error), privacy: .public)")
        }
    }

    // MARK: - Backoff

    /// Holds `stage` for 30 min (doubling up to 4 h on each further trouble).
    private func backOff(_ stage: StudyStage) {
        let delay = backoffs[stage].map { min($0.delay * 2, StudyPass.longestBackoff) } ?? StudyPass.firstBackoff
        backoffs[stage] = Backoff(until: now().addingTimeInterval(delay), delay: delay)
        backoffVersion = lastVersion
        StudyPass.log.notice("Study stage \(stage.rawValue, privacy: .public) held for \(Int(delay / 60)) min")
    }

    func blockedStages(at date: Date) -> Set<StudyStage> {
        Set(backoffs.filter { $0.value.until > date }.keys)
    }

    /// Lifts every backoff (a new CLI version, availability turned ready): the lectures it held
    /// are planned again.
    private func liftBackoffs() {
        backoffs = [:]
        for id in waitingOnBackoff { settled[id] = nil }
        waitingOnBackoff = []
        backoffWake?.task.cancel()
        backoffWake = nil
    }

    private func scheduleBackoffWake(at date: Date) {
        if let current = backoffWake, current.at <= date { return }
        backoffWake?.task.cancel()
        let delay = max(1, date.timeIntervalSince(now()) + 1)
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.backoffEnded()
        }
        backoffWake = (date, task)
    }

    private func backoffEnded() async {
        backoffWake = nil
        for id in waitingOnBackoff { settled[id] = nil }
        waitingOnBackoff = []
        await wake()
    }

    // MARK: - Availability and timers

    /// Calls can run now: the client is available and no usage pause holds (a pass follows when
    /// it ends).
    func runsNow(_ client: ClaudeClient) async -> Bool {
        let availability = await client.availability()
        let version = availability.status?.version
        if availability.isReady, !backoffs.isEmpty, !lastReady || version != backoffVersion {
            liftBackoffs()
        }
        lastReady = availability.isReady
        lastVersion = version
        guard availability.isReady else { return false }
        if let until = availability.pausedUntil {
            if pauseWake == nil {
                pauseWake = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(max(1, until.timeIntervalSinceNow + 1))) } catch { return }
                    await self?.pauseEnded()
                }
            }
            return false
        }
        return true
    }

    private func pauseEnded() async {
        pauseWake = nil
        await wake()
    }

    /// A pass when the next waiting lecture has settled.
    private func scheduleSettleWake(at date: Date) {
        if let current = settleWake, current.at <= date { return }
        settleWake?.task.cancel()
        let delay = max(1, date.timeIntervalSince(now()) + 1)
        let task = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.settleEnded()
        }
        settleWake = (date, task)
    }

    private func settleEnded() async {
        settleWake = nil
        await wake()
    }

    // MARK: - Lecture states

    /// What decides whether a lecture is planned again: its lines, spans, deck pages, units and
    /// the columns of its row and course that its prompts' hashes see (`header`; not
    /// `updated_at`, which Review moves every few seconds). Codable for `settled.json`.
    struct Fingerprint: Hashable, Sendable, Codable {
        var lines = 0
        var oldestLine: Date?
        var newestLine: Date?
        var spans = 0
        var newestSpan: Date?
        var newestPage: Date?
        var units = 0
        var newestUnit: Date?
        /// Title, number, language; the course's language and glossary.
        var header = ""
    }

    struct LectureState: Sendable {
        var id: Lecture.ID
        var heldAt: Date?
        /// A job of it is queued or running.
        var busy: Bool
        /// The latest re-transcription (oldest line), span, deck page or header change.
        var lastChange: Date?
        var fingerprint: Fingerprint
    }

    /// Every lecture with transcript lines (or only `lectureID`). A header change (seen here
    /// first, in memory) counts as a change for the settle.
    func lectureStates(only lectureID: Lecture.ID? = nil) async throws -> [LectureState] {
        let date = now()
        return try await loadStates(only: lectureID).map { state in
            var state = state
            let key = state.fingerprint.header
            if let seen = headers[state.id] {
                if seen.key != key { headers[state.id] = (key, date) }
            } else {
                headers[state.id] = (key, nil)
            }
            if let changed = headers[state.id]?.changedAt {
                state.lastChange = max(state.lastChange ?? changed, changed)
            }
            return state
        }
    }

    private func loadStates(only lectureID: Lecture.ID?) async throws -> [LectureState] {
        try await services.database.read { db in
            let lineStats = try TranscriptSegment
                .where { $0.lectureID.isNot(nil) }
                .group(by: \.lectureID)
                .select { ($0.lectureID, $0.id.count(), $0.updatedAt.min(), $0.updatedAt.max()) }
                .fetchAll(db)
            let spanStats = try LectureDeckSpan
                .group(by: \.lectureID)
                .select { ($0.lectureID, $0.id.count(), $0.updatedAt.max()) }
                .fetchAll(db)
            let spanDecks = try LectureDeckSpan.select { ($0.lectureID, $0.deckID) }.fetchAll(db)
            let pageStats = try DeckPage.group(by: \.deckID).select { ($0.deckID, $0.updatedAt.max()) }.fetchAll(db)
            let stages = StudyPlanner.stages
            let unitStats = try StudyUnit
                .where { $0.stage.in(stages) }
                .group(by: \.lectureID)
                .select { ($0.lectureID, $0.id.count(), $0.updatedAt.max()) }
                .fetchAll(db)
            let busyStates: [JobState] = [.queued, .running]
            let busy = Set(try Job
                .where { $0.lectureID.isNot(nil) && $0.state.in(busyStates) }
                .select(\.lectureID)
                .fetchAll(db)
                .compactMap { $0 })
            let lectures = Dictionary(try Lecture.all.fetchAll(db).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let courses = Dictionary(
                try Course.all.fetchAll(db).map { ($0.id, $0.language + "\u{1F}" + $0.glossary) }, uniquingKeysWith: { first, _ in first })

            var fingerprints: [Lecture.ID: Fingerprint] = [:]
            for (id, count, oldest, newest) in lineStats {
                guard let id, lectureID == nil || id == lectureID else { continue }
                fingerprints[id] = Fingerprint(lines: count, oldestLine: oldest, newestLine: newest)
            }
            for (id, count, newest) in spanStats where fingerprints[id] != nil {
                fingerprints[id]?.spans = count
                fingerprints[id]?.newestSpan = newest
            }
            let pageNewest = Dictionary(pageStats.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
            for (id, deckID) in spanDecks where fingerprints[id] != nil {
                guard let page = pageNewest[deckID] ?? nil else { continue }
                let newest = max(fingerprints[id]?.newestPage ?? page, page)
                fingerprints[id]?.newestPage = newest
            }
            for (id, count, newest) in unitStats where fingerprints[id] != nil {
                fingerprints[id]?.units = count
                fingerprints[id]?.newestUnit = newest
            }
            return fingerprints.compactMap { id, fingerprint -> LectureState? in
                guard let lecture = lectures[id] else { return nil }
                var fingerprint = fingerprint
                fingerprint.header = [lecture.title, lecture.number.map(String.init) ?? "", lecture.language, courses[lecture.courseID] ?? ""]
                    .joined(separator: "\u{1F}")
                let lastChange = [fingerprint.oldestLine, fingerprint.newestSpan, fingerprint.newestPage].compactMap { $0 }.max()
                return LectureState(id: id, heldAt: lecture.heldAt, busy: busy.contains(id), lastChange: lastChange, fingerprint: fingerprint)
            }
        }
    }
}

extension UnitSpec.Work {
    var isResearch: Bool {
        if case .research = self { return true }
        return false
    }
}

extension ClaudeError {
    /// Service trouble that stops every call (the usage limit, no CLI or sign-in, the account):
    /// the pass ends until woken. Other service trouble (the CLI process, overload, a server or
    /// network error) holds only the stage whose call met it.
    var stopsEveryCall: Bool {
        switch self {
        case .usageLimited, .unavailable, .missingAPIKey, .authentication, .permissionDenied, .billing: true
        default: false
        }
    }
}
