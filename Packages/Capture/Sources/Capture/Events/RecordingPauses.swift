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
        /// Clock positions: where the pause sits (Pause stopped the input there), and where the
        /// audio went on.
        public var startSample: Int64?
        public var endSample: Int64?
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

    /// Seconds of the clock inside closed pauses, counting only the part before `endSample` (the
    /// end of the audio): a pause whose resume recorded nothing lies beyond the recording.
    public func gapSeconds(sampleRate: Double, through endSample: Int64) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        let frames = pauses.reduce(Int64(0)) { total, pause in
            guard let start = pause.startSample, let end = pause.endSample else { return total }
            return total + max(0, min(end, endSample) - start)
        }
        return Double(frames) / sampleRate
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
