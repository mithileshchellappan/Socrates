import Foundation

/// A recording's pauses (iPhone), read from its events: each `pause` up to the next `resume`;
/// the last one stays open when the recording stopped or ended while paused.
///
/// On the recording clock a closed pause is a gap without audio (the next segment starts after
/// it), because the clock keeps real time. Players and transcribers treat it as silence like any
/// other gap; what the student calls the recording's length leaves it out.
public struct RecordingPauses: Sendable, Hashable {
    public struct Pause: Sendable, Hashable {
        /// Wall clock of the pause and of the resume (nil: still paused, or never resumed).
        public var startedAt: Date
        public var endedAt: Date?
        /// Clock positions: where the audio stopped, and where it went on.
        public var startSample: Int64?
        public var endSample: Int64?

        /// Frames of the clock the pause spans; 0 while it is open or unplaced.
        public var gapFrames: Int64 {
            guard let startSample, let endSample else { return 0 }
            return max(0, endSample - startSample)
        }
    }

    /// Oldest first.
    public let pauses: [Pause]

    /// `events` in recording order (as a session keeps them and a package reader sorts them).
    public init(events: [LectureEvent]) {
        var pauses: [Pause] = []
        for event in events {
            if event.kind == .pause, pauses.last.map({ $0.endedAt != nil }) ?? true {
                pauses.append(Pause(startedAt: event.wallClock, startSample: event.sampleTime))
            } else if event.kind == .resume, let last = pauses.indices.last, pauses[last].endedAt == nil {
                pauses[last].endedAt = event.wallClock
                pauses[last].endSample = event.sampleTime
            }
        }
        self.pauses = pauses
    }

    /// The pause still open (the recording is paused, or ended while paused).
    public var open: Pause? {
        pauses.last.flatMap { $0.endedAt == nil ? $0 : nil }
    }

    /// Clock frames inside closed pauses up to `sample`.
    public func gapFrames(before sample: Int64) -> Int64 {
        pauses.reduce(0) { total, pause in
            guard let end = pause.endSample, end <= sample else { return total }
            return total + pause.gapFrames
        }
    }

    /// Seconds of the clock inside closed pauses.
    public func gapSeconds(sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(pauses.reduce(0) { $0 + $1.gapFrames }) / sampleRate
    }

    /// Wall-clock seconds paused from the pauses' starts up to `end` (an open pause counts up to
    /// `end`).
    public func pausedSeconds(until end: Date) -> TimeInterval {
        pauses.reduce(0) { total, pause in
            let until = min(pause.endedAt ?? end, end)
            return total + max(0, until.timeIntervalSince(pause.startedAt))
        }
    }
}
