/// Liveness: both sides send one every `LinkPolicy.pingInterval`; the answer (`pong`) echoes the
/// nonce, which gives the round-trip time on the sender's own clock.
public struct Ping: Codable, Hashable, Sendable {
    public var nonce: UInt64

    public init(nonce: UInt64) {
        self.nonce = nonce
    }
}
