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
            stopReason: call.stopReason?.rawValue, error: call.error, createdAt: call.startedAt
        ))
    }
}

extension ClaudeClient {
    /// The app's client: the key from the Keychain helper at each call (nil when none is saved:
    /// the call fails, nothing is sent), every call logged to `api_call`.
    public static func studyPortal(services: StudyServices, transport: any HTTPTransport = URLSessionTransport.shared) -> ClaudeClient {
        let secrets = services.secrets
        return ClaudeClient(
            keyProvider: ClosureAPIKeyProvider { try secrets.secret(for: .anthropicAPIKey) },
            ledger: APICallLedger(services: services),
            transport: transport
        )
    }
}
