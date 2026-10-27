/// What the Mac holds of one capture in the phone's outbox.
public enum CaptureDelivery: Hashable, Sendable {
    /// Copying: `onMac` of `total` bytes are on the Mac's disk (from its acknowledgements, kept
    /// beside the outbox until it answers).
    case sending(onMac: Int64, total: Int64)
    /// The Mac has the recording (it took it, or had it already).
    case onMac
}
