import Foundation

/// The recorder's state as every surface renders it: the recorder screen, the Live Activity and
/// later the Mac remote. The recorder is the only one that makes these; a surface keeps the
/// newest (`supersedes(_:)`) and computes nothing of its own beyond the elapsed time
/// (`timing.elapsed(at:)` on its own clock).
public struct RecorderSnapshot: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Hashable, Sendable {
        /// Capturing audio.
        case recording
        /// Nothing is captured until `resume`; the recording goes on after it.
        case paused
        /// Stop is closing the package.
        case stopping
        /// Final; nothing is accepted any more.
        case stopped
    }

    /// The course the recording is for.
    public struct Course: Codable, Hashable, Sendable {
        /// "Data Centers".
        public var name: String
        /// "DC".
        public var shortName: String
        /// "#0a84ff", for its dot.
        public var colorHex: String

        public init(name: String, shortName: String, colorHex: String) {
            self.name = name
            self.shortName = shortName
            self.colorHex = colorHex
        }
    }

    public var recordingID: RecordingID
    /// Counts up by one on every change of content and never goes back while the recorder runs,
    /// across its recordings (a recording taken up after a relaunch continues from what its Live
    /// Activity showed).
    public var sequence: Int
    public var phase: Phase
    public var timing: RecordingTiming
    /// The slide on screen, 1-based (counted from 1 when the phone has no deck).
    public var slide: Int
    /// The deck's pages when the phone has the deck; nil: slides counted without one.
    public var slideCount: Int?
    public var flagCount: Int
    /// False while the input is lost (an interruption, a phone call) during recording.
    public var isInputAvailable: Bool
    public var course: Course
    /// "DC Lecture 2"; the short name and the day without a known class.
    public var sessionName: String
    /// The commands the recorder takes now: a surface enables exactly these. Kinds a newer
    /// sender adds that this build does not know are dropped when decoding.
    public var accepts: Set<RecorderCommand.Kind>
    /// With `phase` stopped: why the recording stopped by itself (storage full, consent
    /// withdrawn); nil after Stop and while it runs.
    public var failure: RecorderFailure?
    /// The highest sequence among the recording's closed audio segments (0: none closed yet). A
    /// closed segment's file never changes again, so a reader may copy every segment up to it
    /// while the recording goes on. It bounds what is closed: a segment counts as closed once a
    /// higher one exists or its frame count is known, every segment once the recording paused or
    /// stopped, and a missing frame count never means "still open". It speaks only for the
    /// recording this snapshot is of; earlier packages are whole. Read as 0 from earlier builds.
    public var closedSegments: Int
    /// The `sequence` at which the current `phase` began: a command drawn from an older snapshot
    /// (`RecorderCommand.basis` below it) was decided against a phase that has ended since. Read as
    /// `sequence` from earlier builds.
    public var phaseSince: Int

    public init(
        recordingID: RecordingID,
        sequence: Int,
        phase: Phase,
        timing: RecordingTiming,
        slide: Int,
        slideCount: Int?,
        flagCount: Int,
        isInputAvailable: Bool,
        course: Course,
        sessionName: String,
        accepts: Set<RecorderCommand.Kind>,
        failure: RecorderFailure? = nil,
        closedSegments: Int = 0,
        phaseSince: Int? = nil
    ) {
        self.recordingID = recordingID
        self.sequence = sequence
        self.phase = phase
        self.timing = timing
        self.slide = slide
        self.slideCount = slideCount
        self.flagCount = flagCount
        self.isInputAvailable = isInputAvailable
        self.course = course
        self.sessionName = sessionName
        self.accepts = accepts
        self.failure = failure
        self.closedSegments = closedSegments
        self.phaseSince = phaseSince ?? sequence
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordingID = try container.decode(RecordingID.self, forKey: .recordingID)
        sequence = try container.decode(Int.self, forKey: .sequence)
        phase = try container.decode(Phase.self, forKey: .phase)
        timing = try container.decode(RecordingTiming.self, forKey: .timing)
        slide = try container.decode(Int.self, forKey: .slide)
        slideCount = try container.decodeIfPresent(Int.self, forKey: .slideCount)
        flagCount = try container.decode(Int.self, forKey: .flagCount)
        isInputAvailable = try container.decode(Bool.self, forKey: .isInputAvailable)
        course = try container.decode(Course.self, forKey: .course)
        sessionName = try container.decode(String.self, forKey: .sessionName)
        accepts = RecorderCommand.Kind.known(try container.decode([String].self, forKey: .accepts))
        failure = try container.decodeIfPresent(RecorderFailure.self, forKey: .failure)
        closedSegments = try container.decodeIfPresent(Int.self, forKey: .closedSegments) ?? 0
        phaseSince = try container.decodeIfPresent(Int.self, forKey: .phaseSince) ?? sequence
    }

    public var isPaused: Bool { phase == .paused }
    /// Not stopped: recording, paused or stopping.
    public var isLive: Bool { phase != .stopped }

    /// Whether this snapshot is newer than `other`, the one rule a receiver keeps: of one
    /// recording the higher sequence wins; of two recordings the one started later.
    public func supersedes(_ other: RecorderSnapshot?) -> Bool {
        guard let other else { return true }
        if recordingID == other.recordingID { return sequence > other.sequence }
        return timing.startedAt > other.timing.startedAt
    }
}
