import RecorderContract

/// Every recording the phone still offers (no receipt yet), the live one included. Sent after the
/// hello and whenever it changes; the Mac deletes its staging for that device of any recording
/// not listed (the student deleted it on the phone).
public struct Holdings: Codable, Hashable, Sendable {
    public var recordings: [RecordingID]

    public init(recordings: [RecordingID]) {
        self.recordings = recordings
    }
}
