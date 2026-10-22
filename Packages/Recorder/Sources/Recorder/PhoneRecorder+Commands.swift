import Capture
import Foundation
import Observation
import RecorderActivity
import RecorderContract

// The recorder's command executor and its published state (README "Recorder contract").
//
// - Every surface sends a `RecorderCommand` to `perform(_:)`. Commands run one at a time on the
//   main actor (the session's actor, where stamps take their host time), each checked by
//   `RecorderMachine` against the snapshot before it acts, and each id is applied once.
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

    /// One tap on the recorder screen: a new command for the recording on now.
    @discardableResult
    public func send(_ action: RecorderCommand.Action) async -> RecorderOutcome {
        // Without a recording the machine answers `.noRecording` whatever the id says.
        await perform(.fresh(action, recordingID: snapshot?.recordingID ?? UUID(), origin: .screen))
    }

    /// Runs `work` after everything queued before it, so no two commands interleave across their
    /// suspension points.
    func serially<T: Sendable>(_ work: @escaping @MainActor () async -> T) async -> T {
        let previous = commandTail
        let task = Task { @MainActor in
            await previous?.value
            return await work()
        }
        commandTail = Task { _ = await task.value }
        return await task.value
    }

    private func execute(_ command: RecorderCommand) async -> RecorderOutcome {
        publish()
        let result: RecorderOutcome.Result
        switch machine.decide(command, current: snapshot) {
        case .answer(let answer):
            result = answer
        case .apply:
            do {
                try await apply(command.action)
                result = .applied
            } catch {
                result = .failed(error.localizedDescription)
            }
        }
        machine.settle(command, as: result)
        publish()
        if result != .applied {
            RecorderLog.recorder.notice(
                "\(command.action.kind.rawValue, privacy: .public) from \(command.origin.rawValue, privacy: .public): \(String(describing: result), privacy: .public)"
            )
            if command.origin == .liveActivity { resync(after: result) }
        }
        return RecorderOutcome(commandID: command.id, result: result, snapshot: snapshot)
    }

    private func apply(_ action: RecorderCommand.Action) async throws {
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
            session.next()
        case .previousSlide:
            session.previous()
        case .flag:
            session.flag()
        case .stop:
            await session.stop()
        }
    }

    /// A Live Activity button that did nothing was drawn from an older state (or the system ran
    /// its tap again): draw the current one, or end the activity when its recording is gone.
    private func resync(after result: RecorderOutcome.Result) {
        switch result {
        case .rejected(.noRecording), .rejected(.otherRecording):
            activity.endStale()
        default:
            if let snapshot, snapshot.phase != .stopped {
                activity.show(RecordingActivityState(snapshot: snapshot), force: true)
            }
        }
    }

    // MARK: - Snapshot

    /// Rebuilds `snapshot` and, when its content changed, counts its sequence up and brings the
    /// Live Activity along (ended once stopped). Idempotent.
    func publish() {
        guard let built = makeSnapshot(sequence: snapshot?.sequence ?? 0), built != snapshot else { return }
        var next = built
        next.sequence = (snapshot?.sequence ?? 0) + 1
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

    /// The state now, or nil before the recording's first audio.
    private func makeSnapshot(sequence: Int) -> RecorderSnapshot? {
        guard let session, let course, let recordingID, let startedAt = session.startedAt else { return nil }
        let phase: RecorderSnapshot.Phase
        var failure: String?
        switch session.phase {
        case .ready, .starting: return nil
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .stopping: phase = .stopping
        case .finished: phase = .stopped
        case .failed(let reason):
            phase = .stopped
            failure = Self.text(for: reason)
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
            failure: failure
        )
    }

    /// The capture package's id (a preview has none and makes one up).
    private var recordingID: UUID? {
        #if DEBUG
        if isPreview { return previewRecordingID }
        #endif
        return session?.package?.id
    }

    private static func text(for failure: LiveLectureSession.Failure) -> String {
        switch failure {
        case .storage(let detail), .engine(let detail): detail
        case .notConsented, .microphoneDenied, .noInputDevice: String(describing: failure)
        }
    }
}
