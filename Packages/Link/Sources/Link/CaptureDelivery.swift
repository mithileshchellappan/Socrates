/// What the Mac holds of one capture in the phone's outbox.
public enum CaptureDelivery: Hashable, Sendable {
    /// Copying: `onMac` of `total` bytes are on the Mac's disk (from its acknowledgements in this
    /// run).
    case sending(onMac: Int64, total: Int64)
    /// The Mac has the recording (it took it, or had it already).
    case onMac
}
