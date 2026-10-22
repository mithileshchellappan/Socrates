import Foundation

/// A recording's time on the wall clock: when it started, its pauses and when it stopped. Each
/// receiver computes the elapsed time on its own clock from these dates, so nothing has to send
/// a ticking value.
public struct RecordingTiming: Codable, Hashable, Sendable {
    /// One pause; `end` is nil while it lasts (or when the recording stopped during it).
    public struct Pause: Codable, Hashable, Sendable {
        public var start: Date
        public var end: Date?

        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }
    }

    /// Wall clock at the recording's first sample.
    public var startedAt: Date
    /// Oldest first; only the last may be open.
    public var pauses: [Pause]
    /// Set once recording stopped: the time freezes there.
    public var stoppedAt: Date?

    public init(startedAt: Date, pauses: [Pause] = [], stoppedAt: Date? = nil) {
        self.startedAt = startedAt
        self.pauses = pauses
        self.stoppedAt = stoppedAt
    }

    /// The pause going on (or the one the recording stopped in).
    public var openPause: Pause? {
        pauses.last.flatMap { $0.end == nil ? $0 : nil }
    }

    /// Seconds recorded at `date`: the span from the start, without the pauses, frozen once
    /// stopped. The one definition of recorded time: the timer counts it, and a stamp's place on
    /// the recording is its wall clock read through it.
    public func elapsed(at date: Date) -> TimeInterval {
        let end = min(date, stoppedAt ?? date)
        let paused = pauses.reduce(0.0) { total, pause in
            total + max(0, min(pause.end ?? end, end).timeIntervalSince(pause.start))
        }
        return max(0, end.timeIntervalSince(startedAt) - paused)
    }

    /// Where a counting-up timer starts so that it shows the recorded time: the start moved on by
    /// every closed pause (`Text(timerInterval:pauseTime:)`).
    public var timerStart: Date {
        startedAt.addingTimeInterval(pauses.reduce(0.0) { total, pause in
            guard let end = pause.end else { return total }
            return total + max(0, end.timeIntervalSince(pause.start))
        })
    }

    /// Where that timer stands still: the open pause's start, else the stop; nil while it counts.
    public var timerPauseTime: Date? {
        openPause?.start ?? stoppedAt
    }
}
