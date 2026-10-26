import RecorderContract

/// The Mac took a recording, or will not: the phone writes its receipt and never offers it again.
/// Sent right after the package moved into the Mac's Recordings folder (filing follows there; a
/// quit before it is taken up by the launch's filing pass).
public struct Received: Codable, Hashable, Sendable {
    /// A string, so a newer Mac's outcomes decode (and are treated like `kept`).
    public struct Outcome: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Moved into the Mac's Recordings folder, whole and checked.
        public static let kept = Self(rawValue: "kept")
        /// The Mac had it already (filed, imported, or shared by AirDrop): nothing was copied.
        public static let known = Self(rawValue: "known")
        /// It failed the Mac's checks twice; Share on the phone stays the way to send it.
        public static let refused = Self(rawValue: "refused")
    }

    public var recording: RecordingID
    public var outcome: Outcome

    public init(recording: RecordingID, outcome: Outcome) {
        self.recording = recording
        self.outcome = outcome
    }
}
