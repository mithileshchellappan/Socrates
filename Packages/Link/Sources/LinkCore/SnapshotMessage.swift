import Foundation
import RecorderContract

/// The phone's recorder state, after its offers on connect and then on every change. The elapsed
/// time is computed on the phone when it sends; the Mac counts on from receipt on its own clock,
/// so the two devices' clocks are never compared.
public struct SnapshotMessage: Codable, Hashable, Sendable {
    /// Nil: nothing records (the Mac drops what it showed).
    public var snapshot: RecorderSnapshot?
    /// Seconds recorded when the phone sent this (`snapshot.timing.elapsed(at: now)`).
    public var elapsed: TimeInterval
    /// Whether that time is counting (recording, not paused or stopped).
    public var isRunning: Bool

    public init(snapshot: RecorderSnapshot?, elapsed: TimeInterval, isRunning: Bool) {
        self.snapshot = snapshot
        self.elapsed = elapsed
        self.isRunning = isRunning
    }

    /// The message for `snapshot` sent at `date`.
    public init(snapshot: RecorderSnapshot?, at date: Date) {
        self.snapshot = snapshot
        elapsed = snapshot?.timing.elapsed(at: date) ?? 0
        isRunning = snapshot?.phase == .recording
    }
}
