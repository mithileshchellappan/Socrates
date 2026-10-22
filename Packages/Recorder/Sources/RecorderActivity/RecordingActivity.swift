import Foundation
import RecorderContract
#if os(iOS)
import ActivityKit
#endif

// The recording's Live Activity (M7, docs/plan-m7.md §3–4, PRD "iPhone recording"): the Lock
// Screen and the Dynamic Island show the course, the session, the slide on screen and the elapsed
// time, with Pause/Resume, Next Slide and Stop Recording. The app (`PhoneRecorder`) starts,
// updates and ends it from its snapshot; the widget extension draws it; the buttons' intents
// (`Widgets/Shared/`, compiled into both) run in the app's process and send `RecorderCommand`s
// through `RecorderControl`.

/// What the Live Activity shows: a fixed-size projection of a `RecorderSnapshot` (ActivityKit
/// caps the content at 4 KB, so the pause list stays in the snapshot). Platform-neutral, so its
/// views also draw off screen.
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
    public var isPaused: Bool
    /// The elapsed time counts up from here by itself (the start moved on by the closed pauses).
    public var timerStart: Date
    /// The time stands still here (paused or stopped); nil while it counts.
    public var timerPauseTime: Date?
    /// What the buttons may send (`RecorderSnapshot.accepts`).
    public var accepts: Set<RecorderCommand.Kind>
    /// The snapshot this was drawn from: the buttons' commands carry it, so one rendering acts
    /// once (`RecorderCommand.rendered`).
    public var sequence: Int

    public init(
        courseName: String,
        courseColorHex: String,
        sessionName: String,
        slide: Int,
        slideCount: Int? = nil,
        isPaused: Bool = false,
        timerStart: Date,
        timerPauseTime: Date? = nil,
        accepts: Set<RecorderCommand.Kind>,
        sequence: Int
    ) {
        self.courseName = courseName
        self.courseColorHex = courseColorHex
        self.sessionName = sessionName
        self.slide = slide
        self.slideCount = slideCount
        self.isPaused = isPaused
        self.timerStart = timerStart
        self.timerPauseTime = timerPauseTime
        self.accepts = accepts
        self.sequence = sequence
    }

    public init(snapshot: RecorderSnapshot) {
        self.init(
            courseName: snapshot.course.name,
            courseColorHex: snapshot.course.colorHex,
            sessionName: snapshot.sessionName,
            slide: snapshot.slide,
            slideCount: snapshot.slideCount,
            isPaused: snapshot.isPaused,
            timerStart: snapshot.timing.timerStart,
            timerPauseTime: snapshot.timing.timerPauseTime,
            accepts: snapshot.accepts,
            sequence: snapshot.sequence
        )
    }
}

extension RecordingActivityState {
    /// "Slide 17 of 88"; "Slide 17" without the deck.
    public var slideText: String {
        if let slideCount { return String(localized: "Slide \(slide) of \(slideCount)") }
        return String(localized: "Slide \(slide)")
    }

    /// "Slide 17 of 88 · DC Lecture 2" (while paused the views lead with "Paused" instead of the
    /// session).
    public var detailLine: String {
        sessionName.isEmpty ? slideText : "\(slideText) · \(sessionName)"
    }

    /// "S17" (the Dynamic Island's compact trailing side).
    public var shortSlide: String { "S\(slide)" }

    /// The elapsed time's range for `Text(timerInterval:pauseTime:countsDown:)`: it counts up
    /// from `timerStart` by itself (no updates) and stands still at `timerPauseTime`.
    public var timerRange: ClosedRange<Date> {
        let upper = timerStart.addingTimeInterval(12 * 3600)
        return timerStart...max(upper, timerPauseTime ?? upper)
    }

    /// The same content, whatever snapshot it was drawn from: an update that changes only the
    /// sequence is not worth waking the Lock Screen for.
    public func showsSame(as other: RecordingActivityState?) -> Bool {
        guard var other else { return false }
        other.sequence = sequence
        return other == self
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

/// The bridge from the Live Activity's intents to the app's recorder. The app's `PhoneRecorder`
/// sets `handler` at launch (`activate()`), before any scene, so a button that launches the app
/// in the background finds it; the intents call `perform` in the app's process.
@MainActor
public enum RecorderControl {
    /// Runs a command through the recorder (`PhoneRecorder.perform`); nil until it is active.
    public static var handler: (@MainActor (RecorderCommand) async -> RecorderOutcome)?

    @discardableResult
    public static func perform(_ command: RecorderCommand) async -> RecorderOutcome? {
        await handler?(command)
    }
}
