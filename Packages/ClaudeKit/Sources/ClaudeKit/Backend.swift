import Foundation

// M3.5 (docs/plan-m35.md §2.1): what runs a `ClaudeClient`'s calls. The client's own code is the
// Messages API over HTTP (an API key); a backend replaces it, e.g. the student's Claude Code CLI
// (`ClaudeCodeEngine`, their subscription). Callers keep using `ClaudeClient` and `ToolLoop`
// unchanged: `streamMessage`, `send`, `structured` and `ToolLoop.run` go to the backend when one
// is set.

/// Which kind of backend serves the calls.
public enum ClaudeBackendKind: String, Sendable, Hashable {
    /// `POST /v1/messages` with an API key (the client's own HTTP code).
    case messagesAPI = "messages_api"
    /// The student's Claude Code CLI (`claude -p`), on their subscription.
    case claudeCode = "claude_code"
}

/// What a ready backend reports (Settings ▸ Accounts shows it in one quiet row).
public struct ClaudeBackendStatus: Sendable, Hashable {
    public var kind: ClaudeBackendKind
    /// The CLI's version ("2.1.268"); nil for the Messages API.
    public var version: String?
    /// The subscription the CLI is signed in with ("pro", "max", "team"); nil when unknown.
    public var subscription: String?
    /// The usage limit was reached: calls fail at once with `ClaudeError.usageLimited` until then
    /// (background pipelines leave their model work pending and wake at this time). Nil while
    /// calls run.
    public var pausedUntil: Date?

    public init(kind: ClaudeBackendKind, version: String? = nil, subscription: String? = nil, pausedUntil: Date? = nil) {
        self.kind = kind
        self.version = version
        self.subscription = subscription
        self.pausedUntil = pausedUntil
    }
}

/// Whether a backend can run calls. Found without a model call (Claude Code: the binary and
/// `claude auth status`).
public enum ClaudeAvailability: Sendable, Hashable {
    /// Calls run (while `pausedUntil` is set they fail, see `ClaudeBackendStatus`).
    case ready(ClaudeBackendStatus)
    /// The Claude Code CLI was not found.
    case notInstalled
    /// The CLI is installed but not signed in.
    case signedOut
    /// The Messages API backend has no key.
    case missingAPIKey
    /// This platform cannot run the backend (iOS and iPadOS: the AI runs on the Mac).
    case unsupported

    /// Calls can be made (a usage pause may still hold, see `pausedUntil`).
    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The usage pause while it holds; nil when calls run or the backend is not ready.
    public var pausedUntil: Date? {
        guard let until = status?.pausedUntil, until > Date() else { return nil }
        return until
    }

    public var status: ClaudeBackendStatus? {
        if case .ready(let status) = self { return status }
        return nil
    }
}

/// Runs the calls of a `ClaudeClient` instead of its own HTTP code.
///
/// The contract every backend keeps (the callers rely on it):
/// - `streamMessage` delivers the documented `StreamEvent`s in order and returns the accumulated
///   `Message`; for `request.outputFormat` the message's text is the schema-valid JSON, so
///   `Message.decodeJSON` works unchanged.
/// - Every model call is reported to `ledger` (one `CallRecord` per API call or per process run,
///   failures included) with its usage, cost (`billing` says whether it is notional) and a
///   `requestID`. The ids callers link by must resolve to a record: `Message.requestID` of what
///   `streamMessage` returns, and the `requestID` of every `.messageStart` a tool loop emits.
/// - `runToolLoop` behaves like `ToolLoop.run`: the request's tools are the only tools, they run
///   through `handler`, every turn is reported as `.appended` (assistant turns verbatim, thinking
///   blocks and signatures included; tool results in user turns), and `request.messages` is never
///   edited.
/// - Effort is always sent as given; never a forced `tool_choice`; thinking never disabled.
/// - Cancelling the calling task cancels the call (Claude Code: the child process is killed).
public protocol ClaudeBackend: Sendable {
    var kind: ClaudeBackendKind { get }

    /// Whether calls can run now. Cheap: never a model call; may be cached briefly.
    func availability() async -> ClaudeAvailability

    /// Forgets a cached availability and finds it again (the app became active; Settings opened).
    func refreshAvailability() async -> ClaudeAvailability

    /// One model call, streamed.
    func streamMessage(
        _ request: MessageRequest,
        context: CallContext,
        ledger: any CostLedger,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void
    ) async throws -> Message

    /// A whole tool loop (see `ToolLoop`), run by the backend.
    func runToolLoop(
        _ request: MessageRequest,
        context: CallContext,
        maxIterations: Int,
        ledger: any CostLedger,
        handler: @escaping ToolHandler,
        onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> ToolLoopResult

    /// ma: how many background calls may run at once from now on (nil: the backend's default).
    /// The app lowers it under memory pressure. Backends without slots ignore it.
    func setBackgroundSlotLimit(_ limit: Int?) async
}

extension ClaudeBackend {
    public func refreshAvailability() async -> ClaudeAvailability {
        await availability()
    }

    public func setBackgroundSlotLimit(_ limit: Int?) async {}
}

/// A backend that can never run (iOS and iPadOS, where the AI does not run; previews).
public struct UnavailableClaudeBackend: ClaudeBackend {
    public let reason: ClaudeAvailability

    public init(reason: ClaudeAvailability = .unsupported) {
        self.reason = reason
    }

    public var kind: ClaudeBackendKind { .claudeCode }

    public func availability() async -> ClaudeAvailability { reason }

    public func streamMessage(
        _ request: MessageRequest, context: CallContext, ledger: any CostLedger,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void
    ) async throws -> Message {
        throw ClaudeError.unavailable(reason)
    }

    public func runToolLoop(
        _ request: MessageRequest, context: CallContext, maxIterations: Int, ledger: any CostLedger,
        handler: @escaping ToolHandler, onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> ToolLoopResult {
        throw ClaudeError.unavailable(reason)
    }
}
