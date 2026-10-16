import Darwin
import Foundation
import Synchronization

/// The host clock (`mach_absolute_time()`), injectable so tests control time.
public struct HostClock: Sendable {
    /// Current host time in ticks.
    public var now: @Sendable () -> UInt64
    /// Seconds per tick.
    public var secondsPerTick: Double

    public init(secondsPerTick: Double, now: @escaping @Sendable () -> UInt64) {
        self.secondsPerTick = secondsPerTick
        self.now = now
    }

    /// `mach_absolute_time()` with the machine's timebase.
    public static let system: HostClock = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let secondsPerTick = info.denom == 0 ? 1e-9 : Double(info.numer) / Double(info.denom) / 1e9
        return HostClock(secondsPerTick: secondsPerTick, now: { mach_absolute_time() })
    }()

    /// Signed seconds from `start` to `end`.
    public func seconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start
            ? Double(end - start) * secondsPerTick
            : -Double(start - end) * secondsPerTick
    }

    /// Ticks in `seconds` (non-negative).
    public func ticks(forSeconds seconds: Double) -> UInt64 {
        guard seconds > 0, secondsPerTick > 0 else { return 0 }
        return UInt64((seconds / secondsPerTick).rounded())
    }
}

/// Maps host time to frames on a recording clock (sample 0 = the first recorded frame).
///
/// The audio writer moves the anchor forward with every buffer it writes ("frame N was
/// captured at host time H"); a slide stamp then lands at
/// `N + (stampHostTime - H) × sampleRate`. Reading is lock-protected and synchronous, so the
/// UI can stamp a key press without hopping to the audio actor.
public final class RecordingClock: Sendable {
    public struct Anchor: Sendable, Hashable {
        public var sampleTime: Int64
        public var hostTime: UInt64

        public init(sampleTime: Int64, hostTime: UInt64) {
            self.sampleTime = sampleTime
            self.hostTime = hostTime
        }
    }

    public let sampleRate: Double
    public let host: HostClock
    private let state = Mutex<Anchor?>(nil)

    public init(sampleRate: Double, host: HostClock = .system, anchor: Anchor? = nil) {
        self.sampleRate = sampleRate
        self.host = host
        state.withLock { $0 = anchor }
    }

    public var anchor: Anchor? {
        state.withLock { $0 }
    }

    public func setAnchor(_ anchor: Anchor) {
        state.withLock { $0 = anchor }
    }

    /// Frame on the recording clock at `hostTime`, never negative; nil before any anchor.
    public func sampleTime(atHostTime hostTime: UInt64) -> Int64? {
        guard let anchor else { return nil }
        let delta = host.seconds(from: anchor.hostTime, to: hostTime)
        return max(0, anchor.sampleTime + Int64((delta * sampleRate).rounded()))
    }

    /// Frame on the recording clock now.
    public func currentSampleTime() -> Int64? {
        sampleTime(atHostTime: host.now())
    }

    /// Seconds for a frame position.
    public func seconds(forSample sample: Int64) -> TimeInterval {
        sampleRate > 0 ? Double(sample) / sampleRate : 0
    }
}
