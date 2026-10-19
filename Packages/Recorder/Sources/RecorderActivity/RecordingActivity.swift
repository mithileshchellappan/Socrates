import Foundation
#if os(iOS)
import ActivityKit
#endif

// The recording's Live Activity (M7, docs/plan-m7.md §3–4, PRD "iPhone recording"): the Lock
// Screen and the Dynamic Island show the course, the session, the slide on screen and the elapsed
// time, with exactly two buttons, Next Slide and Stop Recording. The app (`PhoneRecorder`) starts,
// updates and ends it; the widget extension draws it; the buttons' intents (`Widgets/Shared/`,
// compiled into both) run in the app's process and reach the recorder through `RecorderControl`.

/// What the Live Activity shows; platform-neutral, so its views also draw off screen.
public struct RecordingActivityState: Codable, Hashable, Sendable {
    /// "Data Centers".
    public var courseName: String
    /// The course's colour ("#0a84ff"), for its dot.
    public var courseColorHex: String
    /// "DC Lecture 2"; the course's short name and the day when the phone knows no session.
    public var sessionName: String
    /// The slide on screen, 1-based (counted from 1 when the phone has no deck).
    public var slide: Int
    /// The deck's pages when the phone has the deck ("Slide 17 of 88"); nil: "Slide 17".
    public var slideCount: Int?
    /// Wall clock of the recording's start; the elapsed time counts from here by itself.
    public var startedAt: Date
    /// Set once recording stopped: the time freezes there.
    public var stoppedAt: Date?

    public init(
        courseName: String,
        courseColorHex: String,
        sessionName: String,
        slide: Int,
        slideCount: Int? = nil,
        startedAt: Date,
        stoppedAt: Date? = nil
    ) {
        self.courseName = courseName
        self.courseColorHex = courseColorHex
        self.sessionName = sessionName
        self.slide = slide
        self.slideCount = slideCount
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
    }
}

#if os(iOS)
/// The recording's Live Activity (`Activity<RecordingActivityAttributes>`).
public struct RecordingActivityAttributes: ActivityAttributes {
    public typealias ContentState = RecordingActivityState

    /// The recording it was started for (= the capture package's id): a button of an old
    /// activity never acts on a newer recording.
    public var recordingID: UUID

    public init(recordingID: UUID) {
        self.recordingID = recordingID
    }
}
#endif

/// What a Live Activity button asks the recorder to do.
public enum RecorderCommand: String, Codable, Hashable, Sendable {
    /// Stamps the next slide on the recording clock (→ on the Mac).
    case nextSlide
    /// Stops recording at once (a Lock Screen button cannot ask first; the package is final).
    case stop
}

/// The bridge from the Live Activity's intents to the app's recorder. The app's `PhoneRecorder`
/// sets `handler` at launch (`activate()`), before any scene, so a button that launches the app
/// in the background finds it; the intents call `perform` in the app's process.
@MainActor
public enum RecorderControl {
    /// Runs a command for the recording `recordingID`; nil until the recorder is active.
    public static var handler: (@MainActor (RecorderCommand, UUID) async -> Void)?

    public static func perform(_ command: RecorderCommand, recordingID: UUID) async {
        await handler?(command, recordingID)
    }
}
