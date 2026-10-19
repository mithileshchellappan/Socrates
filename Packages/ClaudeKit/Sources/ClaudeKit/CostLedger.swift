import Foundation
import Synchronization

/// What a call is for; copied into its `CallRecord`.
public struct CallContext: Sendable, Hashable {
    /// e.g. "correction", "routing", "tutor".
    public var purpose: String
    public var lectureID: UUID?
    /// Who waits for the answer (M3.5). Claude Code (ma): an interactive call takes the one
    /// interactive process slot and never waits behind background calls, which share
    /// `ClaudeCodeConfiguration.backgroundSlots` slots. The Messages API ignores it.
    public var priority: CallPriority
    /// The conversation a tool loop continues (M3.5). A backend that keeps conversations itself
    /// (Claude Code: one CLI session per conversation) uses it; the Messages API ignores it.
    public var session: ConversationSession?
    /// Claude Code: how long the call's `claude` may show no life (no output, no tool call
    /// running) before it is ended with `ClaudeError.stalled`; nil: the engine's
    /// `ClaudeCodeConfiguration.idleTimeout` (10 minutes). The Messages API ignores it.
    public var idleTimeout: Duration?

    public init(
        purpose: String = "unspecified",
        lectureID: UUID? = nil,
        priority: CallPriority = .interactive,
        session: ConversationSession? = nil,
        idleTimeout: Duration? = nil
    ) {
        self.purpose = purpose
        self.lectureID = lectureID
        self.priority = priority
        self.session = session
        self.idleTimeout = idleTimeout
    }
}

/// Who waits for a call's answer.
public enum CallPriority: String, Sendable, Hashable {
    /// The student waits (chat, reply drafts, the deadline composer).
    case interactive
    /// Nobody waits (mail triage and its backlog, transcript extraction).
    case background
}

/// A conversation whose history a backend keeps itself.
///
/// Claude Code: `id` is the CLI session id (the `agent_conversation` id); the first run starts the
/// session (`--session-id`), later runs continue it (`--resume`) and send only the user turns
/// after the last assistant turn (all stored turns as text when the CLI has deleted the session).
/// The caller still stores every turn append-only.
public struct ConversationSession: Sendable, Hashable {
    public var id: UUID
    /// False for the conversation's first run; true once a run has produced an assistant turn.
    public var resumes: Bool

    public init(id: UUID, resumes: Bool) {
        self.id = id
        self.resumes = resumes
    }
}

/// Whether a call's cost was billed or is notional.
public enum Billing: String, Sendable, Hashable {
    /// Billed per token (the Messages API with an API key).
    case api
    /// Counted against a subscription's usage limits (Claude Code); `costUSD` is notional, at
    /// list prices.
    case subscription
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
    /// Billed per token, or notional under a subscription (M3.5).
    public var billing: Billing

    public init(
        id: UUID = UUID(), model: ClaudeModel, requestedModel: ClaudeModel, purpose: String, lectureID: UUID?,
        requestID: String?, usage: Usage, costUSD: Double?, startedAt: Date, duration: Duration,
        stopReason: StopReason?, error: String?, streamed: Bool, attempts: Int, billing: Billing = .api
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
        self.billing = billing
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
