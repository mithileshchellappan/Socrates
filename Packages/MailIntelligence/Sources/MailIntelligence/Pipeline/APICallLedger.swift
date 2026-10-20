import ClaudeKit
import Foundation
import StudyCore

/// The app's `CostLedger` (ClaudeKit README): one `api_call` row per logical call, with the
/// response's `request-id`, so the rows a call decided can link to it (`APICallLink`) and the
/// mail cost guard can sum today's spending. Used by the app and the offline end-to-end run.
public struct APICallLedger: CostLedger {
    public let repository: APICallRepository

    public init(services: StudyServices) {
        repository = APICallRepository(store: services.records)
    }

    public func record(_ call: CallRecord) async throws {
        try await repository.log(APICall(
            id: call.id, model: call.model.rawValue, purpose: call.purpose, requestID: call.requestID, lectureID: call.lectureID,
            inputTokens: call.usage.inputTokens, outputTokens: call.usage.outputTokens,
            cacheReadTokens: call.usage.cacheReadInputTokens, cacheWriteTokens: call.cacheWriteTokens,
            costUSD: call.costUSD ?? 0, durationMs: call.durationMilliseconds,
            stopReason: call.stopReason?.rawValue, error: call.error,
            billing: call.billing == .subscription ? .subscription : nil, createdAt: call.startedAt
        ))
    }
}

extension ClaudeClient {
    /// The app's client (M3.5, docs/plan-m35.md): the student's Claude Code CLI on the Mac (their
    /// subscription; no API key), unavailable on iOS and iPadOS (the AI runs on the Mac). Every
    /// call is logged to `api_call` (`billing = subscription`: the cost is notional).
    ///
    /// Each call makes a new engine, and the engine is the one-process queue: the app calls this
    /// once and shares the client.
    public static func socrates(services: StudyServices) -> ClaudeClient {
        #if os(macOS)
        let backend: any ClaudeBackend = ClaudeCodeEngine(configuration: ClaudeCodeConfiguration(directory: services.paths.agent))
        #else
        let backend: any ClaudeBackend = UnavailableClaudeBackend()
        #endif
        return ClaudeClient(backend: backend, ledger: APICallLedger(services: services))
    }

    /// The Messages API with the Keychain key (the M2/M3 path; unused since M3.5, kept in code).
    public static func messagesAPI(services: StudyServices, transport: any HTTPTransport = URLSessionTransport.shared) -> ClaudeClient {
        let secrets = services.secrets
        return ClaudeClient(
            keyProvider: ClosureAPIKeyProvider { try secrets.secret(for: .anthropicAPIKey) },
            ledger: APICallLedger(services: services),
            transport: transport
        )
    }
}
