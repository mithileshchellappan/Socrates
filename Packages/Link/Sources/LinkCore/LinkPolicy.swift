import Foundation

/// The link's timing and size constants, and the rules made of them.
public enum LinkPolicy {
    /// Both sides ping this often while connected.
    public static let pingInterval: Duration = .seconds(1)

    /// A connection is lost when no byte arrived for this long: 6 s, or four times the worst of
    /// the last round trips when that is longer (a slow but alive network is not dropped).
    public static func lossTimeout(worstRoundTrip: Duration) -> Duration {
        max(.seconds(6), worstRoundTrip * 4)
    }

    /// How many recent round trips `lossTimeout` looks at.
    public static let roundTripWindow = 10

    /// TLS and both hellos must be done within this.
    public static let helloTimeout: Duration = .seconds(10)

    /// The phone's wait before dialing again after `failedPasses` full passes over the Mac's
    /// endpoints failed in a row: none before the first, then 5, 10, 20 and from then on 30 s.
    public static func dialDelay(failedPasses: Int) -> Duration {
        switch failedPasses {
        case ...0: .zero
        case 1: .seconds(5)
        case 2: .seconds(10)
        case 3: .seconds(20)
        default: .seconds(30)
        }
    }

    /// The Mac's limits before a peer has said hello: connections in total and per remote host.
    public static let maximumPendingConnections = 8
    public static let maximumPendingPerHost = 2

    /// The bytes of one chunk.
    public static let chunkSize = 256 * 1024
    /// The Mac acknowledges stored bytes this often within a file (and at its end).
    public static let ackInterval: Int64 = 8 * 1024 * 1024

    /// How long the Mac keeps showing a phone recording it lost touch with (frozen, grey).
    public static let frozenLifetime: Duration = .seconds(4 * 60 * 60)
    /// How long before and after a class that records the Mac also listens peer-to-peer.
    public static let classMargin: TimeInterval = 600
    /// How often the Mac looks at the peer-to-peer window again without a change of its own.
    public static let windowRecheck: Duration = .seconds(5 * 60)
    /// The Mac deletes a device's staging folder left untouched this long.
    public static let stagingLifetime: TimeInterval = 14 * 24 * 60 * 60
    /// The free disk space the Mac keeps beyond a file before asking for it.
    public static let diskReserve: Int64 = 1 << 30
}
