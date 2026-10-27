import Foundation
import Observation
import RecorderContract
import StudyCore

/// The Mac's side of the recording link, the only thing its views read: the iPhone's recording
/// (shown and controlled from the menu bar extra, the toolbar capsule and the Lecture menu) and
/// the recordings arriving from it. Made by the app only in the iCloud build (trust comes from the
/// synced `link_device` rows); it owns the service that listens, and every task it starts.
///
/// It decides nothing about the phone: the service owns the recording's lifetime and the arrival
/// rows, and this model stores what it is told and counts the seconds.
///
/// No optimistic state: a button stays pressed (`pending`) until the phone's result and the
/// snapshot that shows it, or the loss of the connection, and Resume appears only after a paused
/// snapshot.
@MainActor
@Observable
public final class PhoneLink {
    /// What the menu bar label and the toolbar capsule draw.
    public enum Item: Hashable, Sendable {
        /// The phone's recording: while it records or pauses (also frozen), or while it stops with
        /// nothing arriving.
        case recording(RemoteRecording)
        /// The bytes arriving, every arrival together.
        case arriving(stored: Int64, total: Int64)
    }

    /// The phone's recording as the service shows it: the newest snapshot, live or frozen at the
    /// last byte heard; gone once it stopped, was filed here another way, or was not heard of for
    /// `LinkPolicy.frozenLifetime`.
    public private(set) var recording: RemoteRecording?
    /// Recordings being copied, from their final offer until the Mac has them.
    public private(set) var arrivals: [Arrival] = []
    /// Buttons pressed and not answered yet.
    public private(set) var pending: Set<RemoteAction> = []
    /// The last remote command the phone could not do; cleared by the next action, and when
    /// another recording or a new phase shows.
    public private(set) var problem: RemoteProblem?
    /// The clock the views count with: ticks each second only while a live recording runs.
    public private(set) var now: Date
    /// The shown recording's phone is linked and takes commands.
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
    /// A button whose result came first: it stays pressed until a snapshot at least this new shows
    /// (the phone sends the result before the snapshot with its effect).
    @ObservationIgnored private var awaited: (action: RemoteAction, sequence: Int)?

    private init(service: MacLinkService?, now: Date) {
        self.service = service
        self.now = now
    }

    isolated deinit {
        consumer?.cancel()
        lifecycle?.cancel()
        command?.cancel()
        ticker?.cancel()
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
        awaited = nil
        recording = nil
        arrivals = []
        pending = []
        problem = nil
        isControlOn = false
        updateTicker()
        enqueue { await service.stop() }
    }

    /// Whether the menu bar extra and the toolbar capsule show.
    public var showsItem: Bool { recording != nil || !arrivals.isEmpty }

    /// What the label and the capsule draw: the recording while it records or pauses (also
    /// frozen), else the bytes arriving, else a recording that is stopping; nil: nothing.
    public var item: Item? {
        if let recording, recording.snapshot.phase == .recording || recording.snapshot.phase == .paused {
            return .recording(recording)
        }
        if !arrivals.isEmpty {
            let stored = arrivals.reduce(Int64(0)) { $0 + $1.stored }
            let total = arrivals.reduce(Int64(0)) { $0 + $1.total }
            return .arriving(stored: stored, total: total)
        }
        return recording.map(Item.recording)
    }

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
        command = nil
        guard let outcome else {
            pending.remove(action)
            LinkLog.link.notice("A remote command went unanswered")
            return
        }
        if case .failed(let failure) = outcome.result {
            problem = RemoteProblem(action: action, failure: failure)
        } else if let after = outcome.snapshot, let shown = recording, shown.isLive,
                  shown.snapshot.recordingID == after.recordingID, shown.snapshot.sequence < after.sequence {
            // No control is drawn from a state the phone has already left.
            awaited = (action, after.sequence)
            return
        }
        pending.remove(action)
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
        case .recording(let next, let controlOn):
            let previous = recording
            recording = next
            if isControlOn != controlOn { isControlOn = controlOn }
            if next?.snapshot.recordingID != previous?.snapshot.recordingID
                || next?.snapshot.phaseSince != previous?.snapshot.phaseSince {
                problem = nil
            }
            if let awaited, next.map({ !$0.isLive || $0.snapshot.sequence >= awaited.sequence }) ?? true {
                pending.remove(awaited.action)
                self.awaited = nil
            }
            now = Date()
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

    #if DEBUG
    /// A link that shows `recording` and `arrivals` with control on and never connects (parity
    /// renders); `pending`: buttons held in, waiting for the phone's answer.
    public static func preview(
        recording: RemoteRecording?, arrivals: [Arrival], problem: RemoteProblem?, pending: Set<RemoteAction> = [], now: Date
    ) -> PhoneLink {
        let link = PhoneLink(service: nil, now: now)
        link.recording = recording
        link.arrivals = arrivals
        link.problem = problem
        link.pending = pending
        link.isControlOn = true
        return link
    }
    #endif
}
