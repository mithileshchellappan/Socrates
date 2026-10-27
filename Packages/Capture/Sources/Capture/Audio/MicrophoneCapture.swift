import AVFAudio
import Foundation

/// Records the default audio input into rolling segment files with `AVAudioEngine`.
///
/// - The input tap copies each buffer into an `AudioChunk` and hands it to the writer's own
///   queue and to the fan-out for meters and captions; the writer task on this actor writes it,
///   so the audio thread never touches files.
/// - When the engine's configuration changes (input device switched, format changed) or an
///   interruption ends, the engine is rebuilt and a new segment starts: the previous segment
///   stays intact and the clock keeps following real time.
/// - A pause (iPhone) stops the engine, writes everything captured and closes the segment. It
///   sits on the recording clock where Pause stopped the input (the clock runs on through an
///   input outage before it, as it does for any interruption), and it remembers when on a clock
///   that keeps counting while the phone sleeps (`ContinuousClock`; the host clock stops then).
///   Resume places the recording clock after the real time paused and starts a new engine run,
///   so the next audio opens a new segment after the gap, as after an interruption.
/// - A pause the Mac may end (`holdInput()`) keeps the input open on an engine of its own whose
///   tap drops every buffer: nothing is written or sent to meters, and iOS keeps the app running,
///   because iOS does not let a backgrounded app start recording. A route change or an ended
///   interruption makes that engine again.
/// - A recording an earlier run left paused (the app was killed meanwhile) can be taken up
///   (`reopen(_:)`) and resumed into the same folder.
/// - While recording, a `ProcessInfo` activity keeps the Mac from idle-sleeping.
/// - Nothing it starts keeps it alive: when its owner lets go without stopping, `deinit` stops
///   the engine and ends the activity (the package is then recovered like after a crash).
///
/// One instance records one lecture.
public actor MicrophoneCapture: AudioCaptureSource {
    private enum State { case idle, starting, recording, paused, stopped }

    /// What the writer's queue carries, in the order it was sent: audio from the tap, or a
    /// pause's barrier (once the writer reaches it, everything sent before it is on disk).
    private enum WriterInput: Sendable {
        case audio(AudioChunk)
        case barrier(Int)
    }

    /// Where a pause sits on the recording clock, and when it began on the continuous clock.
    private struct PauseMark {
        var sampleTime: Int64
        var at: ContinuousClock.Instant
    }

    /// A pause waiting for the writer to reach its barrier.
    private struct BarrierWaiter {
        var barrier: Int
        var continuation: CheckedContinuation<Void, Never>
    }

    public nonisolated let broadcaster = AudioBroadcaster()
    private nonisolated let status = AsyncStream.makeStream(of: CaptureStatus.self)

    private let host: HostClock
    private let tapBufferSize: AVAudioFrameCount
    private var state = State.idle
    private var engine: AVAudioEngine?
    /// The engine holding the input through a pause (`holdInput()`); nil: none.
    private var holdEngine: AVAudioEngine?
    private var writer: SegmentedAudioWriter?
    /// The writer task's queue (nil before start and after stop).
    private var writerInput: AsyncStream<WriterInput>.Continuation?
    /// Set when writing audio failed; the writer keeps its segment list but gets no more audio.
    private var writerFailed = false
    private var run = 0
    private var firstHostTime: UInt64?
    private var writerTask: Task<Void, Never>?
    private var observerTasks: [Task<Void, Never>] = []
    private var activity: (any NSObjectProtocol)?
    private var pauseMark: PauseMark?
    /// Barriers sent by `pause()`, the last one the writer reached, and the pause waiting for one.
    private var barriersSent = 0
    private var barrierReached = 0
    private var barrierWaiter: BarrierWaiter?
    /// Engine runs up to this one ended in a pause: audio of theirs still arriving is dropped
    /// (their segment is closed).
    private var sealedRun = 0

    public init(host: HostClock = .system, tapBufferSize: AVAudioFrameCount = 4096) {
        self.host = host
        self.tapBufferSize = tapBufferSize
    }

    isolated deinit {
        for task in observerTasks { task.cancel() }
        writerInput?.finish()
        writerTask?.cancel()
        tearDownEngine()
        endHold()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        broadcaster.finish()
        status.continuation.finish()
    }

    public nonisolated func requestPermission() async -> Bool {
        await AudioInput.requestPermission()
    }

    public nonisolated func statusUpdates() -> AsyncStream<CaptureStatus> {
        status.stream
    }

    public nonisolated func audio(bufferingNewest limit: Int?) -> AsyncStream<AudioChunk> {
        broadcaster.subscribe(bufferingPolicy: limit.map { .bufferingNewest($0) } ?? .unbounded)
    }

    public func start(in directory: URL, format: RecordingFormat, segmentDuration: Duration) async throws -> CaptureStart {
        guard state == .idle else { throw CaptureError.alreadyRecording }
        state = .starting
        guard await AudioInput.requestPermission() else {
            state = .idle
            throw CaptureError.microphoneDenied
        }

        let clock = RecordingClock(sampleRate: format.sampleRate, host: host)
        let writer: SegmentedAudioWriter
        do {
            #if os(iOS)
            try Self.activateAudioSession()
            #endif
            writer = try SegmentedAudioWriter(
                directory: directory,
                format: format,
                segmentFrames: format.frames(in: segmentDuration),
                clock: clock
            )
        } catch {
            state = .idle
            throw error
        }
        var device = AudioInput.currentDevice()
        writer.deviceName = device?.name
        self.writer = writer
        startWriting()

        let engineStart = host.now()
        clock.setAnchor(.init(sampleTime: 0, hostTime: engineStart))
        let inputFormat: AVAudioFormat
        do {
            inputFormat = try startEngine()
        } catch {
            // Nothing was written; leave the instance ready for another attempt.
            writerInput?.finish()
            writerInput = nil
            writerTask?.cancel()
            await writerTask?.value
            writerTask = nil
            self.writer = nil
            writerFailed = false
            state = .idle
            throw error
        }
        device?.nativeSampleRate = inputFormat.sampleRate
        device?.nativeChannelCount = Int(inputFormat.channelCount)
        state = .recording
        beginActivity()
        observerTasks = makeObservers()

        // Sample 0 is the first frame that reaches the writer; wait briefly for it.
        let deadline = engineStart &+ host.ticks(forSeconds: 3)
        while firstHostTime == nil, host.now() < deadline, state == .recording {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let hostTimeAtStart = firstHostTime ?? engineStart
        let startedAt = Date().addingTimeInterval(-host.seconds(from: hostTimeAtStart, to: host.now()))
        if firstHostTime == nil {
            CaptureLog.capture.error("No audio within 3 s of starting the engine")
        }
        return CaptureStart(
            clock: clock,
            hostTimeAtStart: hostTimeAtStart,
            startedAt: startedAt,
            format: format,
            device: device
        )
    }

    public func stop() async throws -> [AudioSegmentInfo] {
        guard state == .recording || state == .starting || state == .paused else { throw CaptureError.notRecording }
        state = .stopped
        pauseMark = nil
        for task in observerTasks { task.cancel() }
        observerTasks = []
        tearDownEngine()
        endHold()
        broadcaster.finish()
        writerInput?.finish()
        writerInput = nil
        await writerTask?.value
        writerTask = nil
        endActivity()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

        // Closing the last file can fail (disk full); the files on disk stay readable and the
        // package reader recovers their lengths, so report what is known and carry on.
        var segments = writer?.segments ?? []
        do {
            segments = try writer?.finish(drainingConversion: !writerFailed) ?? segments
        } catch {
            CaptureLog.capture.fault("Closing the last segment failed: \(error.localizedDescription, privacy: .public)")
        }
        if writerFailed, let last = segments.indices.last {
            // A failed write may have left a different number of frames in the file than
            // counted; without a count the package reader measures the file.
            segments[last].frameCount = nil
        }
        status.continuation.yield(.segmentsChanged(segments))
        status.continuation.finish()
        return segments
    }

    // MARK: - Pause

    public func pause() async throws -> CapturePause {
        guard state == .recording, let writer, let writerInput else { throw CaptureError.notRecording }
        state = .paused
        // The pause sits where Pause stopped the input: read the clock now, before waiting for
        // the writer, so neither that wait nor an input outage before the pause (an interruption
        // iOS never ended) goes missing from the clock.
        let stoppedHostTime = host.now()
        let stoppedAt = ContinuousClock.now
        tearDownEngine()
        endActivity()

        // Everything the tap sent before the barrier is in the writer's queue ahead of it; once
        // the writer reaches it, all of it is on disk. Bounded, so a stuck writer never holds up
        // the commands behind this one.
        barriersSent += 1
        let barrier = barriersSent
        writerInput.yield(.barrier(barrier))
        let drained = await waitForWriter(through: barrier, timeout: .seconds(1))
        guard state == .paused else { throw CaptureError.notRecording }
        if !drained {
            CaptureLog.capture.error("Pause: the writer did not catch up within 1 s; later audio of this run is dropped")
        }
        sealedRun = run

        var segments = writer.segments
        do {
            segments = try writer.finish(drainingConversion: !writerFailed)
        } catch {
            CaptureLog.capture.fault("Closing the segment at a pause failed: \(error.localizedDescription, privacy: .public)")
        }
        if writerFailed, let last = segments.indices.last {
            // As at Stop: without a count the package reader measures the file.
            segments[last].frameCount = nil
        }
        status.continuation.yield(.segmentsChanged(segments))
        let audioEnd = writer.endSample
        let byClock = writer.clock?.sampleTime(atHostTime: stoppedHostTime) ?? audioEnd
        let sampleTime = max(audioEnd, byClock)
        pauseMark = PauseMark(sampleTime: sampleTime, at: stoppedAt)
        CaptureLog.capture.info("Paused at sample \(sampleTime) (audio ends at \(audioEnd))")
        return CapturePause(sampleTime: sampleTime, audioEnd: audioEnd, segments: segments)
    }

    public func holdInput() async -> Bool {
        guard state == .paused else { return false }
        guard holdEngine == nil else { return true }
        do {
            try startHold()
        } catch {
            CaptureLog.capture.notice("Holding the input through the pause failed: \(String(describing: error), privacy: .public)")
            return false
        }
        CaptureLog.capture.info("Holding the input through the pause")
        return true
    }

    public func releaseInput() async {
        guard state == .paused else { return }
        endHold()
        #if os(iOS)
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            CaptureLog.capture.error("Releasing the audio session failed: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    public func resume() async throws -> CaptureResume {
        guard state == .paused, let writer, let clock = writer.clock, let mark = pauseMark else {
            throw CaptureError.notPaused
        }
        // Audio that cannot be written must not look recorded: stay paused.
        guard !writerFailed else { throw CaptureError.writeFailed }
        #if os(iOS)
        // Fails during a phone call, or when iOS does not let a suspended app record: stay paused
        // (a held input stays held).
        try Self.activateAudioSession()
        #endif
        // The input is claimed: the engine that held it gives way to the one that records.
        endHold()
        // The real time paused, also while the phone slept: the clock keeps wall time, so the
        // Mac files, plays and transcribes the gap as silence and later stamps stay in place.
        let paused = ContinuousClock.now - mark.at
        let sampleTime = mark.sampleTime + writer.format.frames(in: paused)
        let hostTime = host.now()
        clock.setAnchor(.init(sampleTime: sampleTime, hostTime: hostTime))
        writer.nextSegmentFloor = sampleTime
        do {
            try startEngine()
        } catch {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            throw error
        }
        state = .recording
        pauseMark = nil
        beginActivity()
        let device = AudioInput.currentDevice()
        writer.deviceName = device?.name
        status.continuation.yield(.inputChanged(device?.name))
        CaptureLog.capture.info("Resumed at sample \(sampleTime) after \(paused.components.seconds) s")
        return CaptureResume(sampleTime: sampleTime, hostTime: hostTime)
    }

    public func reopen(_ paused: PausedRecording) async throws -> RecordingClock {
        guard state == .idle else { throw CaptureError.alreadyRecording }
        let clock = RecordingClock(sampleRate: paused.format.sampleRate, host: host)
        let writer = try SegmentedAudioWriter(
            directory: paused.directory,
            format: paused.format,
            segmentFrames: paused.format.frames(in: paused.segmentDuration),
            clock: clock,
            continuing: paused.segments
        )
        self.writer = writer
        startWriting()
        // The run that paused is gone and its continuous-clock instant with it: the wall clock
        // measures the time paused so far.
        let pausedFor = max(0, Date().timeIntervalSince(paused.pausedAt))
        pauseMark = PauseMark(sampleTime: paused.sampleTime, at: ContinuousClock.now - .seconds(pausedFor))
        state = .paused
        observerTasks = makeObservers()
        CaptureLog.capture.info("Reopened a paused recording at sample \(paused.sampleTime)")
        return clock
    }

    // MARK: - Writing

    /// Starts the writer task on a new queue.
    private func startWriting() {
        let (inputs, continuation) = AsyncStream.makeStream(of: WriterInput.self)
        writerInput = continuation
        // Weak, so a capture its owner dropped without stopping is released (and stops in deinit).
        writerTask = Task { [weak self] in
            for await input in inputs {
                guard let self else { return }
                await self.write(input)
            }
        }
    }

    private func write(_ input: WriterInput) {
        switch input {
        case .barrier(let barrier):
            barrierReached = max(barrierReached, barrier)
            if let waiter = barrierWaiter, waiter.barrier <= barrierReached {
                barrierWaiter = nil
                waiter.continuation.resume()
            }
        case .audio(let chunk):
            write(chunk)
        }
    }

    private func write(_ chunk: AudioChunk) {
        guard let writer, !writerFailed, chunk.run > sealedRun else { return }
        if firstHostTime == nil {
            firstHostTime = chunk.hostTime ?? host.now()
        }
        do {
            if try writer.append(chunk) {
                status.continuation.yield(.segmentsChanged(writer.segments))
            }
        } catch {
            CaptureLog.capture.fault("Writing audio failed: \(error.localizedDescription, privacy: .public)")
            status.continuation.yield(.failed(error.localizedDescription))
            // Keep the writer: its segments (with their places on the clock) still describe
            // the files, and `stop()` closes the open one.
            writerFailed = true
        }
    }

    /// Waits until the writer reached `barrier`, at most `timeout` (less when the caller is
    /// cancelled). True when it did.
    private func waitForWriter(through barrier: Int, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled: the waiter below was resumed, or the caller was cancelled.
                }
                await self?.stopWaiting(for: barrier)
            }
            await withCheckedContinuation { continuation in
                if barrierReached >= barrier {
                    continuation.resume()
                } else {
                    barrierWaiter = BarrierWaiter(barrier: barrier, continuation: continuation)
                }
            }
            group.cancelAll()
        }
        return barrierReached >= barrier
    }

    private func stopWaiting(for barrier: Int) {
        guard let waiter = barrierWaiter, waiter.barrier == barrier else { return }
        barrierWaiter = nil
        waiter.continuation.resume()
    }

    // MARK: - Engine

    @discardableResult
    private func startEngine() throws -> AVAudioFormat {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        run += 1
        input.installTap(
            onBus: 0,
            bufferSize: tapBufferSize,
            format: format,
            block: Self.makeTapBlock(run: run, writer: writerInput, broadcaster: broadcaster)
        )
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        CaptureLog.capture.info(
            "Engine run \(self.run) started: \(format.sampleRate) Hz, \(format.channelCount) ch"
        )
        return format
    }

    private func beginActivity() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recording a lecture"
        )
    }

    private func endActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    private func tearDownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Claims the input while paused (iOS: the audio session, still active after a pause) and
    /// runs an engine whose tap drops every buffer. When it throws, no engine runs and the audio
    /// session is as it was: `releaseInput()` gives it up.
    private func startHold() throws {
        #if os(iOS)
        try Self.activateAudioSession()
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noInputDevice }
        input.installTap(onBus: 0, bufferSize: tapBufferSize, format: format, block: Self.makeDiscardingTapBlock())
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineFailed(error.localizedDescription)
        }
        holdEngine = engine
    }

    /// Stops the engine holding the input, if any (the audio session stays as it is).
    private func endHold() {
        guard let holdEngine else { return }
        holdEngine.inputNode.removeTap(onBus: 0)
        holdEngine.stop()
        self.holdEngine = nil
    }

    /// Makes the holding engine again after the system stopped it (a route change, an ended
    /// interruption). If it cannot, the input is released, as after a pause never held.
    private func rehold(reason: String) async {
        guard state == .paused, holdEngine != nil else { return }
        endHold()
        do {
            try startHold()
            CaptureLog.capture.notice("Holding the input again: \(reason, privacy: .public)")
        } catch {
            CaptureLog.capture.notice("The input is no longer held (\(reason, privacy: .public)): \(String(describing: error), privacy: .public)")
            await releaseInput()
        }
    }

    /// Rebuilds the engine after a configuration change or interruption. Retries until audio
    /// flows again or recording stops; the writer starts a new segment on the next chunk.
    private func restartEngine(reason: String) async {
        guard state == .recording else { return }
        CaptureLog.capture.notice("Restarting audio engine: \(reason, privacy: .public)")
        tearDownEngine()
        status.continuation.yield(.inputLost)
        var delay = Duration.milliseconds(100)
        while state == .recording, engine == nil {
            do {
                try startEngine()
                let device = AudioInput.currentDevice()
                writer?.deviceName = device?.name
                status.continuation.yield(.inputChanged(device?.name))
                return
            } catch {
                CaptureLog.capture.error("Engine restart failed: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(2))
            }
        }
    }

    private func isCurrentEngine(_ object: ObjectIdentifier?) -> Bool {
        guard let engine, let object else { return false }
        return ObjectIdentifier(engine) == object
    }

    private func makeObservers() -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        let configurationChanges = NotificationCenter.default
            .notifications(named: .AVAudioEngineConfigurationChange)
            .map { ($0.object as AnyObject?).map(ObjectIdentifier.init) }
        tasks.append(Task { [weak self] in
            for await engineID in configurationChanges {
                guard let self else { return }
                await self.handleConfigurationChange(engineID)
            }
        })
        #if os(iOS)
        let interruptions = NotificationCenter.default
            .notifications(named: AVAudioSession.interruptionNotification)
            .map { notification -> Bool in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                return raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
            }
        tasks.append(Task { [weak self] in
            for await ended in interruptions {
                guard let self else { return }
                await self.handleInterruption(ended: ended)
            }
        })
        #endif
        return tasks
    }

    private func handleConfigurationChange(_ engineID: ObjectIdentifier?) async {
        // The engine stops itself when the hardware changes; a change it survived needs nothing.
        if state == .paused, let holdEngine, ObjectIdentifier(holdEngine) == engineID, !holdEngine.isRunning {
            await rehold(reason: "configuration change")
            return
        }
        guard state == .recording, isCurrentEngine(engineID), engine?.isRunning == false else { return }
        await restartEngine(reason: "configuration change")
    }

    #if os(iOS)
    private func handleInterruption(ended: Bool) async {
        // A held pause: the interruption stopped the holding engine; it is made again after.
        if state == .paused {
            if ended { await rehold(reason: "interruption ended") }
            return
        }
        guard state == .recording else { return }
        if ended {
            try? Self.activateAudioSession()
            await restartEngine(reason: "interruption ended")
        } else {
            tearDownEngine()
            status.continuation.yield(.inputLost)
        }
    }

    /// Claims the input. A call, another app holding the input or iOS not letting the app record
    /// now is `inputBusy` (try again later); anything else is an engine failure.
    private static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            CaptureLog.capture.error("Audio session not active: \(String(describing: error), privacy: .public)")
            let busy: [AVAudioSession.ErrorCode] = [.isBusy, .cannotInterruptOthers, .insufficientPriority, .cannotStartRecording, .siriIsRecording]
            let code = (error as NSError).code
            if busy.contains(where: { $0.rawValue == code }) { throw CaptureError.inputBusy }
            throw CaptureError.engineFailed(error.localizedDescription)
        }
    }
    #endif

    /// The tap runs on an audio thread: it only copies the buffer and hands it to the writer's
    /// queue and the fan-out. Built in a nonisolated static context so the closure carries no
    /// actor isolation.
    private static func makeTapBlock(
        run: Int, writer: AsyncStream<WriterInput>.Continuation?, broadcaster: AudioBroadcaster
    ) -> AVAudioNodeTapBlock {
        { buffer, time in
            guard let chunk = AudioChunk(buffer: buffer, time: time, run: run) else { return }
            writer?.yield(.audio(chunk))
            broadcaster.send(chunk)
        }
    }

    /// The holding engine's tap: drops every buffer (built without actor isolation, as above).
    private static func makeDiscardingTapBlock() -> AVAudioNodeTapBlock {
        { _, _ in }
    }
}
