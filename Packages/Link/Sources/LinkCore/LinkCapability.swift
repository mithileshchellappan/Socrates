/// A feature a peer speaks, listed in its hello. A string, so a newer peer's features decode and
/// are simply not used.
public struct LinkCapability: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The Mac remote: snapshots, commands and results. Active only when both hellos list it and
    /// their `recorderContract` versions are equal.
    public static let control = Self(rawValue: "control.1")
    /// Recordings copied to the Mac: holdings, offers, wants, chunks, stored and received.
    /// Independent of `control`.
    public static let files = Self(rawValue: "files.1")
}
