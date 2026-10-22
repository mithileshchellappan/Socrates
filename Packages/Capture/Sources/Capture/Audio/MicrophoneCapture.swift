import AVFAudio
import Foundation

/// Records the default audio input into rolling segment files with `AVAudioEngine`.
///
/// - The input tap copies each buffer into an `AudioChunk` and fans it out; the writer task on
///   this actor writes it, so the audio thread never touches files.
/// - When the engine's configuration changes (input device switched, format changed) or an
///   interruption ends, the engine is rebuilt and a new segment starts: the previous segment
///   stays intact and the clock keeps following real time.
/// - A pause (iPhone) stops the engine, writes everything captured and closes the segment, and
///   remembers where it stopped on a clock that keeps counting while the phone sleeps
///   (`ContinuousClock`; the host clock stops then). Resume places the recording clock after
///   the real time paused and starts a new engine run, so the next audio opens a new segment
///   after the gap, as after an interruption.
/// - While recording, a `ProcessInfo` activity keeps the Mac from idle-sleeping.
/// - Nothing it starts keeps it alive: when its owner lets go without stopping, `deinit` stops
///   the engine and ends the activity (the package is then recovered like after a crash).
///
/// One instance records one lecture.
public actor MicrophoneCapture: AudioCaptureSource {
    private enum State { case idle, starting, recording, paused, stopped }

    /// Where a pause stopped: the first frame after the audio written, and when.
    private struct PauseMark {
        var endSample: Int64
        var at: ContinuousClock.Instant
    }

    public nonisolated let broadcaster = AudioBroadcaster()
    private nonisolated let status = AsyncStream.makeStream(of: CaptureStatus.self)

    private let host: HostClock
    private let tapBufferSize: AVAudioFrameCount
    private var state = State.idle
    private var engine: AVAudioEngine?
    private var writer: SegmentedAudioWriter?
    /// Set when writing audio failed; the writer keeps its segment list but gets no more audio.
    private var writerFailed = false
    private var run = 0
    private var firstHostTime: UInt64?
    private var writerTask: Task<Void, Never>?
    private var observerTasks: [Task<Void, Never>] = []
    private var activity: (any NSObjectProtocol)?
    private var pauseMark: PauseMark?
    /// Barriers sent by `pause()` and the last one the writer reached.
    private var barriersSent = 0
    private var barrierReached = 0
    /// Engine runs up to this one ended in a pause: audio of theirs still arriving is dropped
    /// (their segment is closed).
    private var sealedRun = 0

    public init(host: HostClock = .system, tapBufferSize: AVAudioFrameCount = 4096) {
        self.host = host
        self.tapBufferSize = tapBufferSize
    }

    isolated deinit {
        for task in observerTasks { task.cancel() }
        writerTask?.cancel()
        tearDownEngine()
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

        let chunks = broadcaster.subscribe()
        // Weak, so a capture its owner dropped without stopping is released (and stops in deinit).
        writerTask = Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                await self.write(chunk)
            }
        }

        let engineStart = host.now()
        clock.setAnchor(.init(sampleTime: 0, hostTime: engineStart))
        let inputFormat: AVAudioFormat
        do {
            inputFormat = try startEngine()
        } catch {
            // Nothing was written; leave the instance ready for another attempt.
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
        broadcaster.finish()
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
        guard state == .recording, let writer else { throw CaptureError.notRecording }
        state = .paused
        tearDownEngine()
        endActivity()

        // Everything the tap sent before the barrier is in the writer's queue ahead of it; once
        // the writer reaches it, all of it is on disk. Bounded, so a stuck writer never holds up
        // the commands behind this one.
        barriersSent += 1
        let barrier = barriersSent
        broadcaster.send(.barrier(barrier, run: run, sampleRate: writer.format.sampleRate))
        let deadline = ContinuousClock.now + .seconds(1)
        while barrierReached < barrier, ContinuousClock.now < deadline, state == .paused {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard state == .paused else { throw CaptureError.notRecording }
        if barrierReached < barrier {
            CaptureLog.capture.error("Pause: the writer did not catch up within 1 s; later audio of this run is dropped")
        }
        sealedRun = run

        var segments = writer.segments
        do {
            segments = try writer.finish(drainingConversion: !writerFailed)
        } catch {
            CaptureLog.capture.fault("Closing the segment at a pause failed: \(error.localizedDescription, privacy: .public)")
        }
        status.continuation.yield(.segmentsChanged(segments))
        let endSample = writer.endSample
        pauseMark = PauseMark(endSample: endSample, at: .now)
        CaptureLog.capture.info("Paused at sample \(endSample)")
        return CapturePause(endSample: endSample, segments: segments)
    }

    public func releaseInput() async {
        guard state == .paused else { return }
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
        #if os(iOS)
        // Fails during a phone call, or when iOS does not let a suspended app record: stay paused.
        try Self.activateAudioSession()
        #endif
        // The real time paused, also while the phone slept: the clock keeps wall time, so the
        // Mac files, plays and transcribes the gap as silence and later stamps stay in place.
        let paused = ContinuousClock.now - mark.at
        let pausedSeconds = Double(paused.components.seconds) + Double(paused.components.attoseconds) / 1e18
        let sampleTime = mark.endSample + Int64((pausedSeconds * writer.format.sampleRate).rounded())
        let hostTime = host.now()
        clock.setAnchor(.init(sampleTime: sampleTime, hostTime: hostTime))
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
        CaptureLog.capture.info("Resumed at sample \(sampleTime) after \(pausedSeconds, format: .fixed(precision: 1)) s")
        return CaptureResume(sampleTime: sampleTime, hostTime: hostTime)
    }

    // MARK: - Writing

    private func write(_ chunk: AudioChunk) {
        if let barrier = chunk.barrier {
            barrierReached = max(barrierReached, barrier)
            return
        }
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
            block: Self.makeTapBlock(run: run, broadcaster: broadcaster)
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
        guard state == .recording, isCurrentEngine(engineID), engine?.isRunning == false else { return }
        await restartEngine(reason: "configuration change")
    }

    #if os(iOS)
    private func handleInterruption(ended: Bool) async {
        guard state == .recording else { return }
        if ended {
            try? Self.activateAudioSession()
            await restartEngine(reason: "interruption ended")
        } else {
            tearDownEngine()
            status.continuation.yield(.inputLost)
        }
    }

    private static func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default, options: [])
        try session.setActive(true)
    }
    #endif

    /// The tap runs on an audio thread: it only copies the buffer and hands it on. Built in a
    /// nonisolated static context so the closure carries no actor isolation.
    private static func makeTapBlock(run: Int, broadcaster: AudioBroadcaster) -> AVAudioNodeTapBlock {
        { buffer, time in
            guard let chunk = AudioChunk(buffer: buffer, time: time, run: run) else { return }
            broadcaster.send(chunk)
        }
    }
}
