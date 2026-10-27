/// Which side of the link a peer is: the `link_device` row's platform. A string, so a newer
/// build's other platforms decode; a peer trusts only the role it expects on the other side.
public struct LinkRole: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The Mac: listens, receives recordings, sends commands.
    public static let mac = Self(rawValue: "mac")
    /// The iPhone: dials, offers recordings, runs commands.
    public static let iPhone = Self(rawValue: "iphone")
}
