/// A frame the link refuses; the connection then closes with `Goodbye.Reason.protocolError`.
public enum LinkProtocolError: Error, Hashable, Sendable {
    /// The header announced a body over `LinkFrame.maximumBody` (refused before reading it).
    case oversized(kind: UInt8, length: Int)
    /// The body does not decode as its kind's message.
    case malformed(kind: UInt8)
    /// A message that cannot be sent or is out of place (an `unknown` message to encode).
    case unexpected(kind: UInt8)
}
