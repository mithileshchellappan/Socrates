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
    @ObservationIgnored private let backgroundTime: LinkBackgroundTime
    @ObservationIgnored private var isStarted = false
    /// The agent's deliveries, shown here.
    @ObservationIgnored private var consumer: Task<Void, Never>?
    /// The recorder's snapshots, handed to the agent.
    @ObservationIgnored private var snapshots: Task<Void, Never>?
    /// Start, stop and scene changes, one after the other.
    @ObservationIgnored private var lifecycle: Task<Void, Never>?

    private init(services: StudyServices?, recorder: (any RecorderEndpoint)?, beginBackgroundTime: BeginBackgroundTime?) {
        let backgroundTime = LinkBackgroundTime(begin: beginBackgroundTime)
        self.backgroundTime = backgroundTime
        agent = services.flatMap { services in
            recorder.map { PhoneLinkAgent(services: services, recorder: $0, backgroundTime: backgroundTime) }
        }
        self.recorder = recorder
    }

    isolated deinit {
        consumer?.cancel()
        snapshots?.cancel()
        lifecycle?.cancel()
        backgroundTime.release()
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
        backgroundTime.onExpiry = { [weak self] in
            self?.backgroundTimeExpired()
        }
        let (updates, sink) = AsyncStream.makeStream(of: [UUID: CaptureDelivery].self)
        consumer = Task { [weak self] in
            for await latest in updates {
                self?.deliveries = latest
            }
        }
        let stream = recorder.snapshots()
        let backgroundTime = backgroundTime
        snapshots = Task {
            var wasLive = false
            for await snapshot in stream {
                let isLive = snapshot.map { $0.phase != .stopped } ?? false
                // Stop ends the audio session before the package is closed and sent: the time to
                // finish begins here, before the agent hears of it (it ends the time when there
                // is nothing to send).
                if snapshot?.phase == .stopping || (wasLive && !isLive) {
                    backgroundTime.hold()
                }
                wasLive = isLive
                await agent.recorderChanged(snapshot)
            }
        }
        enqueue { await agent.start(deliveries: sink) }
    }

    /// Says goodbye and stops browsing and dialing.
    public func stop() {
        guard let agent, isStarted else { return }
        isStarted = false
        consumer?.cancel()
        consumer = nil
        snapshots?.cancel()
        snapshots = nil
        backgroundTime.release()
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

    /// iOS took the background time back: the agent stops counting on it.
    private func backgroundTimeExpired() {
        guard let agent else { return }
        enqueue { await agent.backgroundTimeEnded() }
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
