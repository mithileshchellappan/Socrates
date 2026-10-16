import Foundation

/// A Claude model id. Use the exact ids below; never append date suffixes.
public struct ClaudeModel: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    /// Default model. Thinking is always on; set `effort` explicitly (API default is `medium`).
    public static let opus55: ClaudeModel = "claude-opus-5-5"
    /// Cheap passes: routing, extraction, query planning.
    public static let haiku55: ClaudeModel = "claude-haiku-5-5"
    public static let sonnet55: ClaudeModel = "claude-sonnet-5-5"

    /// Models a server-side refusal fallback may serve a request with. Priced, never requested directly.
    public static let opus5: ClaudeModel = "claude-opus-5"
    public static let opus48: ClaudeModel = "claude-opus-4-8"

    public static let `default` = opus55

    /// Whether the model accepts the server-side `fallbacks` parameter.
    public var supportsServerSideFallback: Bool {
        self == .opus55 || self == .sonnet55
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// `output_config.effort`. The main control for how much the model thinks, and so for latency and cost.
public enum Effort: String, Sendable, Hashable, Codable, CaseIterable {
    case low, medium, high, xhigh, max
}

/// How thinking blocks come back. Thinking is billed the same under every setting.
public enum ThinkingDisplay: String, Sendable, Hashable, Codable {
    /// Default on current models: thinking blocks arrive with empty text (signature only).
    case omitted
    /// A readable summary of the reasoning.
    case summarized
    /// Reasoning hidden, between-tool-call progress notes returned as text.
    /// Requires beta `thinking-display-updates-2026-08-18` (added automatically).
    case updates
}

/// `thinking`. Only adaptive thinking exists in ClaudeKit: Opus 5.5 rejects `disabled` and
/// `budget_tokens` with a 400, so they cannot be expressed.
public struct ThinkingConfig: Sendable, Hashable {
    public var display: ThinkingDisplay?

    public init(display: ThinkingDisplay? = nil) {
        self.display = display
    }

    public static let adaptive = ThinkingConfig()
    public static let summarized = ThinkingConfig(display: .summarized)

    var json: JSONValue {
        var object: JSONObject = ["type": "adaptive"]
        object.set("display", display.map { .string($0.rawValue) })
        return .object(object)
    }
}

/// `cache_control` on a block, a tool, or (automatic caching) the request.
public struct CacheControl: Sendable, Hashable {
    public enum TTL: String, Sendable, Hashable {
        case fiveMinutes = "5m"
        case oneHour = "1h"
    }

    public var ttl: TTL?

    public init(ttl: TTL? = nil) { self.ttl = ttl }

    /// 5-minute TTL (the default); writes cost 1.25x input.
    public static let ephemeral = CacheControl()
    /// 1-hour TTL; writes cost 2x input.
    public static let ephemeralOneHour = CacheControl(ttl: .oneHour)

    var json: JSONValue {
        var object: JSONObject = ["type": "ephemeral"]
        object.set("ttl", ttl.map { .string($0.rawValue) })
        return .object(object)
    }

    init?(json: JSONValue?) {
        guard let object = json?.objectValue else { return nil }
        ttl = object.string("ttl").flatMap(TTL.init(rawValue:))
    }
}

public enum Role: String, Sendable, Hashable, Codable {
    case user
    case assistant
    /// Mid-conversation operator instruction (appended, never edited into earlier turns).
    case system
}

/// `stop_reason`. Open set: unknown values decode unchanged.
public struct StopReason: RawRepresentable, Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public static let endTurn: StopReason = "end_turn"
    public static let maxTokens: StopReason = "max_tokens"
    public static let stopSequence: StopReason = "stop_sequence"
    public static let toolUse: StopReason = "tool_use"
    /// A server-tool loop paused; send the turn back unchanged to resume.
    public static let pauseTurn: StopReason = "pause_turn"
    /// Declined by the model or a safety classifier (HTTP 200). Read `stopDetails`.
    public static let refusal: StopReason = "refusal"
    public static let modelContextWindowExceeded: StopReason = "model_context_window_exceeded"
}

/// `stop_details`; populated only when `stop_reason` is `refusal`. Informational: branch on
/// `stop_reason`, never on these fields (any of them can be null).
public struct StopDetails: Sendable, Hashable {
    public var type: String?
    /// Open set, e.g. `cyber`, `bio`, `reasoning_extraction`, `frontier_llm`, or nil.
    public var category: String?
    public var explanation: String?
    /// Set when a fallback could not run (rate-limited/overloaded): a model a direct retry may succeed on.
    public var recommendedModel: String?
    /// Every field as received, for logging or redeeming a fallback credit.
    public var raw: JSONObject

    public init(json: JSONObject) {
        raw = json
        type = json.string("type")
        category = json.string("category")
        explanation = json.string("explanation")
        recommendedModel = json.string("recommended_model")
    }

    public init(category: String?, explanation: String? = nil) {
        var object: JSONObject = ["type": "refusal"]
        object.set("category", category.map(JSONValue.string))
        object.set("explanation", explanation.map(JSONValue.string))
        self.init(json: object)
    }
}
