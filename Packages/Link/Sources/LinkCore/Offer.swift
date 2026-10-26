import RecorderContract

/// One file of an offered recording, by its path in the package.
public struct OfferedFile: Codable, Hashable, Sendable {
    /// Relative to the package root: `manifest.json`, `events.json`, `notes.json` or
    /// `audio/seg-0001.caf` (`InboxRules.accepts`).
    public var path: String
    public var size: Int64
    /// Lowercase hex of the file's SHA-256: the Mac checks it once the file is whole.
    public var sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// What the phone has of one recording so far. It grows as segments close: the live recording's
/// offer lists only its closed segments (`RecorderSnapshot.closedSegments`), a finished one's every
/// file. The JSON files come only with `isFinal`, after which nothing is added.
public struct Offer: Codable, Hashable, Sendable {
    public var recording: RecordingID
    /// "DC Lecture 2": the Mac's arrival row.
    public var title: String
    /// Every file of the package is listed and none will change: the Mac files it once all are
    /// stored and checked.
    public var isFinal: Bool
    public var files: [OfferedFile]

    public init(recording: RecordingID, title: String, isFinal: Bool, files: [OfferedFile]) {
        self.recording = recording
        self.title = title
        self.isFinal = isFinal
        self.files = files
    }

    /// The bytes of every file offered.
    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }
}
