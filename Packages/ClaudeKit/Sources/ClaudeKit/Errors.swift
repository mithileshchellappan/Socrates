import Foundation

/// Details of an API error response (`{"type":"error","error":{"type":…,"message":…},"request_id":…}`).
public struct APIErrorInfo: Sendable, Hashable, CustomStringConvertible {
    /// HTTP status; nil for an `error` event inside a stream that had already returned 200.
    public var status: Int?
    /// `error.type`, e.g. `invalid_request_error`, `rate_limit_error`, `overloaded_error`.
    public var type: String
    public var message: String
    public var requestID: String?

    public init(status: Int?, type: String, message: String, requestID: String? = nil) {
        self.status = status
        self.type = type
        self.message = message
        self.requestID = requestID
    }

    /// Parses an error body. Falls back to the raw text when the body is not the documented shape.
    init(status: Int?, body: Data, requestID: String?) {
        let object = (try? JSONValue.parse(body))?.objectValue
        let error = object?.object("error")
        self.init(
            status: status,
            type: error?.string("type") ?? Self.defaultType(for: status),
            message: error?.string("message")
                ?? String(decoding: body.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            requestID: object?.string("request_id") ?? requestID)
    }

    init(status: Int?, errorObject: JSONObject, requestID: String?) {
        self.init(
            status: status,
            type: errorObject.string("type") ?? Self.defaultType(for: status),
            message: errorObject.string("message") ?? "",
            requestID: requestID)
    }

    static func defaultType(for status: Int?) -> String {
        switch status {
        case 400: "invalid_request_error"
        case 401: "authentication_error"
        case 402: "billing_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 413: "request_too_large"
        case 429: "rate_limit_error"
        case 529: "overloaded_error"
        default: "api_error"
        }
    }

    public var description: String {
        let status = status.map { "HTTP \($0) " } ?? ""
        let request = requestID.map { " (request \($0))" } ?? ""
        return "\(status)\(type): \(message)\(request)"
    }
}

/// Everything ClaudeKit throws.
public enum ClaudeError: Error, Sendable, CustomStringConvertible {
    /// No API key in the Keychain (or the provider returned an empty one).
    case missingAPIKey
    /// A request ClaudeKit refuses to send (caught before spending a call).
    case invalidArgument(String)
    /// Non-streaming call with a `max_tokens` large enough to hit idle timeouts. Use `streamMessage`.
    case streamingRequired(maxTokens: Int)

    /// 400 (and 413): fix the request; retrying the same body never helps.
    case invalidRequest(APIErrorInfo)
    /// 401.
    case authentication(APIErrorInfo)
    /// 403.
    case permissionDenied(APIErrorInfo)
    /// 404: usually a wrong model id.
    case notFound(APIErrorInfo)
    /// 402.
    case billing(APIErrorInfo)
    /// 429. `retryAfter` from the `retry-after` / `retry-after-ms` header.
    case rateLimited(APIErrorInfo, retryAfter: Duration?)
    /// 529, or an `overloaded_error` event mid-stream.
    case overloaded(APIErrorInfo)
    /// 5xx / `api_error`.
    case server(APIErrorInfo)
    /// Any other API error status (e.g. 408, 409).
    case api(APIErrorInfo)

    /// Network failure before or during a response.
    case transport(code: Int, description: String)
    /// The stream closed before `message_stop`.
    case streamEndedUnexpectedly
    /// A response body or event did not match the documented shape.
    case decoding(String)

    /// The model or a safety classifier declined (`stop_reason: refusal`, HTTP 200). Raised by helpers
    /// that need a complete answer (e.g. `decodeJSON`); raw calls return the message instead.
    case refused(StopDetails?, message: Message)
    /// The response hit `max_tokens` where a complete answer was required.
    case truncated(message: Message)

    /// M3.5: the backend cannot run calls (Claude Code not installed or signed out; iOS).
    case unavailable(ClaudeAvailability)
    /// M3.5: the subscription's usage limit was reached ("You've hit your session limit · resets
    /// 5:20pm"). Calls resume at `resetsAt` (nil when the CLI did not say). Every call gets this
    /// error at once while the pause holds; background work stays pending and runs after it.
    case usageLimited(resetsAt: Date?)
    /// M3.5: the Claude Code CLI failed (an error result, a missing MCP connection, an answer
    /// without the expected content). Readable; never contains prompt content.
    case claudeCode(String)
    /// M3.5: the `claude` process failed on its own, whatever was asked: it could not start, it
    /// crashed or was killed, or it exited without a result line (e.g. a flag a CLI update
    /// dropped); or the app's tool server could not listen. Service trouble: the work waits.
    case claudeCodeProcess(String)
    /// M5: a Claude Code run used up its `--max-turns` before it answered (result subtype
    /// `error_max_turns`, e.g. a web research run that kept searching). About the request, not
    /// the service: asking again the same way ends the same way (not retryable, not service
    /// trouble). A tool loop reports this as `ToolLoopStop.iterationLimit` instead.
    case turnLimit(String)
    /// A `claude` run showed no life for `idle` (no output, no tool call of the app running) and
    /// was ended (`ClaudeCodeConfiguration.idleTimeout`, `CallContext.idleTimeout`). Service
    /// trouble: the work waits and runs again later.
    case stalled(idle: Duration)

    /// The API error details, when this is an API error.
    public var apiError: APIErrorInfo? {
        switch self {
        case .invalidRequest(let info), .authentication(let info), .permissionDenied(let info),
            .notFound(let info), .billing(let info), .rateLimited(let info, _), .overloaded(let info),
            .server(let info), .api(let info):
            info
        default:
            nil
        }
    }

    public var requestID: String? {
        switch self {
        case .refused(_, let message), .truncated(let message): message.requestID
        default: apiError?.requestID
        }
    }

    /// Whether retrying the same request may succeed (429, 408, 409, 5xx, overload, network).
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .server, .streamEndedUnexpectedly:
            true
        case .api(let info):
            info.status.map(RetryPolicy.isRetryableStatus) ?? false
        case .transport(let code, _):
            RetryPolicy.isRetryableURLErrorCode(code)
        default:
            false
        }
    }

    /// Trouble with the service rather than the request: work waits (stays pending, counts no
    /// attempt) and runs again when woken. No key or CLI, sign-in, billing, usage limits, and
    /// everything retryable.
    public var isServiceTrouble: Bool {
        switch self {
        case .missingAPIKey, .authentication, .permissionDenied, .billing, .unavailable, .usageLimited, .claudeCodeProcess, .stalled: true
        default: isRetryable
        }
    }

    /// Maps an error HTTP response to a typed error.
    static func from(status: Int, body: Data, headers: [String: String]) -> ClaudeError {
        let info = APIErrorInfo(status: status, body: body, requestID: headers["request-id"])
        switch status {
        case 400, 413: return .invalidRequest(info)
        case 401: return .authentication(info)
        case 402: return .billing(info)
        case 403: return .permissionDenied(info)
        case 404: return .notFound(info)
        case 429: return .rateLimited(info, retryAfter: RetryPolicy.retryAfter(headers: headers))
        case 529: return .overloaded(info)
        case 500...599: return .server(info)
        default: return .api(info)
        }
    }

    /// Maps an `error` event received inside a 200 stream.
    static func fromStreamError(_ errorObject: JSONObject, requestID: String?) -> ClaudeError {
        let info = APIErrorInfo(status: nil, errorObject: errorObject, requestID: requestID)
        switch info.type {
        case "overloaded_error": return .overloaded(info)
        case "rate_limit_error": return .rateLimited(info, retryAfter: nil)
        case "api_error": return .server(info)
        case "invalid_request_error", "request_too_large": return .invalidRequest(info)
        case "authentication_error": return .authentication(info)
        case "permission_error": return .permissionDenied(info)
        case "not_found_error": return .notFound(info)
        case "billing_error": return .billing(info)
        default: return .api(info)
        }
    }

    public var description: String {
        switch self {
        case .missingAPIKey: "No Anthropic API key in the Keychain"
        case .invalidArgument(let reason): "Invalid request: \(reason)"
        case .streamingRequired(let maxTokens): "max_tokens \(maxTokens) needs a streaming call"
        case .invalidRequest(let info), .authentication(let info), .permissionDenied(let info),
            .notFound(let info), .billing(let info), .overloaded(let info), .server(let info), .api(let info):
            info.description
        case .rateLimited(let info, let retryAfter):
            info.description + (retryAfter.map { " (retry after \($0))" } ?? "")
        case .transport(let code, let description): "Network error \(code): \(description)"
        case .streamEndedUnexpectedly: "The response stream ended before message_stop"
        case .decoding(let reason): "Unexpected response: \(reason)"
        case .refused(let details, _):
            "Declined" + (details?.category.map { " (\($0))" } ?? "")
        case .truncated: "The response hit max_tokens"
        case .unavailable(let availability):
            switch availability {
            case .notInstalled: "Claude Code is not installed"
            case .signedOut: "Claude Code is not signed in"
            case .missingAPIKey: "No Anthropic API key in the Keychain"
            case .unsupported: "Claude does not run on this device"
            case .ready: "Claude is unavailable"
            }
        case .usageLimited(let resetsAt):
            "Usage limit reached" + (resetsAt.map { " until \($0.formatted(.iso8601))" } ?? "")
        case .claudeCode(let reason), .claudeCodeProcess(let reason), .turnLimit(let reason): "Claude Code: \(reason)"
        case .stalled(let idle): "Claude Code: no output for \(idle); the process was ended"
        }
    }
}
