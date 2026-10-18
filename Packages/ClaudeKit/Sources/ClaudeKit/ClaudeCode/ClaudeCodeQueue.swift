#if os(macOS)
import Foundation

/// One holder at a time (docs/plan-m35.md §3.3): interactive waiters before background ones, FIFO
/// within a priority; a cancelled waiter leaves the queue. Used per run for the MCP tool calls (one
/// at a time, like `ToolLoop` with `parallelToolExecution: false`). ma: the `claude` processes
/// themselves are held by `ClaudeCodeSlots` (1 interactive + 2 background).
actor ClaudeCodeQueue {
    private struct Waiter {
        let id: UInt64
        let priority: CallPriority
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var busy = false
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    /// Waits for the turn.
    func acquire(_ priority: CallPriority) async throws {
        try Task.checkCancellation()
        if !busy {
            busy = true
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let waiter = Waiter(id: id, priority: priority, continuation: continuation)
                if priority == .interactive {
                    let index = waiters.firstIndex { $0.priority == .background } ?? waiters.endIndex
                    waiters.insert(waiter, at: index)
                } else {
                    waiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Hands the turn to the next waiter, or frees it.
    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Runs `body` holding the turn.
    func run<T: Sendable>(_ priority: CallPriority, _ body: @Sendable () async throws -> T) async throws -> T {
        try await acquire(priority)
        do {
            let value = try await body()
            release()
            return value
        } catch {
            release()
            throw error
        }
    }

    private func cancel(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
#endif
