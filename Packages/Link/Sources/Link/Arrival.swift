import RecorderContract

/// A recording the Mac is receiving from the phone: from its final offer until the Mac has
/// moved it into its Recordings folder.
public struct Arrival: Identifiable, Hashable, Sendable {
    public let id: RecordingID
    /// "DC Lecture 2".
    public var title: String
    /// Bytes on the Mac's disk so far.
    public var stored: Int64
    /// Bytes of every file of the recording.
    public var total: Int64

    public init(id: RecordingID, title: String, stored: Int64, total: Int64) {
        self.id = id
        self.title = title
        self.stored = stored
        self.total = total
    }
}
