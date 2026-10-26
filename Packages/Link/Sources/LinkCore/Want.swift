import RecorderContract

/// The Mac asks for one file's bytes from `from` (the length it already holds durably). One want
/// is outstanding per session; the phone answers with chunks carrying the want's id.
public struct Want: Codable, Hashable, Sendable {
    /// Numbers the chunks that answer this want.
    public var id: UInt32
    public var recording: RecordingID
    public var path: String
    public var from: Int64

    public init(id: UInt32, recording: RecordingID, path: String, from: Int64) {
        self.id = id
        self.recording = recording
        self.path = path
        self.from = from
    }
}
