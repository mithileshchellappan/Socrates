/// The recorder as a remote sees it: its snapshots and its one command entry. The Mac remote's
/// link goes through this boundary and nothing else (`PhoneRecorder` conforms in `Recorder`), so
/// the link depends on the contract, never on the recorder's model. The Live Activity keeps
/// `RecorderControl`, its hook across the app–extension boundary.
@MainActor
public protocol RecorderEndpoint: AnyObject, Sendable {
    /// The current snapshot first, then every change; nil while nothing records. Ends when the
    /// caller stops iterating.
    func snapshots() -> AsyncStream<RecorderSnapshot?>

    /// Runs one command through the recorder's rules (applied once by id, checked against the
    /// state now) and answers with the state after it.
    func perform(_ command: RecorderCommand) async -> RecorderOutcome

    /// Whether a remote that can send Resume is attached (linked, or reconnecting). While it is,
    /// a pause keeps the input claimed without recording, so the system keeps the app running and
    /// the remote's Resume works with the phone locked; once it is not, the input is given up as
    /// after any pause. Queued with the commands; the last call wins.
    func setRemoteAttached(_ attached: Bool)
}
