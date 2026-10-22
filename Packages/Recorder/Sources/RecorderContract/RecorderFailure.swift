import Foundation

/// Why the recorder could not do something (`RecorderOutcome.Result.failed`), or why a recording
/// stopped by itself (`RecorderSnapshot.failure`). Typed, so each surface picks its own words and
/// a remote can tell "try again after the call" from "the recording is gone".
public enum RecorderFailure: String, Codable, Hashable, Sendable {
    /// A call or another app holds the input, or iOS does not let the app record now: the same
    /// command can be sent again later.
    case inputBusy
    /// Microphone access is off.
    case microphoneDenied
    /// No input device.
    case noInput
    /// Recording consent for the course was withdrawn.
    case notConsented
    /// Audio or the package could not be written (storage full).
    case storage
    /// The audio engine failed.
    case engine
    /// The recording stopped while the command ran (a failure stopped it).
    case stoppedMeanwhile
    /// A reason from a newer build that this one does not know.
    case unknown

    /// A reason this build does not know decodes as `unknown`, so a newer sender's payload still
    /// reads.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}
