#if os(macOS)
import Foundation

/// The `claude` process slots (ma, docs/plan-agent.md §1): ONE interactive slot (the agent panel,
/// reply drafts, the composer) and `backgroundSlots` background slots (pipelines and sub-agent
/// tasks; 2 by default, lowered by the app under memory pressure). An interactive caller never
/// waits behind background holders: the interactive slot is its own. FIFO within a priority; a
/// cancelled waiter leaves the queue. So at most 1 + 2 processes run at once (about 0.5 GB each).
actor ClaudeCodeSlots {
    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Void, any Error>
    }

    /// Interactive calls at once.
    static let interactiveSlots = 1

    /// Background calls at once (the configuration's `backgroundSlots`).
    private let backgroundSlots: Int
    /// The app's lower limit (memory pressure); nil: `backgroundSlots`.
    private var backgroundLimit: Int?
    private var interactiveHolders = 0
    private var backgroundHolders = 0
    private var interactiveWaiters: [Waiter] = []
    private var backgroundWaiters: [Waiter] = []
    private var nextID: UInt64 = 0

    init(backgroundSlots: Int) {
        self.backgroundSlots = max(1, backgroundSlots)
    }

    /// Background calls that may run now: the configured slots, or the app's limit when lower
    /// (never below 1, so background work still moves).
    var backgroundCapacity: Int {
        max(1, min(backgroundSlots, backgroundLimit ?? backgroundSlots))
    }

    /// Lowers (or lifts, nil) the background limit; waiters start when slots free up.
    func setBackgroundLimit(_ limit: Int?) {
        backgroundLimit = limit
        promote()
    }

    /// Waits for a slot of `priority`.
    func acquire(_ priority: CallPriority) async throws {
        try Task.checkCancellation()
        if hasFreeSlot(priority) {
            take(priority)
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
                let waiter = Waiter(id: id, continuation: continuation)
                switch priority {
                case .interactive: interactiveWaiters.append(waiter)
                case .background: backgroundWaiters.append(waiter)
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    /// Gives a slot of `priority` back; the next waiter of that priority takes it.
    func release(_ priority: CallPriority) {
        switch priority {
        case .interactive: interactiveHolders = max(0, interactiveHolders - 1)
        case .background: backgroundHolders = max(0, backgroundHolders - 1)
        }
        promote()
    }

    private func hasFreeSlot(_ priority: CallPriority) -> Bool {
        switch priority {
        case .interactive: interactiveHolders < Self.interactiveSlots
        case .background: backgroundHolders < backgroundCapacity
        }
    }

    private func take(_ priority: CallPriority) {
        switch priority {
        case .interactive: interactiveHolders += 1
        case .background: backgroundHolders += 1
        }
    }

    /// Hands free slots to waiters, oldest first within each priority.
    private func promote() {
        while !interactiveWaiters.isEmpty, hasFreeSlot(.interactive) {
            take(.interactive)
            interactiveWaiters.removeFirst().continuation.resume()
        }
        while !backgroundWaiters.isEmpty, hasFreeSlot(.background) {
            take(.background)
            backgroundWaiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UInt64) {
        if let index = interactiveWaiters.firstIndex(where: { $0.id == id }) {
            interactiveWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        } else if let index = backgroundWaiters.firstIndex(where: { $0.id == id }) {
            backgroundWaiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }
}
#endif
