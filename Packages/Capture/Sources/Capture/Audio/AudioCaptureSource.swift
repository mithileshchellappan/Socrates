import Foundation

public enum CaptureError: Error, Equatable, Sendable {
    case microphoneDenied
    case noInputDevice
    case alreadyRecording
    case notRecording
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
}
