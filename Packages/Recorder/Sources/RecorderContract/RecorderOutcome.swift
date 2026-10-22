import Foundation

/// The recorder's answer to one command, with the state after it so the sender can resync.
public struct RecorderOutcome: Codable, Hashable, Sendable {
    public enum Result: Codable, Hashable, Sendable {
        /// Done; `snapshot` shows the change.
        case applied
        /// Already in that state (Pause while paused, Resume while recording, Stop once stopped).
        case unchanged
        /// This id was decided before; nothing happened again.
        case duplicate
        /// Not valid now.
        case rejected(Rejection)
        /// Tried and failed (a Resume during a phone call); the state is as before and the same
        /// command may be sent again.
        case failed(RecorderFailure)
    }

    public enum Rejection: Codable, Hashable, Sendable {
        /// Nothing is recording.
        case noRecording
        /// The command is for another recording than the one running.
        case otherRecording
        /// The recorder does not take this command in this phase (Next Slide while paused).
        case notAccepted(RecorderSnapshot.Phase)
        /// The slide the surface showed is not the slide on screen any more.
        case staleSlide(shown: Int, current: Int)
        /// Past the deck's last slide, or before the first.
        case atEnd
    }

    public var commandID: RecorderCommand.ID
    public var result: Result
    /// The current state after the command; nil when nothing records.
    public var snapshot: RecorderSnapshot?

    public init(commandID: RecorderCommand.ID, result: Result, snapshot: RecorderSnapshot?) {
        self.commandID = commandID
        self.result = result
        self.snapshot = snapshot
    }
}
