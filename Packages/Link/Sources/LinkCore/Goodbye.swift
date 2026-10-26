/// The last message before a side closes the connection on purpose.
public struct Goodbye: Codable, Hashable, Sendable {
    /// Why. A string, so a newer peer's reasons decode (and are treated like `done`).
    public struct Reason: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// Nothing left to do: the phone neither records nor holds anything the Mac lacks.
        public static let done = Self(rawValue: "done")
        /// A newer connection from the same device took this one's place.
        public static let replaced = Self(rawValue: "replaced")
        /// The peer's key, ALPN or hello did not match a trusted device of the other platform.
        public static let untrusted = Self(rawValue: "untrusted")
        /// Nothing the two sides speak in common.
        public static let unsupported = Self(rawValue: "unsupported")
        /// A frame over the cap, a body that does not decode, or a message out of order.
        public static let protocolError = Self(rawValue: "protocolError")
        /// The app is quitting or the link was switched off.
        public static let shuttingDown = Self(rawValue: "shuttingDown")
    }

    public var reason: Reason
    /// Seconds before dialing again, when the sender wants a pause; nil: the dialer's own policy.
    public var retryAfter: Double?

    public init(reason: Reason, retryAfter: Double? = nil) {
        self.reason = reason
        self.retryAfter = retryAfter
    }
}
