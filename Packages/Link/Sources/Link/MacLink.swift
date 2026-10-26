import Foundation
import Observation
import RecorderContract
import StudyCore

/// The iPhone's side of the recording link: copies its recordings to the Mac by themselves and
/// runs the Mac's commands through the recorder's one entry (`RecorderEndpoint`). Its views read
/// only `deliveries` (the outbox rows). Made by the app only in the iCloud build; it owns the
/// agent that browses and dials, and every task it starts.
@MainActor
@Observable
public final class MacLink {
    /// Asks iOS for time to finish after the app leaves the foreground (UIKit's
    /// `beginBackgroundTask`, which the app wraps): `name` for the system's log, `expired` called
    /// when the time is up; returns the call that ends it.
    public typealias BeginBackgroundTime = @MainActor (
        _ name: String, _ expired: @escaping @MainActor @Sendable () -> Void
    ) -> @MainActor @Sendable () -> Void

    /// What the Mac holds of each outbox capture (by the capture's id, `PhoneCapture.ID`), known
    /// from its acknowledgements in this run and from the receipts kept beside the outbox.
    public private(set) var deliveries: [UUID: CaptureDelivery] = [:]

    @ObservationIgnored private let agent: PhoneLinkAgent?
    @ObservationIgnored private let recorder: (any RecorderEndpoint)?
    @ObservationIgnored private let beginBackgroundTime: BeginBackgroundTime?
    @ObservationIgnored private var isStarted = false
    /// The agent's events, shown here.
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// The recorder's snapshots, handed to the agent.
    @ObservationIgnored private var snapshots: Task<Void, Never>?
    /// Start, stop and scene changes, one after the other.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var endBackgroundTime: (@MainActor @Sendable () -> Void)?

    private init(services: StudyServices?, recorder: (any RecorderEndpoint)?, beginBackgroundTime: BeginBackgroundTime?) {
        agent = services.flatMap { services in recorder.map { PhoneLinkAgent(services: services, recorder: $0) } }
        self.recorder = recorder
        self.beginBackgroundTime = beginBackgroundTime
    }

    isolated deinit {
        consumer?.cancel()
        snapshots?.cancel()
        lifecycle?.cancel()
        endBackgroundTime?()
    }

    /// The phone's link over `services`' library and `recorder`. Starts nothing.
    public static func phone(
        services: StudyServices, recorder: any RecorderEndpoint, beginBackgroundTime: @escaping BeginBackgroundTime
    ) -> MacLink {
        MacLink(services: services, recorder: recorder, beginBackgroundTime: beginBackgroundTime)
    }

    /// Starts following the recorder and the outbox, and links when there is a reason to
    /// (idempotent).
    public func start() {
        guard let agent, let recorder, !isStarted else { return }
        isStarted = true
        let (events, sink) = AsyncStream.makeStream(of: PhoneLinkAgent.Event.self)
        consumer = Task { [weak self] in
            for await event in events {
                self?.apply(event)
            }
        }
        let stream = recorder.snapshots()
        snapshots = Task {
            for await snapshot in stream {
                await agent.recorderChanged(snapshot)
            }
        }
        enqueue { await agent.start(events: sink) }
    }

    /// Says goodbye and stops browsing and dialing.
    public func stop() {
        guard let agent, isStarted else { return }
        isStarted = false
        consumer?.cancel()
        consumer = nil
        snapshots?.cancel()
        snapshots = nil
        finishBackgroundTime()
        deliveries = [:]
        enqueue { await agent.stop() }
    }

    /// The scene's phase: active lets the phone link for undelivered captures and rebuilds its
    /// browser (iOS makes a suspended app's discovery defunct).
    public func setActive(_ isActive: Bool) {
        guard let agent else { return }
        enqueue { await agent.setActive(isActive) }
    }

    /// What the Mac holds of the capture `capture`; nil: nothing known (the row stays as it is).
    public func delivery(of capture: UUID) -> CaptureDelivery? {
        deliveries[capture]
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = lifecycle
        lifecycle = Task {
            await previous?.value
            await work()
        }
    }

    private func apply(_ event: PhoneLinkAgent.Event) {
        switch event {
        case .deliveries(let latest):
            deliveries = latest
        case .backgroundTime(true):
            guard endBackgroundTime == nil, let beginBackgroundTime else { return }
            endBackgroundTime = beginBackgroundTime("Socrates recording link") { [weak self] in
                self?.backgroundTimeExpired()
            }
        case .backgroundTime(false):
            finishBackgroundTime()
        }
    }

    private func backgroundTimeExpired() {
        finishBackgroundTime()
        guard let agent else { return }
        enqueue { await agent.backgroundTimeEnded() }
    }

    private func finishBackgroundTime() {
        endBackgroundTime?()
        endBackgroundTime = nil
    }

    #if DEBUG
    /// A link that shows `deliveries` and never connects (parity renders).
    public static func preview(deliveries: [UUID: CaptureDelivery]) -> MacLink {
        let link = MacLink(services: nil, recorder: nil, beginBackgroundTime: nil)
        link.deliveries = deliveries
        return link
    }
    #endif
}
