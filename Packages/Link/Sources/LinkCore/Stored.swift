import RecorderContract

/// The Mac's acknowledgement that `bytes` of a file are on its disk durably (after a full fsync):
/// every `LinkPolicy.ackInterval` bytes and at the file's end. The phone's outbox row counts from
/// these.
public struct Stored: Codable, Hashable, Sendable {
    public var recording: RecordingID
    public var path: String
    public var bytes: Int64
    /// The whole file is stored and its SHA-256 matched the offer.
    public var isVerified: Bool

    public init(recording: RecordingID, path: String, bytes: Int64, isVerified: Bool) {
        self.recording = recording
        self.path = path
        self.bytes = bytes
        self.isVerified = isVerified
    }
}
