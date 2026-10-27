import RecorderContract

/// A recording the Mac is receiving from the phone: from its final offer until the Mac has
/// moved it into its Recordings folder.
public struct Arrival: Identifiable, Hashable, Sendable {
    public let id: RecordingID
    /// "DC Lecture 2".
    public var title: String
    /// Its course's colour in the Mac's library ("#0a84ff"), for the row's dot; nil when the
    /// phone named no course or the Mac does not know it.
    public var colorHex: String?
    /// Bytes on the Mac's disk so far.
    public var stored: Int64
    /// Bytes of every file of the recording.
    public var total: Int64

    public init(id: RecordingID, title: String, colorHex: String? = nil, stored: Int64, total: Int64) {
        self.id = id
        self.title = title
        self.colorHex = colorHex
        self.stored = stored
        self.total = total
    }
}
