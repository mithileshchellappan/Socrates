import Foundation

/// The recorder's state as every surface renders it: the recorder screen, the Live Activity and
/// later the Mac remote. The recorder is the only one that makes these; a surface keeps the one
/// with the highest `sequence` and computes nothing of its own beyond the elapsed time
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

    /// The recording (= the capture package's id).
    public var recordingID: UUID
    /// One more on every change of content, from 1 for each recording: a surface that receives
    /// two keeps the higher.
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
    /// The commands the recorder takes now (`RecorderMachine.accepts`): a surface enables exactly
    /// these.
    public var accepts: Set<RecorderCommand.Kind>
    /// Why the recording stopped by itself (storage full, consent withdrawn); nil after Stop.
    public var failure: String?

    public init(
        recordingID: UUID,
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
        failure: String? = nil
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
    }

    public var isPaused: Bool { phase == .paused }
}
