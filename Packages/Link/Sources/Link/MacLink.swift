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

    @ObservationIgnored private let services: StudyServices?
    @ObservationIgnored private let recorder: (any RecorderEndpoint)?
    @ObservationIgnored private let beginBackgroundTime: BeginBackgroundTime?

    private init(services: StudyServices?, recorder: (any RecorderEndpoint)?, beginBackgroundTime: BeginBackgroundTime?) {
        self.services = services
        self.recorder = recorder
        self.beginBackgroundTime = beginBackgroundTime
    }

    /// The phone's link over `services`' library and `recorder`. Starts nothing.
    public static func phone(
        services: StudyServices, recorder: any RecorderEndpoint, beginBackgroundTime: @escaping BeginBackgroundTime
    ) -> MacLink {
        MacLink(services: services, recorder: recorder, beginBackgroundTime: beginBackgroundTime)
    }

    /// Starts following the recorder and the outbox (idempotent). The link's agent and its tasks
    /// arrive with the Link implementation; until then the link stays off.
    public func start() {}

    /// Says goodbye and stops browsing and dialing.
    public func stop() {}

    /// The scene's phase: active lets the phone link for undelivered captures and rebuilds its
    /// browser (iOS makes a suspended app's discovery defunct).
    public func setActive(_ isActive: Bool) {}

    /// What the Mac holds of the capture `capture`; nil: nothing known (the row stays as it is).
    public func delivery(of capture: UUID) -> CaptureDelivery? {
        deliveries[capture]
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
