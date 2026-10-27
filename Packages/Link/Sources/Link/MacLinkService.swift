import Foundation
import GRDB
import LinkCore
import Network
import RecorderContract
import Security
import StudyCore

/// The Mac's side of the link: listens for the student's phones, admits and authenticates them,
/// keeps one session per phone, runs the remote's commands over it, and hands arriving recordings
/// to the inbox and then to filing.
///
/// It is the one owner of what the Mac shows of the phone (`MacLinkEvent`): the recording (newest
/// snapshot first, replaced by the first snapshot of a new session, cleared by a nil or stopped
/// snapshot, frozen at the last byte heard when its session ends, dropped when it is filed here
/// another way or `LinkPolicy.frozenLifetime` after it was last heard) and the rows of recordings
/// arriving (each ends with the session that brings it; a later final offer brings it back).
///
/// Listening:
/// - over Wi-Fi, Ethernet and the USB cable (the infrastructure listener) whenever at least one
///   trusted iPhone row exists;
/// - also over peer-to-peer Wi-Fi, a second listener with its own random name, only while
///   `PeerToPeerWindow` is open: a class of a course that records is on, a phone recording is
///   known, or a session runs over it. Each listener's parameters are fixed when it is made, so
///   the infrastructure listener is never rebuilt for it.
///
/// Before a peer is known, at most `LinkPolicy.maximumPendingConnections` connections wait for
/// their hello, `maximumPendingPerHost` from one address, each for `helloTimeout` at most (a
/// refused handshake gives its slot back at once).
/// While a session runs, the Mac holds a user-initiated activity so App Nap does not delay pings.
/// It keeps the Mac from idle-sleeping only while the phone of the recording shown is linked or a
/// recording arrives over a session: a sleeping Mac drops the link, and a phone in a pocket stops
/// dialing a few minutes later. Otherwise the Mac may sleep when idle.
actor MacLinkService {
    private let services: StudyServices
    private let file: @MainActor @Sendable (URL) async -> Void
    private let directory: LinkDirectory
    private let inbox: RecordingInbox
    /// New at every launch (the hello's `instance`).
    private let instance = UUID()

    private var events: AsyncStream<MacLinkEvent>.Continuation?
    private var started = false
    private var secIdentity: sec_identity_t?
    private var device: LinkDeviceID?
    private var trusted = TrustedPeers()

    private var infrastructure: Task<Void, Never>?
    private var peerToPeer: Task<Void, Never>?
    private var window: Task<Void, Never>?
    /// The `filing` table, followed while the link runs (`filingsChanged`).
    private var filingObservation: AnyDatabaseCancellable?
    private var filingWatcher: Task<Void, Never>?
    /// Filing, one recording after the other.
    private var filing: Task<Void, Never>?

    private var pendingTotal = 0
    private var pendingByHost: [String: Int] = [:]

    /// A phone's session.
    private struct Registration {
        let id: UUID
        let device: LinkDeviceID
        let channel: any LinkChannel
        let controlOn: Bool
        let isPeerToPeer: Bool
        var hasSnapshot = false
        /// The recording its last snapshot was of.
        var recording: RecordingID?
    }

    private var sessions: [LinkDeviceID: Registration] = [:]

    /// The `ProcessInfo` activity held, and whether it keeps the Mac from idle-sleeping.
    private struct Activity {
        let token: any NSObjectProtocol
        let keepsAwake: Bool
    }

    private var activity: Activity?

    /// A command sent and its answer.
    private enum PendingCommand {
        /// Sent on that session; nobody waits yet.
        case sent(session: UUID)
        /// Answered before anybody waited.
        case answered(RecorderOutcome)
        /// The sender waits.
        case awaited(session: UUID, CheckedContinuation<RecorderOutcome?, Never>)
        /// Its session ended unanswered.
        case lost
    }

    private var commands: [RecorderCommand.ID: PendingCommand] = [:]

    /// The phone recording shown, and the phone it is from.
    private struct Shown {
        var device: LinkDeviceID
        var recording: RemoteRecording
    }

    /// What `PhoneLink` was last told of the recording.
    private struct Published: Equatable {
        var recording: RemoteRecording?
        var controlOn: Bool
    }

    private var shown: Shown?
    private var published: Published?
    /// Drops a frozen recording at the end of its lifetime.
    private var expiry: Task<Void, Never>?
    /// The phone each arrival row comes from: the row ends with that phone's session.
    private var arrivalSenders: [RecordingID: LinkDeviceID] = [:]
    /// An arrival's course colour once known: the Mac's own for the offer's course, else the
    /// phone's snapshot of that recording (gone once the recording stopped).
    private var arrivalColors: [RecordingID: String] = [:]

    init(services: StudyServices, file: @escaping @MainActor @Sendable (URL) async -> Void) {
        self.services = services
        self.file = file
        directory = LinkDirectory(services: services, role: .mac)
        inbox = RecordingInbox(services: services)
    }

    // MARK: - Lifecycle

    /// Loads the key (the link stays off without one), registers this Mac's row, follows the
    /// trusted phones (listening once there is one) and the peer-to-peer window. Idempotent.
    func start(events: AsyncStream<MacLinkEvent>.Continuation) async {
        guard !started else { return }
        started = true
        self.events = events
        let identity: LinkIdentity
        switch LinkIdentityStore().load() {
        case .ready(let loaded):
            identity = loaded
        case .unavailable(let reason):
            LinkLog.link.notice("Link off: \(reason, privacy: .public)")
            return
        }
        do {
            secIdentity = try identity.secIdentity()
            let device = try await directory.register(spki: identity.spki)
            guard started else { return }
            self.device = device
        } catch {
            LinkLog.link.error("Link off: \(String(describing: error), privacy: .public)")
            secIdentity = nil
            return
        }
        await inbox.start()
        await directory.follow { [weak self] peers in
            await self?.trustChanged(peers)
        }
        followFilings()
        window = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluateWindow()
                do {
                    try await Task.sleep(for: LinkPolicy.windowRecheck)
                } catch {
                    return
                }
            }
        }
    }

    /// Says goodbye to every session and stops listening.
    func stop() async {
        guard started else { return }
        started = false
        window?.cancel()
        window = nil
        filingObservation?.cancel()
        filingObservation = nil
        filingWatcher?.cancel()
        filingWatcher = nil
        let open = sessions.values.map(\.channel)
        await withTaskGroup(of: Void.self) { group in
            for channel in open {
                group.addTask { await channel.close(Goodbye(reason: .shuttingDown), within: .seconds(1)) }
            }
        }
        infrastructure?.cancel()
        infrastructure = nil
        peerToPeer?.cancel()
        peerToPeer = nil
        filing?.cancel()
        filing = nil
        expiry?.cancel()
        expiry = nil
        for case .awaited(_, let continuation) in commands.values {
            continuation.resume(returning: nil)
        }
        commands = [:]
        sessions = [:]
        shown = nil
        published = nil
        arrivalSenders = [:]
        arrivalColors = [:]
        updateActivity()
        await directory.stop()
        trusted = TrustedPeers()
        await inbox.stop()
        events?.finish()
        events = nil
    }

    private func trustChanged(_ peers: TrustedPeers) async {
        guard started else { return }
        trusted = peers
        for session in sessions.values where !peers.contains(session.device) {
            await session.channel.close(Goodbye(reason: .untrusted), within: .seconds(1))
        }
        if peers.isEmpty {
            infrastructure?.cancel()
            infrastructure = nil
        } else if infrastructure == nil {
            infrastructure = listen(peerToPeer: false)
        }
        await evaluateWindow()
    }

    // MARK: - Listening

    /// Keeps a listener up until the returned task is cancelled (the window closes, the link
    /// stops). Owned by the service.
    private func listen(peerToPeer: Bool) -> Task<Void, Never> {
        Task { await self.keepListening(peerToPeer: peerToPeer) }
    }

    /// A listener advertised under a new random name each time (nothing personal is broadcast).
    /// One that fails (Local Network access granted only later, an interface that went away) is
    /// made again after 5, 10, 20, then every 30 s; one that ran for a while starts that count over.
    private func keepListening(peerToPeer: Bool) async {
        var failures = 0
        while !Task.isCancelled, started, let secIdentity {
            let directory = directory
            let parameters = DirectChannel.parameters(identity: secIdentity, peerToPeer: peerToPeer) { fingerprint in
                await directory.isTrusted(fingerprint)
            }
            let began = ContinuousClock.now
            do {
                let listener = try NetworkListener(
                    for: BonjourListenerProvider(name: Self.serviceName(), type: LinkProtocol.serviceType), using: parameters
                )
                listener.onStateUpdate { _, state in
                    switch state {
                    case .ready: LinkLog.direct.info("Listening\(peerToPeer ? " peer-to-peer" : "", privacy: .public)")
                    case .waiting(let error), .failed(let error):
                        LinkLog.direct.notice("Listener\(peerToPeer ? " (peer-to-peer)" : "", privacy: .public): \(String(describing: error), privacy: .public)")
                    default: break
                    }
                }
                try await listener.run { connection in
                    await self.serve(connection, peerToPeer: peerToPeer)
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                LinkLog.direct.error("Listener stopped: \(String(describing: error), privacy: .public)")
            }
            failures = ContinuousClock.now - began > LinkPolicy.listenerSettled ? 1 : failures + 1
            do {
                try await Task.sleep(for: LinkPolicy.dialDelay(failedPasses: failures))
            } catch {
                return
            }
        }
    }

    /// Twelve random hex digits.
    private static func serviceName() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<6).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }

    /// One incoming connection, from admission to the end of its session.
    private nonisolated func serve(_ connection: NetworkConnection<TLS>, peerToPeer: Bool) async {
        let host = Self.host(of: connection)
        guard await admit(host) else {
            LinkLog.direct.notice("Turned a connection away: too many waiting")
            return
        }
        guard let hello = await localHello() else {
            await release(host)
            return
        }
        let directory = directory
        let peer: LinkPeer
        do {
            peer = try await DirectChannel.open(connection, hello: hello) { fingerprint in
                await directory.devices(for: fingerprint)
            }
        } catch {
            await release(host)
            LinkLog.direct.info("A connection did not become a session: \(String(describing: error), privacy: .public)")
            return
        }
        await release(host)
        var registered: (id: UUID, device: LinkDeviceID)?
        do {
            _ = try await DirectChannel.run(connection, peer: peer) { channel in
                guard var session = await self.register(
                    channel, controlOn: hello.allowsControl(with: peer.hello), filesOn: hello.allowsFiles(with: peer.hello),
                    peerToPeer: peerToPeer
                ) else { return }
                registered = (session.id, session.device)
                try await session.run()
            }
        } catch {
            LinkLog.direct.notice("Session with \(peer.device.description, privacy: .public) ended: \(String(describing: error), privacy: .public)")
        }
        if let registered {
            await unregister(registered.id, device: registered.device)
        }
    }

    private static func host(of connection: NetworkConnection<TLS>) -> String {
        if case .hostPort(let host, _)? = connection.remoteEndpoint { return "\(host)" }
        return "unknown"
    }

    private func admit(_ host: String) -> Bool {
        guard started, pendingTotal < LinkPolicy.maximumPendingConnections,
              pendingByHost[host, default: 0] < LinkPolicy.maximumPendingPerHost
        else { return false }
        pendingTotal += 1
        pendingByHost[host, default: 0] += 1
        return true
    }

    private func release(_ host: String) {
        pendingTotal = max(0, pendingTotal - 1)
        let left = (pendingByHost[host] ?? 1) - 1
        pendingByHost[host] = left > 0 ? left : nil
    }

    private func localHello() -> Hello? {
        guard started, let device else { return nil }
        return Hello.local(role: .mac, device: device, instance: instance)
    }

    // MARK: - Sessions

    /// The phone's session from now on; one it had before is told it was replaced.
    private func register(_ channel: any LinkChannel, controlOn: Bool, filesOn: Bool, peerToPeer: Bool) async -> MacSession? {
        guard started else { return nil }
        let device = channel.peer.device
        let id = UUID()
        let previous = sessions[device]
        sessions[device] = Registration(id: id, device: device, channel: channel, controlOn: controlOn, isPeerToPeer: peerToPeer)
        updateActivity()
        await inbox.claim(RecordingInbox.Sender(device: device, session: id))
        publishRecording()
        if let previous {
            await previous.channel.close(Goodbye(reason: .replaced), within: .seconds(1))
        }
        await evaluateWindow()
        return MacSession(
            id: id, device: device, channel: channel, service: self, inbox: inbox, controlOn: controlOn, filesOn: filesOn
        )
    }

    private func unregister(_ id: UUID, device: LinkDeviceID) async {
        for (commandID, state) in commands {
            switch state {
            case .sent(let session) where session == id:
                commands[commandID] = .lost
            case .awaited(let session, let continuation) where session == id:
                commands[commandID] = nil
                continuation.resume(returning: nil)
            default:
                break
            }
        }
        await inbox.release(RecordingInbox.Sender(device: device, session: id))
        guard let registration = sessions[device], registration.id == id else { return }
        // Frozen at the last byte heard, never at the moment the loss was declared (seconds
        // later): the Mac never counts a time the phone did not confirm.
        let lost = await registration.channel.lastHeard
        guard sessions[device]?.id == id else { return }
        sessions[device] = nil
        updateActivity()
        if var current = shown, current.device == device, current.recording.isLive {
            current.recording.freshness = .lastSeen(lost)
            shown = current
            scheduleExpiry(lost: lost)
        }
        // Its copies stop with it; a later session's final offer brings each row back.
        withdraw(arrivalSenders.filter { $0.value == device }.map(\.key))
        publishRecording()
        await evaluateWindow()
    }

    /// Holds the activity a session needs (see the type's notes), or none without a session.
    private func updateActivity() {
        let linkedRecording = shown.map { sessions[$0.device] != nil } ?? false
        let wanted: Bool? = sessions.isEmpty ? nil : linkedRecording || !arrivalSenders.isEmpty
        guard wanted != activity?.keepsAwake else { return }
        let previous = activity
        activity = wanted.map { keepsAwake in
            Activity(
                token: ProcessInfo.processInfo.beginActivity(
                    options: keepsAwake ? .userInitiated : .userInitiatedAllowingIdleSystemSleep,
                    reason: keepsAwake ? "Phone recording linked" : "Recording link to the iPhone"
                ),
                keepsAwake: keepsAwake
            )
        }
        if let previous { ProcessInfo.processInfo.endActivity(previous.token) }
    }

    /// A snapshot from session `id`'s phone.
    func received(_ message: SnapshotMessage, session id: UUID) async {
        guard var registration = sessions.values.first(where: { $0.id == id }) else { return }
        let isFirst = !registration.hasSnapshot
        registration.hasSnapshot = true
        registration.recording = message.snapshot?.recordingID
        sessions[registration.device] = registration
        let wasKnown = shown != nil
        show(message, from: registration.device, isFirst: isFirst)
        publishRecording()
        updateActivity()
        if wasKnown != (shown != nil) {
            await evaluateWindow()
        }
    }

    // MARK: - The recording shown

    /// Applies a phone's snapshot (`isFirst`: the first of its session, which replaces what was
    /// shown unless another phone's recording is live).
    private func show(_ message: SnapshotMessage, from device: LinkDeviceID, isFirst: Bool) {
        guard let snapshot = message.snapshot, snapshot.isLive else {
            // Nothing records on that phone any more (or it stopped): the item goes.
            if let current = shown,
               current.device == device || current.recording.snapshot.recordingID == message.snapshot?.recordingID {
                clearShown()
            }
            return
        }
        let replaces = isFirst && (shown == nil || shown?.device == device || shown?.recording.isLive != true)
        guard replaces || snapshot.supersedes(shown?.recording.snapshot) else { return }
        shown = Shown(
            device: device,
            recording: RemoteRecording(
                snapshot: snapshot, freshness: .live, elapsedAtReceipt: message.elapsed,
                isRunning: message.isRunning, receivedAt: Date()
            )
        )
        expiry?.cancel()
        expiry = nil
    }

    private func clearShown() {
        shown = nil
        expiry?.cancel()
        expiry = nil
        publishRecording()
        updateActivity()
    }

    /// Tells `PhoneLink` the recording and whether its phone takes commands, when either changed.
    private func publishRecording() {
        let now = Published(recording: shown?.recording, controlOn: shown.flatMap { sessions[$0.device]?.controlOn } ?? false)
        guard now != published else { return }
        published = now
        events?.yield(.recording(now.recording, controlOn: now.controlOn))
    }

    /// A frozen recording goes `LinkPolicy.frozenLifetime` after its phone was last heard.
    private func scheduleExpiry(lost: Date) {
        expiry?.cancel()
        let left = max(.zero, LinkPolicy.frozenLifetime - .seconds(Date().timeIntervalSince(lost)))
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: left)
            } catch {
                return
            }
            await self?.expire(lost: lost)
        }
    }

    private func expire(lost: Date) async {
        guard case .lastSeen(lost)? = shown?.recording.freshness else { return }
        clearShown()
        await evaluateWindow()
    }

    // MARK: - Commands

    /// Sends `command` to the phone whose recording it is for and waits for its outcome; nil when
    /// no phone with control is linked or the session ended first. Never resent.
    func perform(_ command: RecorderCommand) async -> RecorderOutcome? {
        let candidates = sessions.values.filter(\.controlOn)
        guard let target = candidates.first(where: { $0.recording == command.recordingID }) ?? candidates.first else {
            return nil
        }
        let id = command.id
        commands[id] = .sent(session: target.id)
        do {
            try await target.channel.send(.command(command), lane: .control)
        } catch {
            commands[id] = nil
            return nil
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<RecorderOutcome?, Never>) in
            switch commands[id] {
            case .answered(let outcome)?:
                commands[id] = nil
                continuation.resume(returning: outcome)
            case .sent(let session)?:
                commands[id] = .awaited(session: session, continuation)
            case .awaited?, .lost?, nil:
                commands[id] = nil
                continuation.resume(returning: nil)
            }
        }
    }

    /// A phone's answer to a command.
    func resolve(_ outcome: RecorderOutcome) {
        switch commands[outcome.commandID] {
        case .sent?:
            commands[outcome.commandID] = .answered(outcome)
        case .awaited(_, let continuation)?:
            commands[outcome.commandID] = nil
            continuation.resume(returning: outcome)
        case .answered?, .lost?, nil:
            break
        }
    }

    // MARK: - Arrivals

    /// A recording being received from `device`'s phone (its final offer, its progress).
    func arriving(_ arrival: Arrival, from device: LinkDeviceID) {
        var arrival = arrival
        if let colorHex = arrival.colorHex {
            arrivalColors[arrival.id] = colorHex
        } else if let colorHex = arrivalColors[arrival.id] {
            arrival.colorHex = colorHex
        } else if let current = shown, current.recording.snapshot.recordingID == arrival.id {
            arrival.colorHex = current.recording.snapshot.course.colorHex
            arrivalColors[arrival.id] = arrival.colorHex
        }
        arrivalSenders[arrival.id] = device
        events?.yield(.arrival(arrival))
        updateActivity()
    }

    /// The Mac took `recording` (in `Recordings/` at `url`, filed next; `url` also for a package
    /// found there that nothing filed yet) or will not.
    func arrived(_ recording: RecordingID, at url: URL?) {
        arrivalColors[recording] = nil
        withdraw([recording])
        guard let url else { return }
        let previous = filing
        let file = file
        filing = Task {
            await previous?.value
            await file(url)
        }
    }

    /// The rows of `recordings` go: their copies stopped (the session ended, or the phone no longer
    /// has them and their staging is gone).
    func withdraw(_ recordings: [RecordingID]) {
        for recording in recordings {
            arrivalSenders[recording] = nil
            events?.yield(.arrived(recording))
        }
        updateActivity()
    }

    // MARK: - Filed another way

    /// Follows `filing`: a phone recording the Mac shows frozen ends when its recording is filed
    /// here another way (Share or AirDrop while the phone was out of reach; DESIGN 8.11).
    private func followFilings() {
        guard filingObservation == nil else { return }
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        filingObservation = DatabaseRegionObservation(tracking: SQLRequest<Row>(sql: "SELECT recording_id FROM filing"))
            .start(
                in: services.database,
                onError: { error in
                    LinkLog.link.error("Following the filings failed: \(String(describing: error), privacy: .public)")
                },
                onChange: { _ in continuation.yield() }
            )
        filingWatcher = Task { [weak self] in
            for await _ in changes {
                await self?.filingsChanged()
            }
        }
    }

    /// The recording shown, while no session reports it, has a `filing` row: the Mac has it, so it
    /// is no longer shown or known (the peer-to-peer window may close).
    private func filingsChanged() async {
        guard started, let current = shown else { return }
        let recording = current.recording.snapshot.recordingID
        guard !sessions.values.contains(where: { $0.recording == recording }) else { return }
        do {
            guard try await FilingRepository(store: services.records).latest(recordingID: recording.rawValue) != nil else { return }
        } catch {
            LinkLog.link.error("Reading a recording's filing failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard started, shown?.recording.snapshot.recordingID == recording,
              !sessions.values.contains(where: { $0.recording == recording })
        else { return }
        clearShown()
        await evaluateWindow()
    }

    // MARK: - Peer-to-peer window

    /// Opens or closes the peer-to-peer listener by `PeerToPeerWindow`.
    private func evaluateWindow() async {
        guard started, !trusted.isEmpty else {
            peerToPeer?.cancel()
            peerToPeer = nil
            return
        }
        let now = Date()
        let margin = LinkPolicy.classMargin
        var classes: [DateInterval] = []
        do {
            classes = try await SessionRepository(store: services.records)
                .recordingClasses(overlapping: DateInterval(start: now.addingTimeInterval(-margin), end: now.addingTimeInterval(margin)))
                .compactMap { $0.endsAt >= $0.startsAt ? DateInterval(start: $0.startsAt, end: $0.endsAt) : nil }
        } catch {
            LinkLog.link.error("Reading the classes that record failed: \(String(describing: error), privacy: .public)")
        }
        guard started, !trusted.isEmpty else { return }
        let isOpen = PeerToPeerWindow.isOpen(
            now: now,
            classes: classes,
            recordingKnown: shown != nil,
            peerToPeerSessions: sessions.values.filter(\.isPeerToPeer).count,
            margin: margin
        )
        if isOpen, peerToPeer == nil {
            peerToPeer = listen(peerToPeer: true)
        } else if !isOpen, let task = peerToPeer {
            task.cancel()
            peerToPeer = nil
            LinkLog.direct.info("Stopped listening peer-to-peer")
        }
    }
}
