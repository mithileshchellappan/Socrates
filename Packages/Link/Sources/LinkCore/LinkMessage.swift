import RecorderContract

/// One message of the link, protocol generation 1 (`LinkProtocol.applicationProtocol`). Each has
/// a fixed kind number that is never reused; a kind this build does not know arrives as
/// `unknown` and is skipped.
///
/// | kind | from | purpose |
/// |---|---|---|
/// | 1 hello | both, first | identity, recorder contract, capabilities |
/// | 2 goodbye | both | why a side closes |
/// | 3 ping, 4 pong | both | liveness, round-trip time |
/// | 16 snapshot | iPhone | the recorder's state, on every change |
/// | 17 command | Mac | Pause, Resume, Next Slide, Stop (origin remote) |
/// | 18 result | iPhone | the command's outcome |
/// | 32 holdings | iPhone | every recording the phone still offers |
/// | 33 offer | iPhone | one recording's files so far |
/// | 34 want | Mac | one file's bytes from an offset |
/// | 35 chunk | iPhone | file bytes (binary body) |
/// | 36 stored | Mac | bytes durably on the Mac |
/// | 37 received | Mac | the Mac took the recording (or will not) |
public enum LinkMessage: Hashable, Sendable {
    case hello(Hello)
    case goodbye(Goodbye)
    case ping(Ping)
    case pong(Ping)
    case snapshot(SnapshotMessage)
    case command(RecorderCommand)
    case result(RecorderOutcome)
    case holdings(Holdings)
    case offer(Offer)
    case want(Want)
    case chunk(Chunk)
    case stored(Stored)
    case received(Received)
    /// A kind this build does not know (read and skipped).
    case unknown(kind: UInt8)

    /// The kind numbers of generation 1.
    public enum Kind {
        public static let hello: UInt8 = 1
        public static let goodbye: UInt8 = 2
        public static let ping: UInt8 = 3
        public static let pong: UInt8 = 4
        public static let snapshot: UInt8 = 16
        public static let command: UInt8 = 17
        public static let result: UInt8 = 18
        public static let holdings: UInt8 = 32
        public static let offer: UInt8 = 33
        public static let want: UInt8 = 34
        public static let chunk: UInt8 = 35
        public static let stored: UInt8 = 36
        public static let received: UInt8 = 37
    }

    public var kind: UInt8 {
        switch self {
        case .hello: Kind.hello
        case .goodbye: Kind.goodbye
        case .ping: Kind.ping
        case .pong: Kind.pong
        case .snapshot: Kind.snapshot
        case .command: Kind.command
        case .result: Kind.result
        case .holdings: Kind.holdings
        case .offer: Kind.offer
        case .want: Kind.want
        case .chunk: Kind.chunk
        case .stored: Kind.stored
        case .received: Kind.received
        case .unknown(let kind): kind
        }
    }
}
