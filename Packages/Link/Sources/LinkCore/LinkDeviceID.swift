import Foundation

/// A device key's id on the link: the `link_device` row's id. Typed, so no other UUID names a
/// peer by mistake. Encoded as the bare UUID string.
public struct LinkDeviceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}
