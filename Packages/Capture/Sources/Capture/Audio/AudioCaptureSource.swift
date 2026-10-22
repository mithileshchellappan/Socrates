import Foundation

public enum CaptureError: Error, Equatable, Sendable {
    case microphoneDenied
    case noInputDevice
    case alreadyRecording
    case notRecording
    /// `resume()` without a pause.
    case notPaused
    case engineFailed(String)
}

/// Returned once audio is flowing: sample 0 of the recording clock is known.
public struct CaptureStart: Sendable {
    /// Maps host time to recording-clock frames for slide stamps.
    public var clock: RecordingClock
    /// `mach_absolute_time()` at sample 0.
    public var hostTimeAtStart: UInt64
    /// Wall clock at sample 0.
    public var startedAt: Date
    public var format: RecordingFormat
    public var device: AudioDeviceInfo?

    public init(clock: RecordingClock, hostTimeAtStart: UInt64, startedAt: Date, format: RecordingFormat, device: AudioDeviceInfo?) {
        self.clock = clock
        self.hostTimeAtStart = hostTimeAtStart
        self.startedAt = startedAt
        self.format = format
        self.device = device
    }
}

/// Returned by `pause()` once the input is off and everything recorded is on disk.
public struct CapturePause: Sendable {
    /// The first frame after the audio written: where the pause sits on the recording clock.
    public var endSample: Int64
    /// All segments, the last one closed.
    public var segments: [AudioSegmentInfo]

    public init(endSample: Int64, segments: [AudioSegmentInfo]) {
        self.endSample = endSample
        self.segments = segments
    }
}

/// Returned by `resume()` once the input runs again.
public struct CaptureResume: Sendable {
    /// Where the next audio sits on the recording clock: the pause's end plus the time paused.
    public var sampleTime: Int64
    /// `mach_absolute_time()` when the clock was placed there.
    public var hostTime: UInt64

    public init(sampleTime: Int64, hostTime: UInt64) {
        self.sampleTime = sampleTime
        self.hostTime = hostTime
    }
}

/// What a running capture reports while recording.
public enum CaptureStatus: Sendable, Equatable {
    /// Segments were opened or closed; persist them in the manifest.
    case segmentsChanged([AudioSegmentInfo])
    /// The input device changed (nil name: none available).
    case inputChanged(String?)
    /// Audio stopped arriving (interruption, no device); a new segment follows when it resumes.
    case inputLost
    /// Writing audio failed; the recording cannot continue.
    case failed(String)
}

/// A source of recorded audio for a live lecture. `MicrophoneCapture` records the default input;
/// tests use a fake.
public protocol AudioCaptureSource: AnyObject, Sendable {
    /// Asks for microphone access if needed. False when denied.
    func requestPermission() async -> Bool

    /// Starts recording segments into `directory`; returns once the first audio arrived.
    func start(
        in directory: URL,
        format: RecordingFormat,
        segmentDuration: Duration
    ) async throws -> CaptureStart

    /// Stops recording and closes the last segment. Returns all segments.
    func stop() async throws -> [AudioSegmentInfo]

    /// Status updates for the current recording; finishes when it stops.
    func statusUpdates() -> AsyncStream<CaptureStatus>

    /// Audio as it arrives (for meters and captions); finishes when recording stops.
    func audio(bufferingNewest limit: Int?) -> AsyncStream<AudioChunk>

    /// Pauses (iPhone): the input stops, everything recorded so far is written and the open
    /// segment closed. The input stays claimed until `releaseInput()`, so the caller can finish
    /// its own writes first. Throws `notRecording` unless recording.
    func pause() async throws -> CapturePause

    /// Gives the input up while paused (iOS: the audio session goes inactive, the microphone
    /// indicator goes out and the app may be suspended).
    func releaseInput() async

    /// Records again after `pause()` into the same recording: the clock is placed after the
    /// real time paused and the next audio opens a new segment there. On failure it stays
    /// paused.
    func resume() async throws -> CaptureResume
}

extension AudioCaptureSource {
    /// Sources that cannot pause (the Mac never does) refuse.
    public func pause() async throws -> CapturePause { throw CaptureError.notRecording }
    public func releaseInput() async {}
    public func resume() async throws -> CaptureResume { throw CaptureError.notPaused }
}
