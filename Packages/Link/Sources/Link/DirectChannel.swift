import Foundation
import LinkCore
import Network
import Security

/// The direct route: one TCP connection under TLS 1.3 between the phone and the Mac, both keys
/// pinned (Bonjour on Wi-Fi, Ethernet and the USB cable; peer-to-peer Wi-Fi when the parameters
/// include it). Framing, liveness and the two lanes live here; the sessions above see messages.
///
/// A channel exists only inside its connection's scope (`NetworkListener.run`'s handler on the
/// Mac, `withNetworkConnection` on the phone): `open` sends this side's hello and checks the
/// peer's, then `run` keeps a reader, a writer and a pinger as child tasks while the session runs
/// as `body`. When `body` returns, the peer says goodbye, liveness is lost or the protocol is
/// broken, the children end, `run` returns and the scope closes the connection. Nothing outlives it.
actor DirectChannel: LinkChannel {
    nonisolated let peer: LinkPeer
    nonisolated let messages: AsyncThrowingStream<LinkMessage, any Error>
    private let inbound: AsyncThrowingStream<LinkMessage, any Error>.Continuation
    private let connection: NetworkConnection<TLS>

    /// A frame waiting for the writer; `done` (when someone waits) is resumed once it was handed
    /// to the network, or failed when the channel ended first.
    private struct Outgoing {
        let frame: Data
        let done: CheckedContinuation<Void, any Error>?
    }

    private var control: [Outgoing] = []
    private var bulk: [Outgoing] = []
    /// The waiter of the frame the writer is sending now: resumed by the writer when the network
    /// took it, or by `finish` first (a send stuck on a dead path never outlives the channel).
    private var inFlight: CheckedContinuation<Void, any Error>?
    private var writerWaiting: CheckedContinuation<Void, Never>?
    private var ended = false
    private var closing = false
    /// When the last byte arrived (headers and body pieces both count).
    private var lastByte = ContinuousClock.now
    private var roundTrips: [Duration] = []
    private var pingsOut: [UInt64: ContinuousClock.Instant] = [:]
    private var nonce: UInt64 = 0
    /// The goodbye the peer said, if it said one.
    private(set) var peerGoodbye: Goodbye?

    private init(connection: NetworkConnection<TLS>, peer: LinkPeer) {
        self.connection = connection
        self.peer = peer
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: LinkMessage.self)
        messages = stream
        inbound = continuation
    }

    // MARK: - Parameters

    /// The connection's stack for both the Mac's listeners and the phone's dials: TCP without
    /// Nagle, with keepalive (5 s idle, 2 s apart, 3 probes) and a 10 s connect timeout, under TLS
    /// 1.3 only, presenting `identity`, requiring the peer's certificate, offering only this
    /// generation's ALPN, without session tickets. The peer's certificate is trusted when its key's
    /// fingerprint is (`isTrusted`); the chain is never evaluated. `peerToPeer` adds peer-to-peer
    /// Wi-Fi (AWDL), fixed for the life of whatever uses these parameters.
    static func parameters(
        identity: sec_identity_t, peerToPeer: Bool, isTrusted: @escaping @Sendable (LinkFingerprint) async -> Bool
    ) -> NWParametersBuilder<TLS> {
        NWParametersBuilder<TLS>.parameters {
            TLS {
                TCP()
                    .noDelay(true)
                    .keepalive(idleTimeInSeconds: 5, count: 3, intervalInSeconds: 2)
                    .connectionTimeout(10)
            }
            .version(min: .TLSv13, max: .TLSv13)
            .localIdentity(identity)
            .peerAuthentication(.required)
            .applicationProtocols([LinkProtocol.applicationProtocol])
            .ticketsEnabled(false)
            .certificateValidator { _, trust in
                guard let fingerprint = PeerCertificate.fingerprint(trust: trust) else { return false }
                return await isTrusted(fingerprint)
            }
        }
        .peerToPeerIncluded(peerToPeer)
    }

    // MARK: - Opening

    /// Sends `hello` and reads the peer's (TLS finishes on the way), both within
    /// `LinkPolicy.helloTimeout`, then checks the session, failing closed: the agreed ALPN must be
    /// this generation's, a peer certificate must be there (a resumed session has none), its key
    /// must be a trusted device of the other platform (`peersFor`: the rows with that key), the
    /// hello must name one of those devices and that platform, and the two hellos must share a
    /// feature. Anything else is answered with a goodbye and thrown.
    ///
    /// A handshake either side's pin check refuses leaves the connection waiting, not failed: the
    /// first waiting or failed state ends the exchange at once (`refused`), so a stranger's Mac or
    /// phone costs a dial pass or an admission slot milliseconds, not the whole timeout. The
    /// timeout stays for a peer that finishes TLS and never says hello.
    static func open(
        _ connection: NetworkConnection<TLS>, hello: Hello,
        peersFor: @escaping @Sendable (LinkFingerprint) async -> Set<LinkDeviceID>
    ) async throws -> LinkPeer {
        let expected: LinkRole = hello.role == .mac ? .iPhone : .mac
        let theirs: Hello
        do {
            theirs = try await withDeadline(LinkPolicy.helloTimeout) {
                try await withThrowingTaskGroup(of: Hello.self) { group in
                    group.addTask { try await exchangeHellos(hello, on: connection) }
                    group.addTask { try await refusal(of: connection) }
                    defer { group.cancelAll() }
                    guard let theirs = try await group.next() else { throw LinkChannelError.timedOut }
                    return theirs
                }
            }
        } catch let error as LinkProtocolError {
            await refuse(connection, .protocolError)
            throw LinkChannelError.protocolViolation(error)
        } catch LinkChannelError.protocolViolation(let error) {
            await refuse(connection, .protocolError)
            throw LinkChannelError.protocolViolation(error)
        }

        guard let tls = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            await refuse(connection, .untrusted)
            throw LinkChannelError.untrusted
        }
        let session = tls.securityProtocolMetadata
        let alpn = PeerCertificate.negotiatedProtocol(metadata: session)
        guard alpn == LinkProtocol.applicationProtocol, let fingerprint = PeerCertificate.fingerprint(metadata: session) else {
            LinkLog.direct.notice("Refused a connection: ALPN \(alpn ?? "none", privacy: .public) or no peer certificate")
            await refuse(connection, .untrusted)
            throw LinkChannelError.untrusted
        }
        let device = theirs.device
        guard await peersFor(fingerprint).contains(device), theirs.role == expected else {
            LinkLog.direct.notice("Refused \(fingerprint.description, privacy: .public): not a trusted \(expected.rawValue, privacy: .public)")
            await refuse(connection, .untrusted)
            throw LinkChannelError.untrusted
        }
        guard hello.allowsControl(with: theirs) || hello.allowsFiles(with: theirs) else {
            LinkLog.direct.notice("Refused \(device.description, privacy: .public): no feature in common (\(theirs.app, privacy: .public))")
            await refuse(connection, .unsupported)
            throw LinkChannelError.untrusted
        }
        LinkLog.direct.info("Linked to \(expected.rawValue, privacy: .public) \(device.description, privacy: .public) (\(theirs.app, privacy: .public), run \(theirs.instance.uuidString, privacy: .public))")
        return LinkPeer(device: device, fingerprint: fingerprint, hello: theirs)
    }

    /// This side's hello out, the peer's in.
    private static func exchangeHellos(_ hello: Hello, on connection: NetworkConnection<TLS>) async throws -> Hello {
        try await write(try LinkFrame.encode(.hello(hello)), to: connection)
        switch try await readMessage(from: connection, noteBytes: {}) {
        case .hello(let theirs):
            return theirs
        case .goodbye(let goodbye):
            LinkLog.direct.notice("Turned away before the hello: \(goodbye.reason.rawValue, privacy: .public)")
            throw LinkChannelError.closed
        case let other:
            throw LinkChannelError.protocolViolation(.unexpected(kind: other.kind))
        }
    }

    /// Throws `refused` at the connection's first waiting or failed state (a refused handshake on
    /// either side, a path that went away) and `closed` once it is cancelled; never returns. It
    /// reads the state every `refusalCheck` rather than taking the connection's one update
    /// handler, which belongs to whoever made the connection.
    private static func refusal(of connection: NetworkConnection<TLS>) async throws -> Hello {
        while true {
            switch connection.state {
            case .waiting(let error), .failed(let error):
                LinkLog.direct.info("The handshake did not go through: \(String(describing: error), privacy: .public)")
                throw LinkChannelError.refused
            case .cancelled:
                throw LinkChannelError.closed
            default:
                try await Task.sleep(for: refusalCheck)
            }
        }
    }

    /// How often `refusal(of:)` looks at a connection's state during the hello.
    private static let refusalCheck: Duration = .milliseconds(50)

    /// A goodbye on a connection that never became a channel, best effort, for a second at most.
    private static func refuse(_ connection: NetworkConnection<TLS>, _ reason: Goodbye.Reason) async {
        _ = try? await withDeadline(.seconds(1)) {
            try await write(try LinkFrame.encode(.goodbye(Goodbye(reason: reason))), to: connection)
        }
    }

    // MARK: - Running

    /// Runs `body` with the channel for `peer` (from `open`) while the reader, the writer and the
    /// pinger run beside it. Returns the peer's goodbye, if it said one; throws what ended `body`
    /// (the message stream's error when liveness was lost).
    nonisolated(nonsending) static func run(
        _ connection: NetworkConnection<TLS>, peer: LinkPeer, body: (DirectChannel) async throws -> Void
    ) async throws -> Goodbye? {
        let channel = DirectChannel(connection: connection, peer: peer)
        var failure: (any Error)?
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await channel.readLoop() }
            group.addTask { await channel.writeLoop() }
            group.addTask { await channel.pingLoop() }
            do {
                try await body(channel)
            } catch {
                failure = error
            }
            await channel.end()
            group.cancelAll()
        }
        if let failure { throw failure }
        return await channel.peerGoodbye
    }

    // MARK: - LinkChannel

    func send(_ message: LinkMessage, lane: LinkLane) async throws {
        let frame: Data
        do {
            frame = try LinkFrame.encode(message)
        } catch {
            throw LinkChannelError.protocolViolation(error)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard !ended, !closing else {
                continuation.resume(throwing: LinkChannelError.closed)
                return
            }
            let item = Outgoing(frame: frame, done: continuation)
            switch lane {
            case .control: control.append(item)
            case .bulk: bulk.append(item)
            }
            wakeWriter()
        }
    }

    func close(_ goodbye: Goodbye) async {
        guard !ended, !closing else { return }
        closing = true
        if let frame = try? LinkFrame.encode(.goodbye(goodbye)) {
            try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !ended else {
                    continuation.resume(throwing: LinkChannelError.closed)
                    return
                }
                control.append(Outgoing(frame: frame, done: continuation))
                wakeWriter()
            }
        }
        LinkLog.direct.info("Said goodbye (\(goodbye.reason.rawValue, privacy: .public)) to \(self.peer.device.description, privacy: .public)")
        finish(nil)
    }

    /// Ends the channel at once, without a goodbye: the message stream finishes and whatever waits
    /// to be sent fails.
    func end() {
        finish(nil)
    }

    var lastHeard: Date {
        let silence = ContinuousClock.now - lastByte
        let seconds = Double(silence.components.seconds) + Double(silence.components.attoseconds) / 1e18
        return Date().addingTimeInterval(-seconds)
    }

    // MARK: - Reader

    private func readLoop() async {
        do {
            while !ended {
                let message = try await Self.readMessage(from: connection) { [weak self] in
                    await self?.noteBytes()
                }
                guard !ended else { return }
                switch message {
                case .ping(let ping):
                    enqueue(.pong(ping))
                case .pong(let ping):
                    notePong(ping)
                case .goodbye(let goodbye):
                    peerGoodbye = goodbye
                    LinkLog.direct.info("\(self.peer.device.description, privacy: .public) said goodbye (\(goodbye.reason.rawValue, privacy: .public))")
                    finish(nil)
                    return
                case .hello:
                    throw LinkProtocolError.unexpected(kind: message.kind)
                case .unknown:
                    continue
                default:
                    inbound.yield(message)
                }
            }
        } catch let error as LinkProtocolError {
            LinkLog.direct.error("Protocol error from \(self.peer.device.description, privacy: .public): \(String(describing: error), privacy: .public)")
            await close(Goodbye(reason: .protocolError))
        } catch {
            guard !ended else { return }
            if !(error is CancellationError) {
                LinkLog.direct.notice("Connection to \(self.peer.device.description, privacy: .public) ended: \(String(describing: error), privacy: .public)")
            }
            finish(LinkChannelError.endOfStream)
        }
    }

    private func noteBytes() {
        lastByte = .now
    }

    private func notePong(_ ping: Ping) {
        guard let sent = pingsOut.removeValue(forKey: ping.nonce) else { return }
        roundTrips.append(.now - sent)
        if roundTrips.count > LinkPolicy.roundTripWindow {
            roundTrips.removeFirst(roundTrips.count - LinkPolicy.roundTripWindow)
        }
    }

    // MARK: - Writer

    /// Sends one frame at a time, control frames before bulk ones, so at most one chunk sits in
    /// this queue ahead of the network's own buffer.
    private func writeLoop() async {
        while !ended {
            guard let next = nextOutgoing() else {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if ended || !control.isEmpty || !bulk.isEmpty {
                        continuation.resume()
                    } else {
                        writerWaiting = continuation
                    }
                }
                continue
            }
            inFlight = next.done
            do {
                try await Self.write(next.frame, to: connection)
                inFlight?.resume()
                inFlight = nil
            } catch {
                inFlight?.resume(throwing: error)
                inFlight = nil
                if !ended, !(error is CancellationError) {
                    LinkLog.direct.notice("Sending to \(self.peer.device.description, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                }
                finish(LinkChannelError.lost)
                return
            }
        }
    }

    private func nextOutgoing() -> Outgoing? {
        if !control.isEmpty { return control.removeFirst() }
        if !bulk.isEmpty { return bulk.removeFirst() }
        return nil
    }

    /// Queues a control frame nobody waits for (pings, pongs).
    private func enqueue(_ message: LinkMessage) {
        guard !ended, let frame = try? LinkFrame.encode(message) else { return }
        control.append(Outgoing(frame: frame, done: nil))
        wakeWriter()
    }

    private func wakeWriter() {
        writerWaiting?.resume()
        writerWaiting = nil
    }

    // MARK: - Liveness

    /// Pings every `LinkPolicy.pingInterval` and declares the connection lost when no byte arrived
    /// for `LinkPolicy.lossTimeout` (6 s, or four times the worst recent round trip).
    private func pingLoop() async {
        while !ended {
            do {
                try await Task.sleep(for: LinkPolicy.pingInterval)
            } catch {
                return
            }
            guard !ended else { return }
            let worst = roundTrips.max() ?? .zero
            if ContinuousClock.now - lastByte > LinkPolicy.lossTimeout(worstRoundTrip: worst) {
                LinkLog.direct.notice("Lost \(self.peer.device.description, privacy: .public): nothing heard for too long")
                finish(LinkChannelError.lost)
                return
            }
            nonce &+= 1
            pingsOut[nonce] = .now
            if pingsOut.count > 2 * LinkPolicy.roundTripWindow {
                let oldest = nonce &- UInt64(2 * LinkPolicy.roundTripWindow)
                pingsOut = pingsOut.filter { $0.key > oldest }
            }
            enqueue(.ping(Ping(nonce: nonce)))
        }
    }

    // MARK: - Ending

    private func finish(_ error: (any Error)?) {
        guard !ended else { return }
        ended = true
        if let error {
            inbound.finish(throwing: error)
        } else {
            inbound.finish()
        }
        let waiting = control + bulk
        control = []
        bulk = []
        for item in waiting {
            item.done?.resume(throwing: LinkChannelError.closed)
        }
        inFlight?.resume(throwing: LinkChannelError.closed)
        inFlight = nil
        wakeWriter()
    }

    // MARK: - Frames

    private static func write(_ frame: Data, to connection: NetworkConnection<TLS>) async throws {
        try await connection.send(frame)
    }

    /// One whole message: the header first, its length checked against the cap before any body
    /// byte is read, then the body in pieces (each piece counts for liveness).
    private static func readMessage(
        from connection: NetworkConnection<TLS>, noteBytes: @Sendable () async -> Void
    ) async throws -> LinkMessage {
        let header = try await connection.receive(exactly: LinkFrame.headerSize).content
        guard header.count == LinkFrame.headerSize else { throw LinkChannelError.endOfStream }
        await noteBytes()
        let (kind, length) = try LinkFrame.header(header)
        var body = Data(capacity: length)
        while body.count < length {
            let piece = try await connection.receive(atLeast: 1, atMost: length - body.count).content
            guard !piece.isEmpty else { throw LinkChannelError.endOfStream }
            body.append(piece)
            await noteBytes()
        }
        return try LinkFrame.decode(kind: kind, body: body)
    }

    /// `operation`'s value, or `LinkChannelError.timedOut` after `limit` (the operation is then
    /// cancelled).
    static func withDeadline<Value: Sendable>(
        _ limit: Duration, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: limit)
                throw LinkChannelError.timedOut
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw LinkChannelError.timedOut }
            return value
        }
    }
}
