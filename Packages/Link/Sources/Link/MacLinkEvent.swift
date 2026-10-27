import Foundation
import LinkCore
import RecorderContract

/// What the Mac's link service tells `PhoneLink`, in order. The service decides; `PhoneLink` only
/// stores what it is told.
enum MacLinkEvent: Sendable {
    /// The phone recording to show now (nil: none), and whether its phone takes commands now
    /// (linked, both hellos list control with the same recorder contract).
    case recording(RemoteRecording?, controlOn: Bool)
    /// A recording being received: shown from its final offer, its progress as bytes are stored.
    case arrival(Arrival)
    /// Its row goes: the Mac took the recording or will not, or the copy stopped (the phone's
    /// session ended, or the phone no longer has it). A later final offer brings it back.
    case arrived(RecordingID)
}
