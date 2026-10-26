import Foundation
import RecorderContract

/// Something the student should see on the recorder screen (`PhoneRecorder.problem`): Record
/// that could not start, a recording that stopped by itself, or a command from the screen or the
/// Live Activity that failed (a Resume tapped on the Lock Screen during a call shows when the app
/// opens). A remote command's failure is not one: the Mac shows it. The model keeps it until the
/// screen dismisses it; the screen picks the words.
public struct RecorderProblem: Identifiable, Hashable, Sendable {
    /// When it happened.
    public enum Moment: Hashable, Sendable {
        /// Record could not start; nothing was recorded.
        case start
        /// The recording stopped by itself; the capture is in the outbox.
        case recording
        /// A command failed; the state is as before it.
        case command(RecorderCommand.Kind)
    }

    public let id: UUID
    public var moment: Moment
    public var failure: RecorderFailure

    public init(moment: Moment, failure: RecorderFailure) {
        id = UUID()
        self.moment = moment
        self.failure = failure
    }
}
