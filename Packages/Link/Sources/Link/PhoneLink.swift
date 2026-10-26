import Foundation
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
    /// the first snapshot of a new connection, cleared by a nil snapshot, and kept frozen for
    /// `LinkPolicy.frozenLifetime` after the phone was last seen.
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

    @ObservationIgnored private let services: StudyServices?
    @ObservationIgnored private let file: (@MainActor @Sendable (URL) async -> Void)?

    private init(services: StudyServices?, file: (@MainActor @Sendable (URL) async -> Void)?, now: Date) {
        self.services = services
        self.file = file
        self.now = now
    }

    /// The Mac's link over `services`' library; `file` files a package that arrived in
    /// `AppPaths.recordings` (the app's `filingCenter.file([url])`). Starts nothing.
    public static func mac(services: StudyServices, file: @escaping @MainActor @Sendable (URL) async -> Void) -> PhoneLink {
        PhoneLink(services: services, file: file, now: Date())
    }

    /// Starts listening (idempotent). The link's service and its tasks arrive with the Link
    /// implementation; until then the link stays off.
    public func start() {}

    /// Says goodbye to every session and stops listening.
    public func stop() {}

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
        guard canSend(action) else { return }
    }

    #if DEBUG
    /// A link that shows `recording` and `arrivals` with control on and never connects (parity
    /// renders).
    public static func preview(
        recording: RemoteRecording?, arrivals: [Arrival], problem: RemoteProblem?, now: Date
    ) -> PhoneLink {
        let link = PhoneLink(services: nil, file: nil, now: now)
        link.recording = recording
        link.arrivals = arrivals
        link.problem = problem
        link.isControlOn = true
        return link
    }
    #endif
}
