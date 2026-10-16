import Foundation

/// A `POST /v1/messages` request.
///
/// Shapes that the current models reject are not expressible: there is no `temperature`/`top_p`/`top_k`,
/// no disabled or budgeted thinking, no forced `tool_choice`, and no assistant prefill helper.
/// `effort` is required so every call states it explicitly (Opus 5.5 defaults to `medium` otherwise).
public struct MessageRequest: Sendable, Hashable {
    public var model: ClaudeModel
    /// Output cap, thinking included. Long calls must stream (`ClaudeClient.streamMessage`).
    public var maxTokens: Int
    public var effort: Effort
    public var messages: [MessageParam]
    public var system: [SystemBlock]
    /// Fixed per conversation type: changing tools mid-conversation breaks the cache and preserved thinking.
    public var tools: [Tool]
    public var toolChoice: ToolChoice?
    /// `nil` omits `thinking` (adaptive on every current model).
    public var thinking: ThinkingConfig?
    /// Structured output (`output_config.format`).
    public var outputFormat: OutputFormat?
    public var stopSequences: [String]
    /// Top-level automatic caching: the breakpoint follows the last cacheable block.
    public var cacheControl: CacheControl?
    /// Refusal fallback. `nil` uses the client's default.
    public var fallbacks: FallbackPolicy?
    /// Extra `anthropic-beta` values. Betas required by the request's own fields are added automatically.
    public var betas: Set<String>
    /// Top-level fields ClaudeKit does not model (e.g. `context_management`, `inference_geo`).
    /// Keys already set by typed fields win.
    public var extraBody: JSONObject

    public init(
        model: ClaudeModel = .default,
        maxTokens: Int = 16_000,
        effort: Effort,
        messages: [MessageParam],
        system: [SystemBlock] = [],
        tools: [Tool] = [],
        toolChoice: ToolChoice? = nil,
        thinking: ThinkingConfig? = nil,
        outputFormat: OutputFormat? = nil,
        stopSequences: [String] = [],
        cacheControl: CacheControl? = nil,
        fallbacks: FallbackPolicy? = nil,
        betas: Set<String> = [],
        extraBody: JSONObject = [:]
    ) {
        self.model = model
        self.maxTokens = maxTokens
        self.effort = effort
        self.messages = messages
        self.system = system
        self.tools = tools
        self.toolChoice = toolChoice
        self.thinking = thinking
        self.outputFormat = outputFormat
        self.stopSequences = stopSequences
        self.cacheControl = cacheControl
        self.fallbacks = fallbacks
        self.betas = betas
        self.extraBody = extraBody
    }

    /// Convenience: a system prompt as one text block.
    public static func systemPrompt(_ text: String, cacheControl: CacheControl? = nil) -> [SystemBlock] {
        [SystemBlock(text: text, cacheControl: cacheControl)]
    }

    // MARK: Wire form

    /// The request body (without `stream`).
    public var body: JSONObject {
        var object = extraBody
        object["model"] = .string(model.rawValue)
        object["max_tokens"] = .int(maxTokens)
        object["messages"] = .array(messages.map(\.json))
        if !system.isEmpty { object["system"] = .array(system.map(\.json)) }
        if !tools.isEmpty { object["tools"] = .array(tools.map(\.json)) }
        object.set("tool_choice", toolChoice?.json)
        object.set("thinking", thinking?.json)
        var outputConfig = extraBody.object("output_config") ?? [:]
        outputConfig["effort"] = .string(effort.rawValue)
        outputConfig.set("format", outputFormat?.json)
        object["output_config"] = .object(outputConfig)
        if !stopSequences.isEmpty { object["stop_sequences"] = .array(stopSequences.map(JSONValue.string)) }
        object.set("cache_control", cacheControl?.json)
        object.set("fallbacks", fallbacks?.json)
        return object
    }

    /// The `anthropic-beta` values this request needs, sorted.
    public var requiredBetas: [String] {
        var all = betas
        if thinking?.display == .updates { all.insert(Beta.thinkingDisplayUpdates) }
        if let beta = fallbacks?.beta { all.insert(beta) }
        return all.sorted()
    }

    /// Encoded body; deterministic so the same conversation produces the same bytes.
    public func encodedBody(stream: Bool) throws -> Data {
        var object = body
        if stream { object["stream"] = true }
        return try JSONValue.object(object).serialized()
    }

    /// Checks shapes the API would reject, before spending a request.
    public func validate() throws {
        guard maxTokens > 0 else { throw ClaudeError.invalidArgument("max_tokens must be positive") }
        guard !messages.isEmpty else { throw ClaudeError.invalidArgument("messages must not be empty") }
        var names = Set<String>()
        for tool in tools where !names.insert(tool.name).inserted {
            throw ClaudeError.invalidArgument("duplicate tool name \(tool.name)")
        }
        if fallbacks != nil, fallbacks != .disabled, !model.supportsServerSideFallback {
            throw ClaudeError.invalidArgument("\(model) does not accept server-side fallbacks")
        }
    }
}

/// Known `anthropic-beta` values.
public enum Beta {
    public static let thinkingDisplayUpdates = "thinking-display-updates-2026-08-18"
    public static let serverSideFallbackDefault = "server-side-fallback-2026-07-01"
    public static let serverSideFallbackModels = "server-side-fallback-2026-06-01"
}

// MARK: - System

/// A top-level system prompt block. Put stable text first and a `cacheControl` on the last stable block.
public struct SystemBlock: Sendable, Hashable {
    public var text: String
    public var cacheControl: CacheControl?

    public init(text: String, cacheControl: CacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }

    var json: JSONValue {
        var object: JSONObject = ["type": "text", "text": .string(text)]
        object.set("cache_control", cacheControl?.json)
        return .object(object)
    }
}

// MARK: - Tools

/// A tool definition: a client tool with an input schema, or an Anthropic server tool.
public enum Tool: Sendable, Hashable {
    case custom(CustomTool)
    case webSearch(WebSearchTool)
    case webFetch(WebFetchTool)
    /// Any other tool definition, sent verbatim.
    case raw(JSONObject)

    public var name: String {
        switch self {
        case .custom(let tool): tool.name
        case .webSearch: "web_search"
        case .webFetch: "web_fetch"
        case .raw(let object): object.string("name") ?? object.string("type") ?? ""
        }
    }

    var json: JSONValue {
        switch self {
        case .custom(let tool): tool.json
        case .webSearch(let tool): tool.json
        case .webFetch(let tool): tool.json
        case .raw(let object): .object(object)
        }
    }

    public static func custom(
        name: String, description: String, inputSchema: JSONValue, strict: Bool = true
    ) -> Tool {
        .custom(CustomTool(name: name, description: description, inputSchema: inputSchema, strict: strict))
    }
}

/// A client tool. ClaudeKit defaults to `strict: true`: the schema must set `additionalProperties: false`
/// and `required` on every object, and the API then guarantees `tool_use.input` matches it.
public struct CustomTool: Sendable, Hashable {
    public var name: String
    /// Say when to call it, not only what it does.
    public var description: String
    public var inputSchema: JSONValue
    public var strict: Bool
    /// Stream large inputs as generated. Off by default: the API then no longer validates the input,
    /// which gives up `strict`'s guarantee. Only meaningful on streamed requests.
    public var eagerInputStreaming: Bool
    public var cacheControl: CacheControl?

    public init(
        name: String, description: String, inputSchema: JSONValue, strict: Bool = true,
        eagerInputStreaming: Bool = false, cacheControl: CacheControl? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
        self.eagerInputStreaming = eagerInputStreaming
        self.cacheControl = cacheControl
    }

    var json: JSONValue {
        var object: JSONObject = [
            "name": .string(name),
            "description": .string(description),
            "input_schema": inputSchema,
        ]
        if strict { object["strict"] = true }
        if eagerInputStreaming { object["eager_input_streaming"] = true }
        object.set("cache_control", cacheControl?.json)
        return .object(object)
    }

    /// Problems that make a schema unusable with `strict: true` (objects without
    /// `additionalProperties: false` or `required`). Empty when the schema is fine.
    public var strictSchemaProblems: [String] {
        var problems: [String] = []
        func visit(_ value: JSONValue, path: String) {
            switch value {
            case .object(let object):
                if object.string("type") == "object" {
                    if object["additionalProperties"] != .bool(false) {
                        problems.append("\(path): additionalProperties must be false")
                    }
                    if object["required"] == nil {
                        problems.append("\(path): required is missing")
                    }
                }
                for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                    visit(child, path: "\(path)/\(key)")
                }
            case .array(let values):
                for (index, child) in values.enumerated() { visit(child, path: "\(path)/\(index)") }
            default:
                break
            }
        }
        visit(inputSchema, path: "#")
        return problems
    }
}

/// `web_search_20260209` (dynamic filtering; do not also declare code execution).
public struct WebSearchTool: Sendable, Hashable {
    public struct UserLocation: Sendable, Hashable {
        public var city: String?
        public var region: String?
        public var country: String?
        public var timezone: String?

        public init(city: String? = nil, region: String? = nil, country: String? = nil, timezone: String? = nil) {
            self.city = city
            self.region = region
            self.country = country
            self.timezone = timezone
        }

        var json: JSONValue {
            var object: JSONObject = ["type": "approximate"]
            object.set("city", city.map(JSONValue.string))
            object.set("region", region.map(JSONValue.string))
            object.set("country", country.map(JSONValue.string))
            object.set("timezone", timezone.map(JSONValue.string))
            return .object(object)
        }
    }

    public static let type = "web_search_20260209"

    public var maxUses: Int?
    /// Use either allowed or blocked domains, not both.
    public var allowedDomains: [String]?
    public var blockedDomains: [String]?
    public var userLocation: UserLocation?
    public var cacheControl: CacheControl?

    public init(
        maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil,
        userLocation: UserLocation? = nil, cacheControl: CacheControl? = nil
    ) {
        self.maxUses = maxUses
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.userLocation = userLocation
        self.cacheControl = cacheControl
    }

    var json: JSONValue {
        var object: JSONObject = ["type": .string(Self.type), "name": "web_search"]
        object.set("max_uses", maxUses.map(JSONValue.int))
        object.set("allowed_domains", allowedDomains.map { .array($0.map(JSONValue.string)) })
        object.set("blocked_domains", blockedDomains.map { .array($0.map(JSONValue.string)) })
        object.set("user_location", userLocation?.json)
        object.set("cache_control", cacheControl?.json)
        return .object(object)
    }
}

/// `web_fetch_20260209`. Fetches only URLs already present in the conversation.
public struct WebFetchTool: Sendable, Hashable {
    public static let type = "web_fetch_20260209"

    public var maxUses: Int?
    public var allowedDomains: [String]?
    public var blockedDomains: [String]?
    public var citations: Bool?
    public var maxContentTokens: Int?
    public var cacheControl: CacheControl?

    public init(
        maxUses: Int? = nil, allowedDomains: [String]? = nil, blockedDomains: [String]? = nil,
        citations: Bool? = nil, maxContentTokens: Int? = nil, cacheControl: CacheControl? = nil
    ) {
        self.maxUses = maxUses
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.citations = citations
        self.maxContentTokens = maxContentTokens
        self.cacheControl = cacheControl
    }

    var json: JSONValue {
        var object: JSONObject = ["type": .string(Self.type), "name": "web_fetch"]
        object.set("max_uses", maxUses.map(JSONValue.int))
        object.set("allowed_domains", allowedDomains.map { .array($0.map(JSONValue.string)) })
        object.set("blocked_domains", blockedDomains.map { .array($0.map(JSONValue.string)) })
        object.set("citations", citations.map { ["enabled": .bool($0)] })
        object.set("max_content_tokens", maxContentTokens.map(JSONValue.int))
        object.set("cache_control", cacheControl?.json)
        return .object(object)
    }
}

/// `tool_choice`. Only `auto` and `none` exist: forced `any`/`tool` returns a 400 on Opus 5.5.
/// Steer toward a tool from the prompt and check that the call happened.
public enum ToolChoice: Sendable, Hashable {
    case auto
    /// `auto` with `disable_parallel_tool_use`: at most one tool call per turn.
    case autoWithoutParallelToolUse
    case none

    var json: JSONValue {
        switch self {
        case .auto: ["type": "auto"]
        case .autoWithoutParallelToolUse: ["type": "auto", "disable_parallel_tool_use": true]
        case .none: ["type": "none"]
        }
    }
}

// MARK: - Output format

/// `output_config.format`: constrain the response to a JSON schema (every object needs
/// `additionalProperties: false`). Incompatible with citations.
public struct OutputFormat: Sendable, Hashable {
    public var schema: JSONValue

    public init(schema: JSONValue) { self.schema = schema }

    public static func jsonSchema(_ schema: JSONValue) -> OutputFormat { OutputFormat(schema: schema) }

    var json: JSONValue {
        ["type": "json_schema", "schema": schema]
    }
}

// MARK: - Refusal fallbacks

/// Server-side retry of a classifier-declined request on another model, inside the same call.
public enum FallbackPolicy: Sendable, Hashable {
    /// `fallbacks: "default"`: Anthropic picks the fallback by refusal category.
    case recommended
    /// `fallbacks: [{model, max_tokens?}]` (1-3 distinct entries).
    case models([FallbackTarget])
    /// No fallback; a refusal is returned as-is.
    case disabled

    var json: JSONValue? {
        switch self {
        case .recommended: "default"
        case .models(let targets): .array(targets.map(\.json))
        case .disabled: nil
        }
    }

    var beta: String? {
        switch self {
        case .recommended: Beta.serverSideFallbackDefault
        case .models: Beta.serverSideFallbackModels
        case .disabled: nil
        }
    }
}

public struct FallbackTarget: Sendable, Hashable {
    public var model: ClaudeModel
    public var maxTokens: Int?

    public init(model: ClaudeModel, maxTokens: Int? = nil) {
        self.model = model
        self.maxTokens = maxTokens
    }

    var json: JSONValue {
        var object: JSONObject = ["model": .string(model.rawValue)]
        object.set("max_tokens", maxTokens.map(JSONValue.int))
        return .object(object)
    }
}
