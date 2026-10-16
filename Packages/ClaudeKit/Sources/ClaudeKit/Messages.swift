import Foundation

/// `content` of a request message: a plain string or content blocks. Kept as sent so a stored
/// conversation re-encodes to the same bytes.
public enum MessageContent: Sendable, Hashable {
    case text(String)
    case blocks([ContentBlock])

    public var blocks: [ContentBlock] {
        switch self {
        case .text(let text): [.text(TextBlock(text: text))]
        case .blocks(let blocks): blocks
        }
    }

    var json: JSONValue {
        switch self {
        case .text(let text): .string(text)
        case .blocks(let blocks): .array(blocks.map(\.json))
        }
    }

    init(json: JSONValue) throws {
        switch json {
        case .string(let text): self = .text(text)
        case .array(let values): self = .blocks(try values.map(ContentBlock.init(json:)))
        default: throw ClaudeError.decoding("message content: expected a string or an array")
        }
    }
}

/// One turn in `messages`. Conversations are append-only: never edit a turn once it has been sent.
public struct MessageParam: Sendable, Hashable {
    public var role: Role
    public var content: MessageContent
    /// Fields ClaudeKit does not model (e.g. `output_config` on a mid-conversation system message).
    public var extra: JSONObject

    public init(role: Role, content: MessageContent, extra: JSONObject = [:]) {
        self.role = role
        self.content = content
        self.extra = extra
    }

    public init(role: Role, blocks: [ContentBlock]) {
        self.init(role: role, content: .blocks(blocks))
    }

    public static func user(_ text: String) -> MessageParam {
        MessageParam(role: .user, content: .text(text))
    }

    public static func user(_ blocks: [ContentBlock]) -> MessageParam {
        MessageParam(role: .user, content: .blocks(blocks))
    }

    public static func assistant(_ blocks: [ContentBlock]) -> MessageParam {
        MessageParam(role: .assistant, content: .blocks(blocks))
    }

    /// A mid-conversation operator instruction (models that support it; no beta header).
    public static func system(_ text: String) -> MessageParam {
        MessageParam(role: .system, content: .text(text))
    }

    /// The assistant turn to append after `message`, in the form the API expects back.
    public static func assistant(_ message: Message) -> MessageParam {
        MessageParam(role: .assistant, content: .blocks(message.historyContent))
    }

    public var json: JSONValue {
        var object = extra
        object["role"] = .string(role.rawValue)
        object["content"] = content.json
        return .object(object)
    }

    public init(json: JSONValue) throws {
        guard let object = json.objectValue,
              let roleString = object.string("role"), let role = Role(rawValue: roleString),
              let content = object["content"]
        else { throw ClaudeError.decoding("message: expected role and content") }
        self.role = role
        self.content = try MessageContent(json: content)
        extra = object.excluding(["role", "content"])
    }
}

extension MessageParam: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}

// MARK: - Usage

/// Token usage of one response. `inputTokens` is the uncached remainder only:
/// total prompt = input + cache creation + cache read.
public struct Usage: Sendable, Hashable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int
    /// Cache writes split by TTL, when the API reports it.
    public var cacheCreation5mInputTokens: Int?
    public var cacheCreation1hInputTokens: Int?
    public var webSearchRequests: Int
    public var webFetchRequests: Int
    /// Every usage field as received (e.g. `service_tier`, `iterations` for fallbacks).
    public var raw: JSONObject

    public init(
        inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0, cacheCreation5mInputTokens: Int? = nil,
        cacheCreation1hInputTokens: Int? = nil, webSearchRequests: Int = 0, webFetchRequests: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreation5mInputTokens = cacheCreation5mInputTokens
        self.cacheCreation1hInputTokens = cacheCreation1hInputTokens
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
        raw = [:]
    }

    public init(json: JSONObject) {
        self.init()
        merge(json)
    }

    /// Applies a (cumulative) usage object from `message_start` or `message_delta`.
    /// Null values never overwrite known counts.
    mutating func merge(_ json: JSONObject) {
        for (key, value) in json where !value.isNull {
            raw[key] = value
        }
        if let value = json.int("input_tokens") { inputTokens = value }
        if let value = json.int("output_tokens") { outputTokens = value }
        if let value = json.int("cache_creation_input_tokens") { cacheCreationInputTokens = value }
        if let value = json.int("cache_read_input_tokens") { cacheReadInputTokens = value }
        if let creation = json.object("cache_creation") {
            if let value = creation.int("ephemeral_5m_input_tokens") { cacheCreation5mInputTokens = value }
            if let value = creation.int("ephemeral_1h_input_tokens") { cacheCreation1hInputTokens = value }
        }
        if let serverTools = json.object("server_tool_use") {
            if let value = serverTools.int("web_search_requests") { webSearchRequests = value }
            if let value = serverTools.int("web_fetch_requests") { webFetchRequests = value }
        }
    }

    /// The usage object: every received field, with the typed counts written over it.
    public var json: JSONObject {
        var object = raw
        object["input_tokens"] = .int(inputTokens)
        object["output_tokens"] = .int(outputTokens)
        object["cache_creation_input_tokens"] = .int(cacheCreationInputTokens)
        object["cache_read_input_tokens"] = .int(cacheReadInputTokens)
        if cacheCreation5mInputTokens != nil || cacheCreation1hInputTokens != nil {
            var creation = raw.object("cache_creation") ?? [:]
            creation.set("ephemeral_5m_input_tokens", cacheCreation5mInputTokens.map(JSONValue.int))
            creation.set("ephemeral_1h_input_tokens", cacheCreation1hInputTokens.map(JSONValue.int))
            object["cache_creation"] = .object(creation)
        }
        if webSearchRequests > 0 || webFetchRequests > 0 || raw["server_tool_use"] != nil {
            var serverTools = raw.object("server_tool_use") ?? [:]
            serverTools["web_search_requests"] = .int(webSearchRequests)
            if webFetchRequests > 0 || serverTools["web_fetch_requests"] != nil {
                serverTools["web_fetch_requests"] = .int(webFetchRequests)
            }
            object["server_tool_use"] = .object(serverTools)
        }
        return object
    }

    /// Total prompt tokens: uncached input + cache writes + cache reads.
    public var promptTokens: Int {
        inputTokens + cacheCreationInputTokens + cacheReadInputTokens
    }

    /// Sums two usages (e.g. across the turns of a tool loop).
    public static func + (lhs: Usage, rhs: Usage) -> Usage {
        func add(_ a: Int?, _ b: Int?) -> Int? { (a == nil && b == nil) ? nil : (a ?? 0) + (b ?? 0) }
        return Usage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationInputTokens: lhs.cacheCreationInputTokens + rhs.cacheCreationInputTokens,
            cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
            cacheCreation5mInputTokens: add(lhs.cacheCreation5mInputTokens, rhs.cacheCreation5mInputTokens),
            cacheCreation1hInputTokens: add(lhs.cacheCreation1hInputTokens, rhs.cacheCreation1hInputTokens),
            webSearchRequests: lhs.webSearchRequests + rhs.webSearchRequests,
            webFetchRequests: lhs.webFetchRequests + rhs.webFetchRequests)
    }
}

// MARK: - Message (response)

/// A complete response from `POST /v1/messages` (or the accumulation of a stream).
public struct Message: Sendable, Hashable {
    public var id: String
    /// The model that produced this message (a fallback model when a refusal fallback served it).
    public var model: ClaudeModel
    public var role: Role
    public var content: [ContentBlock]
    public var stopReason: StopReason?
    public var stopSequence: String?
    public var stopDetails: StopDetails?
    public var usage: Usage
    /// Top-level fields ClaudeKit does not model, kept verbatim.
    public var extra: JSONObject
    /// `request-id` response header. Not part of the wire form.
    public var requestID: String?

    public init(
        id: String, model: ClaudeModel, role: Role = .assistant, content: [ContentBlock],
        stopReason: StopReason?, stopSequence: String? = nil, stopDetails: StopDetails? = nil,
        usage: Usage = Usage(), extra: JSONObject = [:], requestID: String? = nil
    ) {
        self.id = id
        self.model = model
        self.role = role
        self.content = content
        self.stopReason = stopReason
        self.stopSequence = stopSequence
        self.stopDetails = stopDetails
        self.usage = usage
        self.extra = extra
        self.requestID = requestID
    }

    private static let known: Set<String> = [
        "id", "type", "role", "model", "content", "stop_reason", "stop_sequence", "stop_details", "usage",
    ]

    public init(json: JSONValue) throws {
        guard let object = json.objectValue else { throw ClaudeError.decoding("message: expected an object") }
        id = object.string("id") ?? ""
        model = ClaudeModel(object.string("model") ?? "")
        role = object.string("role").flatMap(Role.init(rawValue:)) ?? .assistant
        content = try (object.array("content") ?? []).map(ContentBlock.init(json:))
        stopReason = object.string("stop_reason").map(StopReason.init(rawValue:))
        stopSequence = object.string("stop_sequence")
        stopDetails = object.object("stop_details").map(StopDetails.init(json:))
        usage = Usage(json: object.object("usage") ?? [:])
        extra = object.excluding(Self.known)
    }

    public var json: JSONValue {
        var object = extra
        object["id"] = .string(id)
        object["type"] = "message"
        object["role"] = .string(role.rawValue)
        object["model"] = .string(model.rawValue)
        object["content"] = .array(content.map(\.json))
        object["stop_reason"] = stopReason.map { .string($0.rawValue) } ?? .null
        object["stop_sequence"] = stopSequence.map(JSONValue.string) ?? .null
        object.set("stop_details", stopDetails.map { .object($0.raw) })
        object["usage"] = .object(usage.json)
        return .object(object)
    }

    // MARK: Reading

    /// All text blocks joined. Read blocks by type, not position: responses can begin with thinking blocks.
    public var text: String {
        content.compactMap(\.textValue).joined()
    }

    public var toolUses: [ToolUseBlock] {
        content.compactMap(\.toolUse)
    }

    public var isRefusal: Bool { stopReason == .refusal }

    /// Non-empty thinking text: summaries under `display: summarized`, progress notes under `updates`.
    public var thinkingSummaries: [String] {
        content.compactMap { block in
            if case .thinking(let thinking) = block, !thinking.thinking.isEmpty { return thinking.thinking }
            return nil
        }
    }

    /// Content to append to the history as this assistant turn.
    ///
    /// Unchanged unless a refusal fallback switched models mid-output: then thinking, redacted thinking,
    /// client tool calls, unpaired server tool calls, and unknown model-internal blocks that come before
    /// the last `fallback` block are omitted, as the API requires. Text, paired server-tool blocks and the
    /// `fallback` marker itself are kept.
    public var historyContent: [ContentBlock] {
        guard let boundary = content.lastIndex(where: { $0.type == "fallback" }) else { return content }
        let pairedResultIDs = Set(content.compactMap(\.serverToolResultID))
        var kept: [ContentBlock] = []
        for (index, block) in content.enumerated() {
            guard index < boundary else {
                kept.append(block)
                continue
            }
            switch block {
            case .text, .image, .document:
                kept.append(block)
            case .serverToolUse(let use) where pairedResultIDs.contains(use.id):
                kept.append(block)
            case .other where block.serverToolResultID != nil:
                kept.append(block)
            case .thinking, .redactedThinking, .toolUse, .toolResult, .serverToolUse, .other:
                continue
            }
        }
        return kept
    }
}

extension Message: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}
