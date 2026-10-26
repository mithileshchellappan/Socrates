import Observation
import RecorderContract

// The recorder as the Mac remote reaches it (`RecorderEndpoint`, declared with the class; README
// "Recorder contract", Endpoint): the link reads the published snapshot and sends commands
// through `perform(_:)`, the same door as the screen and the Live Activity, so a remote command
// is checked and applied by the same rules.

extension PhoneRecorder {
    /// `snapshot` now, then every change (nil while nothing records), newest only: a reader that
    /// falls behind skips to the latest state, which is complete. Ends when the recorder goes;
    /// the observation stops when the reader stops iterating.
    public func snapshots() -> AsyncStream<RecorderSnapshot?> {
        let (stream, continuation) = AsyncStream.makeStream(of: RecorderSnapshot?.self, bufferingPolicy: .bufferingNewest(1))
        let changes = Observations.untilFinished { @MainActor [weak self] () -> Observations<RecorderSnapshot?, Never>.Iteration in
            guard let self else { return .finish }
            return .next(self.snapshot)
        }
        let forwarding = Task { @MainActor in
            for await snapshot in changes {
                continuation.yield(snapshot)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in forwarding.cancel() }
        return stream
    }
}
