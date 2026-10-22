import Foundation

/// A recording's id (= the capture package's id, `LectureManifest.id`). Typed, so a lecture's,
/// course's or package row's UUID cannot address the recorder by mistake. Encoded as the bare
/// UUID string, so payloads read the same as a plain UUID.
public struct RecordingID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    /// Nil when `uuidString` is not a UUID (an intent parameter).
    public init?(uuidString: String) {
        guard let uuid = UUID(uuidString: uuidString) else { return nil }
        rawValue = uuid
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var uuidString: String { rawValue.uuidString }

    public var description: String { rawValue.uuidString }
}
