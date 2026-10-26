import Foundation
import LinkCore
import Observation
import RecorderContract
import StudyCore

/// The Mac's side of the recording link, the only thing its views read: the iPhone's recording
/// (shown and controlled from the menu bar extra, the toolbar capsule and the Lecture menu) and
/// the recordings arriving from it. Made by the app only in the iCloud build (trust comes from the
/// synced `link_device` rows); it owns the service that listens, and every task it starts.
///
/// No optimistic state: a button stays pressed (`pending`) until the phone's result or the loss
/// of the connection, and Resume appears only after a paused snapshot.
@MainActor
@Observable
public final class PhoneLink {
    /// The phone's recording: newest snapshot first (`RecorderSnapshot.supersedes`), replaced by
    /// the first snapshot of a new connection, cleared by a nil or stopped snapshot, and kept
    /// frozen for `LinkPolicy.frozenLifetime` after the phone was last seen.
    public private(set) var recording: RemoteRecording?
    /// Recordings being copied, from their final offer until the Mac has them.
    public private(set) var arrivals: [Arrival] = []
    /// Buttons pressed and not answered yet.
    public private(set) var pending: Set<RemoteAction> = []
    /// The last remote command the phone could not do; cleared by the next action.
    public private(set) var problem: RemoteProblem?
    /// The clock the views count with: ticks each second only while a live recording runs.
    public private(set) var now: Date
    /// Both hellos list `control` with the same recorder contract.
    private(set) var isControlOn = false

    @ObservationIgnored private let service: MacLinkService?
    @ObservationIgnored private var isStarted = false
    /// The service's events, applied here.
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// Start and stop, one after the other.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    /// The command waiting for its outcome (one at a time: nothing is sent while one is pending).
    @ObservationIgnored private var command: Task<Void, Never>?
    @ObservationIgnored private var ticker: Task<Void, Never>?
    /// Drops a frozen recording at the end of its lifetime.
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// The phone whose recording is shown.
    @ObservationIgnored private var shownDevice: LinkDeviceID?
    /// Phones linked now with control on.
    @ObservationIgnored private var controlDevices: Set<LinkDeviceID> = []

    private init(service: MacLinkService?, now: Date) {
        self.service = service
        self.now = now
    }

    isolated deinit {
        consumer?.cancel()
        lifecycle?.cancel()
        command?.cancel()
        ticker?.cancel()
        expiry?.cancel()
    }

    /// The Mac's link over `services`' library; `file` files a package that arrived in
    /// `AppPaths.recordings` (the app's `filingCenter.file([url])`). Starts nothing.
    public static func mac(services: StudyServices, file: @escaping @MainActor @Sendable (URL) async -> Void) -> PhoneLink {
        PhoneLink(service: MacLinkService(services: services, file: file), now: Date())
    }

    /// Starts listening (idempotent).
    public func start() {
        guard let service, !isStarted else { return }
        isStarted = true
        let (events, sink) = AsyncStream.makeStream(of: MacLinkEvent.self)
        consumer = Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
        enqueue { await service.start(events: sink) }
    }

    /// Says goodbye to every session and stops listening.
    public func stop() {
        guard let service, isStarted else { return }
        isStarted = false
        consumer?.cancel()
        consumer = nil
        command?.cancel()
        command = nil
        expiry?.cancel()
        expiry = nil
        recording = nil
        arrivals = []
        pending = []
        problem = nil
        shownDevice = nil
        controlDevices = []
        refreshControl()
        updateTicker()
        enqueue { await service.stop() }
    }

    /// Whether the menu bar extra and the toolbar capsule show.
    public var showsItem: Bool { recording != nil || !arrivals.isEmpty }

    /// Whether `action`'s button works now: the phone is reachable, control is on, its snapshot
    /// accepts the command and nothing is pending.
    public func canSend(_ action: RemoteAction) -> Bool {
        guard let recording, recording.isLive, isControlOn, pending.isEmpty else { return false }
        return recording.snapshot.accepts.contains(action.kind)
    }

    /// Sends `action` as a fresh command (origin remote; Pause and Resume carry the snapshot's
    /// sequence as their basis, Next Slide the slide shown).
    public func send(_ action: RemoteAction) {
        guard canSend(action), let service, let snapshot = recording?.snapshot else { return }
        problem = nil
        let id = snapshot.recordingID
        let command: RecorderCommand = switch action {
        case .pause: .fresh(.pause, recordingID: id, origin: .remote, basis: snapshot.sequence)
        case .resume: .fresh(.resume, recordingID: id, origin: .remote, basis: snapshot.sequence)
        case .nextSlide: .fresh(.nextSlide(from: snapshot.slide), recordingID: id, origin: .remote)
        case .stop: .fresh(.stop, recordingID: id, origin: .remote)
        }
        pending.insert(action)
        self.command = Task { [weak self] in
            let outcome = await service.perform(command)
            self?.finish(action, outcome: outcome)
        }
    }

    private func finish(_ action: RemoteAction, outcome: RecorderOutcome?) {
        pending.remove(action)
        command = nil
        guard let outcome else {
            LinkLog.link.notice("A remote command went unanswered")
            return
        }
        if case .failed(let failure) = outcome.result {
            problem = RemoteProblem(action: action, failure: failure)
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = lifecycle
        lifecycle = Task {
            await previous?.value
            await work()
        }
    }

    // MARK: - Events

    private func apply(_ event: MacLinkEvent) {
        switch event {
        case .connected(let device, let controlOn):
            if controlOn {
                controlDevices.insert(device)
            } else {
                controlDevices.remove(device)
            }
            refreshControl()
        case .snapshot(let message, let device, let isFirst):
            show(message, from: device, isFirst: isFirst)
        case .disconnected(let device):
            controlDevices.remove(device)
            if device == shownDevice, var shown = recording, shown.isLive {
                let lost = Date()
                shown.freshness = .lastSeen(lost)
                recording = shown
                scheduleExpiry(after: lost)
            }
            refreshControl()
            updateTicker()
        case .arrival(let arrival):
            if let index = arrivals.firstIndex(where: { $0.id == arrival.id }) {
                arrivals[index] = arrival
            } else {
                arrivals.append(arrival)
            }
        case .arrived(let id):
            arrivals.removeAll { $0.id == id }
        }
    }

    private func show(_ message: SnapshotMessage, from device: LinkDeviceID, isFirst: Bool) {
        guard let snapshot = message.snapshot, snapshot.phase != .stopped else {
            // Nothing records on that phone any more (or it stopped): the item goes.
            if shownDevice == nil || shownDevice == device || message.snapshot?.recordingID == recording?.snapshot.recordingID {
                clearRecording()
            }
            return
        }
        let replaces = isFirst && (shownDevice == nil || shownDevice == device || recording?.isLive != true)
        guard replaces || snapshot.supersedes(recording?.snapshot) else { return }
        let received = Date()
        recording = RemoteRecording(
            snapshot: snapshot, freshness: .live, elapsedAtReceipt: message.elapsed, isRunning: message.isRunning, receivedAt: received
        )
        shownDevice = device
        now = received
        expiry?.cancel()
        expiry = nil
        refreshControl()
        updateTicker()
    }

    private func clearRecording() {
        recording = nil
        shownDevice = nil
        expiry?.cancel()
        expiry = nil
        refreshControl()
        updateTicker()
    }

    private func refreshControl() {
        let on = shownDevice.map(controlDevices.contains) ?? false
        if isControlOn != on { isControlOn = on }
    }

    /// Counts the seconds only while a live recording runs.
    private func updateTicker() {
        let runs = recording?.isLive == true && recording?.isRunning == true
        if runs {
            guard ticker == nil else { return }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                    } catch {
                        return
                    }
                    self?.now = Date()
                }
            }
        } else {
            ticker?.cancel()
            ticker = nil
            now = Date()
        }
    }

    private func scheduleExpiry(after lost: Date) {
        expiry?.cancel()
        expiry = Task { [weak self] in
            do {
                try await Task.sleep(for: LinkPolicy.frozenLifetime)
            } catch {
                return
            }
            guard let self, case .lastSeen(lost)? = self.recording?.freshness else { return }
            self.clearRecording()
        }
    }

    #if DEBUG
    /// A link that shows `recording` and `arrivals` with control on and never connects (parity
    /// renders).
    public static func preview(
        recording: RemoteRecording?, arrivals: [Arrival], problem: RemoteProblem?, now: Date
    ) -> PhoneLink {
        let link = PhoneLink(service: nil, now: now)
        link.recording = recording
        link.arrivals = arrivals
        link.problem = problem
        link.isControlOn = true
        return link
    }
    #endif
}
