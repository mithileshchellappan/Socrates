import Foundation
import LinkCore
import RecorderContract

/// What the Mac's link service tells `PhoneLink`, in order.
enum MacLinkEvent: Sendable {
    /// A phone's session began; `controlOn`: both hellos list control with the same recorder
    /// contract.
    case connected(LinkDeviceID, controlOn: Bool)
    /// A phone's recorder state; `isFirst`: the first of its session, which replaces what was
    /// shown.
    case snapshot(SnapshotMessage, from: LinkDeviceID, isFirst: Bool)
    /// A phone's session ended (lost, a goodbye, or replaced by none).
    case disconnected(LinkDeviceID)
    /// A recording being received: shown from its final offer, its progress as bytes are stored.
    case arrival(Arrival)
    /// The Mac took the recording (or will not): its row goes.
    case arrived(RecordingID)
}
