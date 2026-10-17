import Synchronization

/// Lets one async operation run at a time, in arrival order.
///
/// Actors are re-entrant: while one of their methods awaits (WhisperKit loading, decoding,
/// unloading), another call can start on the same actor. Operations that must not overlap take
/// the gate first and release it when done:
///
///     await gate.acquire()
///     defer { gate.release() }
final class AsyncGate: Sendable {
    private struct State {
        var isHeld = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Waits until the gate is free and takes it.
    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let takenNow = state.withLock { state -> Bool in
                guard state.isHeld else {
                    state.isHeld = true
                    return true
                }
                state.waiting.append(continuation)
                return false
            }
            if takenNow { continuation.resume() }
        }
    }

    /// Hands the gate to the next waiting operation, or frees it.
    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else {
                state.isHeld = false
                return nil
            }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }

    /// True while an operation holds the gate (tests and diagnostics).
    var isHeld: Bool { state.withLock { $0.isHeld } }
}
