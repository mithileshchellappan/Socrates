import Capture
import Foundation
import LinkCore
import Network
import RecorderContract
import Security
import StudyCore

/// The iPhone's side of the link: finds the Mac, dials it, keeps one session with it, copies the
/// outbox's recordings to it and runs its commands through the recorder's one entry
/// (`RecorderEndpoint`).
///
/// It links only while it has a reason to, to spare the battery: while a recording goes on, while
/// it holds background time after Stop with the recording not received yet, or while the app is
/// in the foreground and a capture waits for the Mac. Without a reason it says goodbye (`done`).
/// After `LinkPolicy.maximumFailedPasses` passes in a row without a Mac it stops dialing until a
/// reason to try again (Record, Pause, Resume, Stop, the foreground, a network path that comes up,
/// a change of the trusted Macs).
///
/// From a session with control until dialing ends or gives up, it tells the recorder a remote
/// is attached (`RecorderEndpoint.setRemoteAttached`): a pause then keeps the input, so the app
/// keeps running and the Mac's Resume works with the phone locked.
///
/// What the Mac has been told is reconciled in one place (`sync`), in the protocol's order:
/// holdings, final offers oldest first, the other captures' audio, the recording going on, the
/// snapshot. A stopped recording's final offer so goes before its stopped snapshot. The sync runs
/// in a pass the agent owns, so a snapshot or a message is never handled behind one.
actor PhoneLinkAgent {
    /// How long the first browse of a pass waits for the Mac to show up.
    static let discoveryTime: Duration = .seconds(5)

    private let services: StudyServices
    private let recorder: any RecorderEndpoint
    private let backgroundTime: LinkBackgroundTime
    private let directory: LinkDirectory
    private let receiptStore: OutboxReceipts
    /// New at every launch (the hello's `instance`).
    private let instance = UUID()

    /// What the Mac holds of each capture, for `MacLink`.
    private var deliveries: AsyncStream<[UUID: CaptureDelivery]>.Continuation?
    private var started = false
    private var secIdentity: sec_identity_t?
    private var device: LinkDeviceID?
    private var trusted = TrustedPeers()

    /// The recorder's state, from its snapshots.
    private var snapshot: RecorderSnapshot?
    private var isActive = false
    private var holdsBackgroundTime = false
    /// The stopped recording the background time is for.
    private var backgroundFor: RecordingID?

    private var listing = Outbox.Listing()
    private var listingVersion = 0
    private var relistNeeded = true
    /// Lists again once a capture left out for changing recently may be offered.
    private var quietRelist: Task<Void, Never>?
    private var receipts: [RecordingID: Received.Outcome] = [:]
    private var hashes: [URL: Outbox.Hash] = [:]
    /// Bytes the Mac acknowledged, by recording and path; kept in the capture's sidecar until the
    /// Mac answers, so a relaunch shows them before the Mac is reachable again.
    private var onMac: [RecordingID: [String: Int64]] = [:]
    /// Each capture's bytes, from its last offer.
    private var totals: [RecordingID: Int64] = [:]
    private var lastDeliveries: [UUID: CaptureDelivery]?

    private var session: Session?
    /// The sync passes (`requestSync`); a request while one runs runs one more.
    private var syncTask: Task<Void, Never>?
    private var syncGeneration = 0
    private var syncAgain = false

    private var dialing = Dialing.idle
    private var linkGeneration = 0
    /// The address of the last Mac session, dialed when browsing finds nothing (iOS may not browse
    /// while the phone is locked). Memory only.
    private var lastEndpoint: NWEndpoint?
    /// Follows the network path: one that comes up is a reason to dial again after giving up.
    private var pathWatch: Task<Void, Never>?
    /// What the recorder was last told (`RecorderEndpoint.setRemoteAttached`).
    private var remoteAttached = false

    /// The dial loop.
    private enum Dialing {
        /// No reason to link.
        case idle
        /// Browsing and dialing, or in a session.
        case running(Task<Void, Never>)
        /// `LinkPolicy.maximumFailedPasses` passes found no Mac: it waits for a reason to try
        /// again (`dialAgain`).
        case gaveUp

        var task: Task<Void, Never>? {
            switch self {
            case .running(let task): task
            case .idle, .gaveUp: nil
            }
        }
    }

    /// The session with the Mac and what it has been told.
    private struct Session {
        let id = UUID()
        let channel: any LinkChannel
        let controlOn: Bool
        let filesOn: Bool
        var toldHoldings: [RecordingID]?
        var toldOffers: [RecordingID: Offer] = [:]
        var toldListing = -1
        var hasToldSnapshot = false
        var toldSnapshot: RecorderSnapshot?
        /// The files offered, for the Mac's wants.
        var files: [RecordingID: [String: Outbox.File]] = [:]
    }

    init(services: StudyServices, recorder: any RecorderEndpoint, backgroundTime: LinkBackgroundTime) {
        self.services = services
        self.recorder = recorder
        self.backgroundTime = backgroundTime
        directory = LinkDirectory(services: services, role: .iPhone)
        receiptStore = OutboxReceipts(outbox: services.paths.phoneCaptures)
    }

    // MARK: - Lifecycle

    /// Loads the key (the link stays off without one), registers this phone's row, reads the
    /// receipts and the outbox, and follows the trusted Macs. Idempotent.
    func start(deliveries: AsyncStream<[UUID: CaptureDelivery]>.Continuation) async {
        guard !started else { return }
        started = true
        self.deliveries = deliveries
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
        let packages = try? LecturePackage.all(in: services.paths.phoneCaptures)
        let existing = packages.map { Set($0.compactMap { package in package.id.map { RecordingID($0) } }) }
        let sidecars = await receiptStore.load(existing: existing)
        guard started else { return }
        receipts = sidecars.receipts
        onMac = sidecars.onMac
        await directory.follow { [weak self] peers in
            await self?.trustChanged(peers)
        }
        pathWatch = Task { [weak self] in
            for await path in NWPathMonitor() where path.status == .satisfied {
                await self?.networkCameUp()
            }
        }
        relistNeeded = true
        requestSync()
    }

    /// Says goodbye and stops browsing and dialing.
    func stop() async {
        guard started else { return }
        started = false
        linkGeneration += 1
        syncGeneration += 1
        syncTask?.cancel()
        syncTask = nil
        quietRelist?.cancel()
        quietRelist = nil
        pathWatch?.cancel()
        pathWatch = nil
        let task = dialing.task
        dialing = .idle
        if let channel = session?.channel {
            await channel.close(Goodbye(reason: .shuttingDown), within: .seconds(1))
        }
        task?.cancel()
        await directory.stop()
        trusted = TrustedPeers()
        await releaseBackgroundTime()
        await attachRemote(false)
        deliveries?.finish()
        deliveries = nil
    }

    /// The scene's phase. Coming to the foreground reads the outbox again (the student may have
    /// deleted captures) and rebuilds the browser (iOS makes a suspended app's discovery defunct).
    func setActive(_ active: Bool) async {
        guard isActive != active else { return }
        isActive = active
        guard started else { return }
        if active {
            relistNeeded = true
            await dialAgain()
            requestSync()
        }
        await updateLink()
    }

    /// The recorder's newest snapshot (nil: nothing records). Quick: the sync it asks for runs
    /// in its own pass.
    func recorderChanged(_ new: RecorderSnapshot?) async {
        let old = snapshot
        snapshot = new
        let wasLive = old.map { $0.phase != .stopped } ?? false
        let isLive = new.map { $0.phase != .stopped } ?? false
        // A Stop, beginning or seen only once done: the time to send the rest is held for it.
        // `MacLink` began it already when it saw the Stop; it ends here when there is nothing to
        // send (no link, or the Mac has the recording).
        if new?.phase == .stopping || (wasLive && !isLive) {
            if canLink, let stopped = new?.recordingID ?? old?.recordingID, receipts[stopped] == nil {
                await holdBackgroundTime(for: stopped)
            } else if !holdsBackgroundTime {
                await backgroundTime.release()
            }
        }
        guard started else { return }
        if old?.recordingID != new?.recordingID || wasLive != isLive || old?.closedSegments != new?.closedSegments {
            relistNeeded = true
        }
        // Record, Pause, Resume and Stop dial again at once with a new browser, also out of a
        // backoff wait or after dialing gave up: after Stop the background time is the only
        // chance to send the rest.
        if old?.recordingID != new?.recordingID || old?.phase != new?.phase {
            await dialAgain()
        }
        await updateLink()
        requestSync()
    }

    /// iOS took the background time back.
    func backgroundTimeEnded() async {
        holdsBackgroundTime = false
        backgroundFor = nil
        await updateLink()
    }

    private func trustChanged(_ peers: TrustedPeers) async {
        let changed = peers != trusted
        trusted = peers
        if let session, !peers.contains(session.channel.peer.device) {
            await session.channel.close(Goodbye(reason: .untrusted), within: .seconds(1))
        }
        if !canLink { await releaseBackgroundTime() }
        // Another Mac may be reachable: dialing that gave up tries again.
        if changed, case .gaveUp = dialing { dialing = .idle }
        await updateLink()
    }

    /// A network path came up or changed: dialing that gave up tries again.
    private func networkCameUp() async {
        guard started, case .gaveUp = dialing else { return }
        LinkLog.link.info("The network changed; dialing again")
        await dialAgain()
    }

    /// Tells the recorder whether a remote that can send Resume is attached (only a change).
    private func attachRemote(_ attached: Bool) async {
        guard remoteAttached != attached else { return }
        remoteAttached = attached
        await recorder.setRemoteAttached(attached)
    }

    private func holdBackgroundTime(for recording: RecordingID) async {
        backgroundFor = recording
        holdsBackgroundTime = true
        await backgroundTime.hold()
    }

    private func releaseBackgroundTime() async {
        backgroundFor = nil
        guard holdsBackgroundTime else { return }
        holdsBackgroundTime = false
        await backgroundTime.release()
    }

    // MARK: - When to link

    private var isRecording: Bool {
        snapshot.map { $0.phase != .stopped } ?? false
    }

    /// A key, this phone's row and at least one trusted Mac.
    private var canLink: Bool {
        started && device != nil && secIdentity != nil && !trusted.isEmpty
    }

    private var wantsLink: Bool {
        canLink && (isRecording || holdsBackgroundTime || (isActive && !listing.entries.isEmpty))
    }

    /// Starts dialing when the phone wants a link (unless it gave up); says goodbye when it no
    /// longer does. Without a reason, giving up is forgotten: the next reason dials at once.
    private func updateLink() async {
        if wantsLink {
            guard case .idle = dialing else { return }
            linkGeneration += 1
            let generation = linkGeneration
            dialing = .running(Task { await self.dialLoop(generation) })
            return
        }
        if case .gaveUp = dialing { dialing = .idle }
        if let channel = session?.channel {
            await channel.close(Goodbye(reason: .done), within: .seconds(1))
        }
    }

    /// A new pass with a new browser now, unless a session is up; also after dialing gave up.
    private func dialAgain() async {
        guard session == nil else { return }
        if let task = dialing.task {
            task.cancel()
            linkGeneration += 1
        }
        dialing = .idle
        await updateLink()
    }

    // MARK: - Dialing

    private struct Browse: Sendable {
        var endpoints: [Bonjour.Endpoint]
        var accepted: Bool
    }

    private enum DialResult {
        /// No session (TLS or the hello failed, or nothing answered).
        case unreachable
        /// A session ran and ended, with the Mac's goodbye if it said one.
        case ended(Goodbye?)
    }

    /// Browses and dials while the phone wants a link: the Macs listed, wired ones first, else the
    /// last address that worked; the first to finish its hello wins. After a pass where none did,
    /// it waits 5, 10, 20, then 30 s, browsing meanwhile: a changed list ends the wait. After
    /// `LinkPolicy.maximumFailedPasses` such passes in a row it gives up until a reason to try
    /// again. When it ends, no remote is attached any more.
    private func dialLoop(_ generation: Int) async {
        var failedPasses = 0
        var gaveUp = false
        var previous: Set<String> = []
        passes: while !Task.isCancelled, wantsLink, generation == linkGeneration {
            let found: Browse
            if failedPasses == 0 {
                found = await Self.browse(for: Self.discoveryTime) { !$0.isEmpty }
            } else {
                let known = previous
                found = await Self.browse(for: LinkPolicy.dialDelay(failedPasses: failedPasses)) { endpoints in
                    !endpoints.isEmpty && Set(endpoints.map(\.id)) != known
                }
                if found.accepted { failedPasses = 0 }
            }
            guard !Task.isCancelled, wantsLink, generation == linkGeneration else { break }
            previous = Set(found.endpoints.map(\.id))
            var targets = Self.wiredFirst(found.endpoints).map(\.nwEndpoint)
            if targets.isEmpty, let lastEndpoint { targets = [lastEndpoint] }
            for target in targets {
                guard !Task.isCancelled, wantsLink, generation == linkGeneration else { break passes }
                if case .ended(let goodbye) = await dial(target) {
                    // A Mac that is quitting or refused this phone is not dialed again at once.
                    let refusals: [Goodbye.Reason] = [.shuttingDown, .untrusted, .unsupported, .protocolError]
                    failedPasses = refusals.contains { $0 == goodbye?.reason } ? 1 : 0
                    continue passes
                }
            }
            failedPasses += 1
            if !isActive, !isRecording, holdsBackgroundTime {
                LinkLog.link.notice("No Mac reachable after Stop; the rest goes when the app is open")
                await releaseBackgroundTime()
            }
            if failedPasses >= LinkPolicy.maximumFailedPasses {
                LinkLog.link.notice("No Mac in \(failedPasses) passes; dialing waits for a reason to try again")
                gaveUp = true
                break passes
            }
        }
        // A newer loop or `stop()` took over: theirs is the state.
        guard generation == linkGeneration else { return }
        dialing = gaveUp ? .gaveUp : .idle
        await attachRemote(false)
    }

    private func dial(_ endpoint: NWEndpoint) async -> DialResult {
        guard let secIdentity, let device else { return .unreachable }
        let directory = directory
        let parameters = DirectChannel.parameters(identity: secIdentity, peerToPeer: true) { fingerprint in
            await directory.isTrusted(fingerprint)
        }
        let hello = Hello.local(role: .iPhone, device: device, instance: instance)
        var linked = false
        var goodbye: Goodbye?
        do {
            try await withNetworkConnection(to: endpoint, using: parameters) { connection in
                let peer = try await DirectChannel.open(connection, hello: hello) { fingerprint in
                    await directory.devices(for: fingerprint)
                }
                linked = true
                lastEndpoint = connection.remoteEndpoint ?? endpoint
                goodbye = try await DirectChannel.run(connection, peer: peer) { channel in
                    try await self.runSession(channel, hello: hello)
                }
            }
        } catch {
            if linked {
                LinkLog.direct.notice("The Mac session ended: \(String(describing: error), privacy: .public)")
            } else {
                LinkLog.direct.info("Dialing \(String(describing: endpoint), privacy: .private) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return linked ? .ended(goodbye) : .unreachable
    }

    /// The Macs advertised now, waiting up to `limit` for a list `accept` takes; the last list
    /// seen otherwise (possibly empty). A new browser each time.
    private static func browse(for limit: Duration, accept: ([Bonjour.Endpoint]) -> Bool) async -> Browse {
        let (lists, sink) = AsyncStream.makeStream(of: [Bonjour.Endpoint].self, bufferingPolicy: .bufferingNewest(1))
        return await withTaskGroup(of: Void.self) { group in
            group.addTask {
                let parameters = NWParameters()
                parameters.includePeerToPeer = true
                let browser = NetworkBrowser(for: .bonjour(LinkProtocol.serviceType), using: parameters)
                do {
                    try await browser.run { endpoints in sink.yield(endpoints) }
                } catch where !(error is CancellationError) {
                    LinkLog.direct.notice("Browsing failed: \(String(describing: error), privacy: .public)")
                } catch {}
                sink.finish()
            }
            group.addTask {
                try? await Task.sleep(for: limit)
                sink.finish()
            }
            var latest: [Bonjour.Endpoint] = []
            var accepted = false
            for await list in lists {
                latest = list
                if accept(list) {
                    accepted = true
                    break
                }
            }
            group.cancelAll()
            return Browse(endpoints: latest, accepted: accepted)
        }
    }

    /// Endpoints on a wired interface (the USB cable) first.
    private static func wiredFirst(_ endpoints: [Bonjour.Endpoint]) -> [Bonjour.Endpoint] {
        func isWired(_ endpoint: Bonjour.Endpoint) -> Bool {
            endpoint.result.interfaces.contains { $0.type == .wiredEthernet }
        }
        return endpoints.filter(isWired) + endpoints.filter { !isWired($0) }
    }

    // MARK: - Session

    private func runSession(_ channel: any LinkChannel, hello: Hello) async throws {
        let peer = channel.peer
        let current = Session(
            channel: channel, controlOn: hello.allowsControl(with: peer.hello), filesOn: hello.allowsFiles(with: peer.hello)
        )
        let id = current.id
        session = current
        defer { if session?.id == id { session = nil } }
        // The Mac can send Resume: a pause keeps the input from now until dialing ends.
        if current.controlOn { await attachRemote(true) }
        let (wants, wantSink) = AsyncStream.makeStream(of: Want.self)
        defer { wantSink.finish() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await want in wants {
                    await self.answer(want, session: id)
                }
            }
            relistNeeded = true
            requestSync()
            for try await message in channel.messages {
                switch message {
                case .want(let want): wantSink.yield(want)
                case .stored(let stored): await noteStored(stored, session: id)
                case .received(let received): await noteReceived(received, session: id)
                case .command(let command): await run(command, on: channel, controlOn: current.controlOn)
                default: break
                }
            }
            group.cancelAll()
        }
    }

    /// Sends the bytes a want asks for, if they were offered on this session.
    private func answer(_ want: Want, session id: UUID) async {
        guard let session, session.id == id,
              let file = session.files[want.recording]?[want.path], want.from >= 0, want.from <= file.size
        else {
            LinkLog.outbox.notice("The Mac wanted \(want.path, privacy: .public) of \(want.recording.uuidString, privacy: .public), which is not offered")
            return
        }
        let channel = session.channel
        do {
            try await Outbox.stream(file.url, from: want.from, size: file.size, want: want.id) { chunk in
                try await channel.send(.chunk(chunk), lane: .bulk)
            }
        } catch is CancellationError {
        } catch is LinkChannelError {
        } catch {
            LinkLog.outbox.notice("Sending \(want.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            relistNeeded = true
            requestSync()
        }
    }

    /// Bytes of a file offered on session `id` are on the Mac (never more than the file has),
    /// kept in the capture's sidecar until the Mac answers for it.
    private func noteStored(_ stored: Stored, session id: UUID) async {
        guard let session, session.id == id, let file = session.files[stored.recording]?[stored.path] else {
            LinkLog.outbox.notice("The Mac stored \(stored.path, privacy: .public) of \(stored.recording.uuidString, privacy: .public), which is not offered; ignored")
            return
        }
        // Answered already: the sidecar holds the answer, never bytes again.
        guard receipts[stored.recording] == nil else { return }
        let known = onMac[stored.recording]?[stored.path] ?? 0
        let bytes = max(known, min(stored.bytes, file.size))
        guard bytes != known else { return }
        onMac[stored.recording, default: [:]][stored.path] = bytes
        emitDeliveries()
        let held = onMac[stored.recording] ?? [:]
        do {
            try await receiptStore.write(.copying(onMac: held), for: stored.recording, at: Date())
        } catch {
            LinkLog.outbox.error("Keeping the Mac's bytes failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The Mac's answer for a recording offered on session `id`: its receipt is written and it is
    /// never offered again. An answer for anything else is dropped: a receipt the Mac did not earn
    /// would show "On Mac" for a capture it never got.
    private func noteReceived(_ received: Received, session id: UUID) async {
        guard let session, session.id == id, session.toldOffers[received.recording] != nil else {
            LinkLog.outbox.notice("The Mac answered for \(received.recording.uuidString, privacy: .public), which this session did not offer; ignored")
            return
        }
        receipts[received.recording] = received.outcome
        do {
            try await receiptStore.write(.answered(received.outcome), for: received.recording, at: Date())
        } catch {
            LinkLog.outbox.error("Writing a receipt failed: \(error.localizedDescription, privacy: .public)")
        }
        LinkLog.outbox.notice("The Mac answered \(received.outcome.rawValue, privacy: .public) for \(received.recording.uuidString, privacy: .public)")
        onMac[received.recording] = nil
        listing.entries.removeAll { $0.id == received.recording }
        emitDeliveries()
        if received.recording == backgroundFor { await releaseBackgroundTime() }
        requestSync()
        await updateLink()
    }

    private func run(_ command: RecorderCommand, on channel: any LinkChannel, controlOn: Bool) async {
        var command = command
        command.origin = .remote
        let outcome: RecorderOutcome
        if controlOn {
            let stops = command.action.kind == .stop
            // Stop ends the audio session before the package is closed: on a locked phone iOS may
            // suspend the app from then on, so the time to finish it and send it comes first.
            if stops, canLink, receipts[command.recordingID] == nil {
                await holdBackgroundTime(for: command.recordingID)
            }
            outcome = await recorder.perform(command)
            let stopped = outcome.snapshot.map { $0.recordingID == command.recordingID && $0.phase == .stopped } ?? false
            if stops, !stopped, backgroundFor == command.recordingID {
                await releaseBackgroundTime()
            }
        } else {
            outcome = RecorderOutcome(commandID: command.id, result: .rejected(.noRecording), snapshot: nil)
        }
        try? await channel.send(.result(outcome), lane: .control)
    }

    // MARK: - Telling the Mac

    /// Brings the Mac up to date in a pass the agent owns, one at a time (a request meanwhile
    /// runs one more). Callers never wait for it.
    private func requestSync() {
        guard started else { return }
        guard syncTask == nil else {
            syncAgain = true
            return
        }
        syncGeneration += 1
        let generation = syncGeneration
        syncTask = Task { await self.syncPasses(generation) }
    }

    private func syncPasses(_ generation: Int) async {
        repeat {
            syncAgain = false
            await syncOnce()
        } while syncAgain && started && generation == syncGeneration
        if generation == syncGeneration { syncTask = nil }
    }

    private func syncOnce() async {
        if relistNeeded {
            relistNeeded = false
            let stopped = snapshot.flatMap { $0.phase == .stopped ? $0.recordingID : nil }
            // A listing that failed keeps the last one: an empty one would tell the Mac the
            // student deleted every capture.
            if let fresh = await Outbox.list(
                in: services.paths.phoneCaptures, live: liveRecording, settled: stopped, skipping: Set(receipts.keys), now: Date()
            ) {
                listing = fresh
                listingVersion += 1
                // A finished capture's total is its whole recording, also when no new offer goes
                // (the link dropped before Stop): a bar never looks full for what is still here.
                for entry in listing.entries { totals[entry.id] = entry.totalBytes }
                let urls = Set(listing.entries.flatMap { $0.files.map(\.url) })
                hashes = hashes.filter { urls.contains($0.key) }
                scheduleQuietRelist(at: listing.quietUntil)
                emitDeliveries()
                await updateLink()
            }
        }
        guard let current = session else { return }
        let id = current.id
        let channel = current.channel
        do {
            if current.filesOn, current.toldListing != listingVersion {
                let version = listingVersion
                // Everything still on the phone without the Mac's answer, offered now or not: the
                // Mac deletes the staging of any recording left out.
                let holdings = listing.all.subtracting(receipts.keys).sorted { $0.uuidString < $1.uuidString }
                if current.toldHoldings != holdings {
                    try await channel.send(.holdings(Holdings(recordings: holdings)), lane: .control)
                    update(id) { $0.toldHoldings = holdings }
                }
                let ordered = listing.entries.filter(\.isFinal)
                    + listing.entries.filter { !$0.isFinal && !$0.isLive }
                    + listing.entries.filter(\.isLive)
                for entry in ordered {
                    guard let offer = await offer(for: entry) else {
                        // Deleted meanwhile, or unreadable: read again at the next change, never in a loop.
                        relistNeeded = true
                        continue
                    }
                    guard session?.id == id, session?.toldOffers[entry.id] != offer else { continue }
                    let files = Dictionary(entry.files.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
                    // Noted before it goes: the Mac's answer may come before this pass resumes.
                    update(id) {
                        $0.files[entry.id] = files
                        $0.toldOffers[entry.id] = offer
                    }
                    totals[entry.id] = offer.totalBytes
                    emitDeliveries()
                    try await channel.send(.offer(offer), lane: .control)
                }
                update(id) { $0.toldListing = version }
            }
            // A change during this pass runs another one, which lists and offers first: a Stop
            // that came in meanwhile so never reaches the Mac before the recording's final offer.
            guard current.controlOn, !syncAgain, let told = session, told.id == id else { return }
            if !told.hasToldSnapshot || told.toldSnapshot != snapshot {
                let now = snapshot
                try await channel.send(.snapshot(SnapshotMessage(snapshot: now, at: Date())), lane: .control)
                update(id) {
                    $0.hasToldSnapshot = true
                    $0.toldSnapshot = now
                }
            }
        } catch {
            // The channel ended; the next session starts over.
        }
    }

    /// Lists again once the first capture left out for changing recently may be offered (a
    /// capture recovered after a kill mid-recording, a recording left paused and taken up).
    private func scheduleQuietRelist(at date: Date?) {
        quietRelist?.cancel()
        quietRelist = nil
        guard let date else { return }
        let wait = max(0, date.timeIntervalSinceNow) + 1
        quietRelist = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                return
            }
            await self?.quietPeriodEnded()
        }
    }

    private func quietPeriodEnded() {
        relistNeeded = true
        requestSync()
    }

    private func update(_ id: UUID, _ change: (inout Session) -> Void) {
        guard var current = session, current.id == id else { return }
        change(&current)
        session = current
    }

    private var liveRecording: Outbox.Live? {
        guard let snapshot, snapshot.phase != .stopped else { return nil }
        return Outbox.Live(id: snapshot.recordingID, closedSegments: snapshot.closedSegments, title: snapshot.sessionName)
    }

    private func offer(for entry: Outbox.Entry) async -> Offer? {
        let urls = Set(entry.files.map(\.url))
        let known = hashes.filter { urls.contains($0.key) }
        guard let made = await Outbox.offer(for: entry, known: known) else { return nil }
        hashes.merge(made.hashes) { _, new in new }
        return made.offer
    }

    /// What the Mac holds of each capture: received (or known there), else the bytes it
    /// acknowledged (also in an earlier run, from the sidecar).
    private func emitDeliveries() {
        var deliveries: [UUID: CaptureDelivery] = [:]
        for id in listing.all {
            if let outcome = receipts[id] {
                if outcome != .refused { deliveries[id.rawValue] = .onMac }
            } else if let bytes = onMac[id], let total = totals[id], total > 0 {
                let stored = bytes.values.reduce(0, +)
                deliveries[id.rawValue] = .sending(onMac: min(stored, total), total: total)
            }
        }
        guard deliveries != lastDeliveries else { return }
        lastDeliveries = deliveries
        self.deliveries?.yield(deliveries)
    }
}
