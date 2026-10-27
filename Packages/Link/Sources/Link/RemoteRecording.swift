import Foundation
import RecorderContract

/// The phone's recording as the Mac shows it: the newest snapshot, whether the phone is still
/// reachable, and the elapsed time counted on the Mac's own clock from receipt.
public struct RemoteRecording: Hashable, Sendable {
    public enum Freshness: Hashable, Sendable {
        /// The connection is alive: the controls may work.
        case live
        /// The connection was lost at this moment: shown frozen and grey, the controls off.
        case lastSeen(Date)
    }

    public var snapshot: RecorderSnapshot
    public var freshness: Freshness
    /// Seconds recorded when the phone sent the snapshot (`SnapshotMessage.elapsed`).
    public var elapsedAtReceipt: TimeInterval
    /// Whether that time was counting (`SnapshotMessage.isRunning`).
    public var isRunning: Bool
    /// When the Mac received the snapshot, on the Mac's clock.
    public var receivedAt: Date

    public init(
        snapshot: RecorderSnapshot, freshness: Freshness, elapsedAtReceipt: TimeInterval, isRunning: Bool, receivedAt: Date
    ) {
        self.snapshot = snapshot
        self.freshness = freshness
        self.elapsedAtReceipt = elapsedAtReceipt
        self.isRunning = isRunning
        self.receivedAt = receivedAt
    }

    public var isLive: Bool { freshness == .live }

    /// Seconds recorded at `now` on the Mac's clock: the elapsed time at receipt, plus the time
    /// since while the recording runs and the phone is reachable. Frozen otherwise: paused or
    /// stopped at what the phone said, unreachable at the moment the connection was lost (it never
    /// counts a time it cannot confirm).
    public func elapsed(at now: Date) -> TimeInterval {
        guard isRunning else { return elapsedAtReceipt }
        let end: Date
        switch freshness {
        case .live: end = now
        case .lastSeen(let date): end = min(date, now)
        }
        return elapsedAtReceipt + max(0, end.timeIntervalSince(receivedAt))
    }
}
