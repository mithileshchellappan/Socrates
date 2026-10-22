import Foundation

/// What happened at a moment of a live lecture. String-backed so packages written by newer
/// builds still decode.
public struct LectureEventKind: RawRepresentable, Hashable, Sendable, Codable,
    ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Recording started; `page` is the slide on screen.
    public static let start: Self = "start"
    /// Recording stopped.
    public static let stop: Self = "stop"
    /// Advanced to the next slide (→ or Space).
    public static let slide: Self = "slide"
    /// Went back one slide (←).
    public static let back: Self = "back"
    /// Jumped to any slide (filmstrip).
    public static let jump: Self = "jump"
    /// The student flagged this moment (F), optionally with text.
    public static let flag: Self = "flag"
    /// Recording paused (iPhone): no audio until the next `resume`. `sampleTime` is the end of
    /// the audio written; `page` the slide on screen.
    public static let pause: Self = "pause"
    /// Recording went on after a pause. `sampleTime` is where the next audio sits on the clock:
    /// the pause's end plus the time paused, so the clock keeps real time across the gap.
    public static let resume: Self = "resume"

    /// True for events after which `page` is the slide on screen (a slide stamp).
    public var showsSlide: Bool {
        self == .start || self == .slide || self == .back || self == .jump
    }
}

/// One event on the recording clock, stamped three ways: frames on the recording clock
/// (`sampleTime`), `mach_absolute_time()` (`hostTime`) and wall clock.
public struct LectureEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var kind: LectureEventKind
    /// 1-based deck page on screen after the event (nil when there is no deck).
    public var page: Int?
    /// 1-based page on screen before a slide change.
    public var fromPage: Int?
    /// Flag text, if the student typed any.
    public var text: String?
    /// Frame position on the recording clock (sample 0 = first recorded frame).
    public var sampleTime: Int64?
    /// `mach_absolute_time()` when the key was pressed.
    public var hostTime: UInt64
    public var wallClock: Date

    public init(
        id: UUID = UUID(),
        kind: LectureEventKind,
        page: Int? = nil,
        fromPage: Int? = nil,
        text: String? = nil,
        sampleTime: Int64? = nil,
        hostTime: UInt64,
        wallClock: Date
    ) {
        self.id = id
        self.kind = kind
        self.page = page
        self.fromPage = fromPage
        self.text = text
        self.sampleTime = sampleTime
        self.hostTime = hostTime
        self.wallClock = wallClock
    }

    /// Seconds on the recording clock.
    public func time(sampleRate: Double) -> TimeInterval? {
        guard let sampleTime, sampleRate > 0 else { return nil }
        return Double(sampleTime) / sampleRate
    }
}

/// Contents of `events.json`.
public struct LectureEventLog: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var events: [LectureEvent]

    public init(version: Int = LectureEventLog.currentVersion, events: [LectureEvent]) {
        self.version = version
        self.events = events
    }
}
