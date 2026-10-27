import Foundation
import LinkCore

/// One live, authenticated connection to the other device: the seam between the link's sessions
/// and its transport. The sessions (the Mac's `MacSession`, the phone's agent) speak only this;
/// `DirectChannel` is the route over TCP and TLS, and a later route (a second connection for bulk
/// bytes, a tailnet dial) comes in behind it without a change to them.
///
/// Messages arrive in order; the stream ends when the connection ends: normally after a goodbye
/// either way, with an error when liveness was lost or the peer broke the protocol. Nothing sent on
/// one channel is ever carried over to another.
protocol LinkChannel: Sendable {
    /// Who is on the other side, from the TLS session and its hello.
    var peer: LinkPeer { get }
    /// Every message from the peer except the link's own (hello, goodbye, ping, pong).
    var messages: AsyncThrowingStream<LinkMessage, any Error> { get }
    /// Sends `message` and returns once it was handed to the network. Throws once the channel ended.
    func send(_ message: LinkMessage, lane: LinkLane) async throws
    /// Says `goodbye` and ends the channel (the message stream finishes).
    func close(_ goodbye: Goodbye) async
    /// Ends the channel at once, without a goodbye: the message stream finishes and whatever waits
    /// to be sent fails.
    func end() async
    /// When the last byte from the peer arrived, on this device's clock: the last moment the peer
    /// is known to have been there.
    var lastHeard: Date { get async }
}

extension LinkChannel {
    /// Says `goodbye`, waiting no longer than `limit` for it to go (a quit, a replaced session):
    /// the channel ends either way.
    func close(_ goodbye: Goodbye, within limit: Duration) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.close(goodbye) }
            group.addTask {
                try? await Task.sleep(for: limit)
                await self.end()
            }
            await group.next()
            group.cancelAll()
        }
    }
}

/// How a message queues behind others on a channel.
enum LinkLane: Sendable {
    /// Sent before any queued bulk bytes: everything but file chunks.
    case control
    /// File chunks, one in flight at a time, with control messages going between them.
    case bulk
}

/// The device on the other side of a channel.
struct LinkPeer: Sendable, Hashable {
    /// Its `link_device` row: the row whose key it presented.
    var device: LinkDeviceID
    /// The hash of the key it presented.
    var fingerprint: LinkFingerprint
    var hello: Hello
}

/// Why a channel could not be opened or ended early.
enum LinkChannelError: Error, Hashable, Sendable {
    /// No byte arrived for longer than the loss timeout.
    case lost
    /// The channel ended (a goodbye either way, or it was stopped) before the message went.
    case closed
    /// The peer closed the connection in the middle of a frame or before its hello.
    case endOfStream
    /// TLS and both hellos were not done within `LinkPolicy.helloTimeout`.
    case timedOut
    /// The connection went waiting or failed before the hellos: a pin check on either side said
    /// no (a stranger, or a key whose row has not synced yet), or the path went away.
    case refused
    /// The peer's key, ALPN or hello did not match a trusted device of the other platform.
    case untrusted
    /// A frame the link refuses, or a message out of place.
    case protocolViolation(LinkProtocolError)
}
