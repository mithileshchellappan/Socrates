import Capture
import Foundation
import Observation
import RecorderActivity
import RecorderContract

// The recorder's command executor and its published state (README "Recorder contract").
//
// - Every surface sends a `RecorderCommand`: the Live Activity and the Mac remote
//   (`RecorderEndpoint`) through `perform(_:)`, the screen through `submit(_:)`. Commands run
//   one at a time on the model's serial queue on the main actor (the session's actor, where
//   stamps take their host time), each checked by `RecorderMachine` against the snapshot before
//   it acts and against the phase it should reach after, and each id is applied once.
// - `snapshot` is the only state a surface renders. `publish()` rebuilds it from the session and
//   the course and counts `sequence` up when its content changed; it runs after every command,
//   and on any other change of what it reads (a failure, the input lost), through an
//   observation of those inputs. The Live Activity follows the snapshot from there.

extension PhoneRecorder {
    // MARK: - Commands

    /// Runs a command from any surface and answers with the state after it. Commands wait for
    /// the ones before them; a repeated id is answered `.duplicate` and does nothing.
    @discardableResult
    public func perform(_ command: RecorderCommand) async -> RecorderOutcome {
        await serially { await self.execute(command) }
    }

    /// One tap on the recorder screen: a new command for the recording on show, queued behind
    /// the work before it. A failure the student should see becomes `problem`.
    public func submit(_ action: RecorderCommand.Action) {
        guard let snapshot else {
            RecorderLog.recorder.notice("\(action.kind.rawValue, privacy: .public) from the screen: nothing records")
            return
        }
        let command = RecorderCommand.fresh(action, recordingID: snapshot.recordingID, origin: .screen)
        enqueue { _ = await self.execute(command) }
    }

    /// Runs `work` after everything queued before it and returns its result, so no two
    /// commands interleave across their suspension points.
    func serially<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        await queued(work).value
    }

    /// Queues `work` after everything before it without waiting for it (a tap).
    func enqueue(_ work: @escaping @MainActor () async -> Void) {
        queued(work)
    }

    /// The model's serial queue: each task waits for the one before; `commandTail` keeps the last.
    @discardableResult
    private func queued<T: Sendable>(_ work: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = commandTail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        commandTail = Task { _ = await task.value }
        return task
    }

    private func execute(_ command: RecorderCommand) async -> RecorderOutcome {
        publish()
        let result: RecorderOutcome.Result
        switch machine.decide(command, current: snapshot) {
        case .answer(let answer):
            result = answer
        case .apply:
            result = await apply(command)
        }
        machine.settle(command, as: result)
        publish()
        if result != .applied {
            RecorderLog.recorder.notice(
                "\(command.action.kind.rawValue, privacy: .public) from \(command.origin.rawValue, privacy: .public): \(String(describing: result), privacy: .public)"
            )
        }
        // A recording that stopped meanwhile says so itself (`didFinish`); a remote command's
        // failure is the remote's to show (the Mac draws it under its controls).
        if case .failed(let failure) = result, failure != .stoppedMeanwhile, command.origin != .remote {
            problem = RecorderProblem(moment: .command(command.action.kind), failure: failure)
        }
        if command.origin == .liveActivity {
            if result != .applied { resync(after: result) }
            // The system may suspend the app as soon as the intent returns: the activity shows
            // the outcome first, for an applied Next Slide and for a refused one alike. An app
            // suspended again right after a tap (an interruption stopped the audio) would
            // otherwise keep the old slide on the Lock Screen, and the next tap would be refused.
            await activity.settled()
        }
        return RecorderOutcome(commandID: command.id, result: result, snapshot: snapshot)
    }

    /// Runs an accepted command, then checks it reached the phase the machine says it leads to
    /// (a failure can stop the recording while a command waits on the capture).
    private func apply(_ command: RecorderCommand) async -> RecorderOutcome.Result {
        do {
            try await run(command.action)
        } catch {
            RecorderLog.recorder.error(
                "\(command.action.kind.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            return .failed(RecorderFailure(error))
        }
        publish()
        guard snapshot?.phase == RecorderMachine.phase(after: command.action) else { return .failed(.stoppedMeanwhile) }
        return .applied
    }

    private func run(_ action: RecorderCommand.Action) async throws {
        guard let session else { throw CaptureError.notRecording }
        switch action {
        case .pause:
            try await session.pause()
            // The Live Activity shows Paused before the input goes: iOS may suspend the app
            // seconds after the audio session ends.
            publish()
            await activity.settled()
            await session.releaseInput()
        case .resume:
            try await session.resume()
        case .nextSlide:
            guard session.next() else { throw CaptureError.notRecording }
        case .previousSlide:
            guard session.previous() else { throw CaptureError.notRecording }
        case .flag:
            guard session.flag() != nil else { throw CaptureError.notRecording }
        case .stop:
            await session.stop()
        }
    }

    /// A Live Activity button that did nothing was drawn from an older state (or the system ran
    /// its tap again): draw the current one, or end the activity when its recording is gone or
    /// stopped (an end that never reached ActivityKit is sent again).
    private func resync(after result: RecorderOutcome.Result) {
        switch result {
        case .rejected(.noRecording), .rejected(.otherRecording):
            activity.endStale()
        default:
            if let snapshot, snapshot.phase != .stopped {
                activity.show(RecordingActivityState(snapshot: snapshot), force: true)
            } else {
                activity.endStale()
            }
        }
    }

    // MARK: - Snapshot

    /// Rebuilds `snapshot` and, when its content changed, counts its sequence up and brings the
    /// Live Activity along (ended once stopped). Idempotent.
    func publish() {
        guard let built = makeSnapshot(sequence: snapshot?.sequence ?? 0, phaseSince: snapshot?.phaseSince),
              built != snapshot else { return }
        var next = built
        lastSequence += 1
        next.sequence = lastSequence
        // The phase's start stays while the recording and its phase do (so an unchanged state
        // still compares equal above); a new phase or recording starts at this sequence.
        if let snapshot, snapshot.recordingID == next.recordingID, snapshot.phase == next.phase {
            next.phaseSince = snapshot.phaseSince
        } else {
            next.phaseSince = next.sequence
        }
        snapshot = next
        let state = RecordingActivityState(snapshot: next)
        if next.phase == .stopped {
            activity.end(with: state)
        } else {
            activity.show(state)
        }
    }

    /// Publishes whenever anything the snapshot reads changes (the session's phase, slide,
    /// events and input; the course), also outside commands.
    func observeSnapshot() -> Task<Void, Never> {
        let changes = Observations { @MainActor [weak self] in
            self?.makeSnapshot(sequence: 0)
        }
        return Task { [weak self] in
            for await _ in changes {
                self?.publish()
            }
        }
    }

    /// The state now, or nil before the recording's first audio. `phaseSince` nil: `sequence`.
    private func makeSnapshot(sequence: Int, phaseSince: Int? = nil) -> RecorderSnapshot? {
        guard let session, let course, let recordingID, let startedAt = session.startedAt else { return nil }
        let phase: RecorderSnapshot.Phase
        var failure: RecorderFailure?
        switch session.phase {
        case .ready, .starting: return nil
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .stopping: phase = .stopping
        case .finished: phase = .stopped
        case .failed(let reason):
            phase = .stopped
            failure = RecorderFailure(reason)
        }
        return RecorderSnapshot(
            recordingID: recordingID,
            sequence: sequence,
            phase: phase,
            timing: RecordingTiming(
                startedAt: startedAt,
                pauses: session.pauses.pauses.map { RecordingTiming.Pause(start: $0.startedAt, end: $0.endedAt) },
                stoppedAt: session.endedAt
            ),
            slide: session.currentPage,
            slideCount: session.hasDeck ? session.pageCount : nil,
            flagCount: session.events.count { $0.kind == .flag },
            isInputAvailable: session.isInputAvailable,
            course: RecorderSnapshot.Course(name: course.name, shortName: course.shortName, colorHex: course.colorHex),
            sessionName: sessionName,
            accepts: RecorderMachine.accepts(phase: phase, canGoNext: session.canGoNext, canGoPrevious: session.canGoPrevious),
            failure: failure,
            closedSegments: session.closedThrough,
            phaseSince: phaseSince
        )
    }

    /// The capture package's id (a preview has none and makes one up).
    private var recordingID: RecordingID? {
        #if DEBUG
        if isPreview { return previewRecordingID }
        #endif
        return session?.package?.id.map { RecordingID($0) }
    }
}
