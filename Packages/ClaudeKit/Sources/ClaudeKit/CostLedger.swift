import Foundation
import Synchronization

/// What a call is for; copied into its `CallRecord`.
public struct CallContext: Sendable, Hashable {
    /// e.g. "correction", "routing", "tutor".
    public var purpose: String
    public var lectureID: UUID?

    public init(purpose: String = "unspecified", lectureID: UUID? = nil) {
        self.purpose = purpose
        self.lectureID = lectureID
    }
}

/// Usage and cost of one logical call (retries included), successful or not.
public struct CallRecord: Sendable, Hashable {
    public var id: UUID
    /// The model that served the call (a fallback model if one did); the requested model on failure.
    public var model: ClaudeModel
    public var requestedModel: ClaudeModel
    public var purpose: String
    public var lectureID: UUID?
    public var requestID: String?
    public var usage: Usage
    /// nil when the model is not in the pricing table.
    public var costUSD: Double?
    public var startedAt: Date
    public var duration: Duration
    public var stopReason: StopReason?
    /// Error description for failed calls (never contains the key or prompt content).
    public var error: String?
    public var streamed: Bool
    /// HTTP attempts made (1 + retries).
    public var attempts: Int

    public init(
        id: UUID = UUID(), model: ClaudeModel, requestedModel: ClaudeModel, purpose: String, lectureID: UUID?,
        requestID: String?, usage: Usage, costUSD: Double?, startedAt: Date, duration: Duration,
        stopReason: StopReason?, error: String?, streamed: Bool, attempts: Int
    ) {
        self.id = id
        self.model = model
        self.requestedModel = requestedModel
        self.purpose = purpose
        self.lectureID = lectureID
        self.requestID = requestID
        self.usage = usage
        self.costUSD = costUSD
        self.startedAt = startedAt
        self.duration = duration
        self.stopReason = stopReason
        self.error = error
        self.streamed = streamed
        self.attempts = attempts
    }

    /// Cache writes of both TTLs.
    public var cacheWriteTokens: Int { usage.cacheCreationInputTokens }

    public var durationMilliseconds: Int {
        let components = duration.components
        return Int(components.seconds) * 1000 + Int(components.attoseconds / 1_000_000_000_000_000)
    }
}

/// Receives one record per call. The app implements it with the `api_call` table
/// (`APICallRepository.log`). Errors thrown here are logged and never fail the call.
public protocol CostLedger: Sendable {
    func record(_ call: CallRecord) async throws
}

/// Discards records.
public struct NullCostLedger: CostLedger {
    public init() {}
    public func record(_ call: CallRecord) async throws {}
}

/// Keeps records in memory (tests, previews).
public final class InMemoryCostLedger: CostLedger {
    private let storage = Mutex<[CallRecord]>([])

    public init() {}

    public func record(_ call: CallRecord) async throws {
        storage.withLock { $0.append(call) }
    }

    public var records: [CallRecord] {
        storage.withLock { $0 }
    }

    public var totalCostUSD: Double {
        records.reduce(0) { $0 + ($1.costUSD ?? 0) }
    }
}
