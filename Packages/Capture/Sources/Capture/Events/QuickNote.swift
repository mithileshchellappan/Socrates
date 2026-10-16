import Foundation

/// A plain-text note typed against one slide during class.
public struct QuickNote: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    /// 1-based deck page the note belongs to.
    public var page: Int
    public var text: String
    /// Recording-clock frame when the note was started (nil when not recording).
    public var sampleTime: Int64?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        page: Int,
        text: String,
        sampleTime: Int64? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.page = page
        self.text = text
        self.sampleTime = sampleTime
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public var isBlank: Bool {
        text.allSatisfy(\.isWhitespace)
    }
}

/// Contents of `notes.json`.
public struct QuickNoteLog: Codable, Sendable, Hashable {
    public static let currentVersion = 1

    public var version: Int
    public var notes: [QuickNote]

    public init(version: Int = QuickNoteLog.currentVersion, notes: [QuickNote]) {
        self.version = version
        self.notes = notes
    }
}
