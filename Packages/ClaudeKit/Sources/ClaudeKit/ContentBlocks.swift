import Foundation

/// A content block in a request or response.
///
/// Blocks decoded from a response keep every field they arrived with (unknown fields in `extra`,
/// unknown block types as `.other`), so an assistant turn can be appended to the history unchanged.
/// Thinking blocks in particular must go back byte-for-byte with their signatures.
public enum ContentBlock: Sendable, Hashable {
    case text(TextBlock)
    case image(ImageBlock)
    case document(DocumentBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case thinking(ThinkingBlock)
    case redactedThinking(RedactedThinkingBlock)
    case serverToolUse(ServerToolUseBlock)
    /// Any other block type (`web_search_tool_result`, `web_fetch_tool_result`, `fallback`, ...), verbatim.
    case other(JSONObject)

    public var type: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .document: "document"
        case .toolUse: "tool_use"
        case .toolResult: "tool_result"
        case .thinking: "thinking"
        case .redactedThinking: "redacted_thinking"
        case .serverToolUse: "server_tool_use"
        case .other(let object): object.string("type") ?? ""
        }
    }

    public init(json: JSONValue) throws {
        guard let object = json.objectValue, let type = object.string("type") else {
            throw ClaudeError.decoding("content block: expected an object with a \"type\"")
        }
        switch type {
        case "text": self = .text(TextBlock(object: object))
        case "image": self = .image(try ImageBlock(object: object))
        case "document": self = .document(try DocumentBlock(object: object))
        case "tool_use": self = .toolUse(try ToolUseBlock(object: object))
        case "tool_result": self = .toolResult(try ToolResultBlock(object: object))
        case "thinking": self = .thinking(ThinkingBlock(object: object))
        case "redacted_thinking": self = .redactedThinking(RedactedThinkingBlock(object: object))
        case "server_tool_use": self = .serverToolUse(try ServerToolUseBlock(object: object))
        default: self = .other(object)
        }
    }

    public var json: JSONValue {
        switch self {
        case .text(let block): .object(block.object)
        case .image(let block): .object(block.object)
        case .document(let block): .object(block.object)
        case .toolUse(let block): .object(block.object)
        case .toolResult(let block): .object(block.object)
        case .thinking(let block): .object(block.object)
        case .redactedThinking(let block): .object(block.object)
        case .serverToolUse(let block): .object(block.object)
        case .other(let object): .object(object)
        }
    }

    // MARK: Convenience constructors

    public static func text(_ text: String, cacheControl: CacheControl? = nil) -> ContentBlock {
        .text(TextBlock(text: text, cacheControl: cacheControl))
    }

    /// A base64 PDF document block (`application/pdf`). Place documents before the question text.
    public static func pdf(
        _ data: Data, title: String? = nil, context: String? = nil, citations: Bool? = nil,
        cacheControl: CacheControl? = nil
    ) -> ContentBlock {
        .document(DocumentBlock(
            source: .base64(mediaType: "application/pdf", data: data.base64EncodedString()),
            title: title, context: context, citationsEnabled: citations, cacheControl: cacheControl))
    }

    /// A base64 image block (`image/jpeg`, `image/png`, `image/gif`, `image/webp`).
    public static func image(_ data: Data, mediaType: String, cacheControl: CacheControl? = nil) -> ContentBlock {
        .image(ImageBlock(source: .base64(mediaType: mediaType, data: data.base64EncodedString()),
                          cacheControl: cacheControl))
    }

    public static func toolResult(
        toolUseID: String, _ text: String, isError: Bool = false, cacheControl: CacheControl? = nil
    ) -> ContentBlock {
        .toolResult(ToolResultBlock(toolUseID: toolUseID, content: .text(text), isError: isError,
                                    cacheControl: cacheControl))
    }

    // MARK: Accessors

    public var textValue: String? {
        if case .text(let block) = self { return block.text }
        return nil
    }

    public var toolUse: ToolUseBlock? {
        if case .toolUse(let block) = self { return block }
        return nil
    }

    /// `tool_use_id` of a server-tool result block (`web_search_tool_result`, ...), if this is one.
    var serverToolResultID: String? {
        if case .other(let object) = self, object.string("type")?.hasSuffix("_tool_result") == true {
            return object.string("tool_use_id")
        }
        return nil
    }
}

extension ContentBlock: Codable {
    public init(from decoder: any Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try json.encode(to: encoder)
    }
}

// MARK: - Sources

/// `source` of an image or document block.
public enum BlockSource: Sendable, Hashable {
    /// Base64 data without newlines (`Data.base64EncodedString()` default options).
    case base64(mediaType: String, data: String)
    /// Plain-text document (`media_type: text/plain`).
    case text(String)
    case url(String)
    /// Files API id.
    case file(id: String)
    case other(JSONObject)

    init(object: JSONObject) {
        switch object.string("type") {
        case "base64":
            if let mediaType = object.string("media_type"), let data = object.string("data"), object.count == 3 {
                self = .base64(mediaType: mediaType, data: data)
                return
            }
        case "text":
            if let data = object.string("data"), object.string("media_type") == "text/plain", object.count == 3 {
                self = .text(data)
                return
            }
        case "url":
            if let url = object.string("url"), object.count == 2 {
                self = .url(url)
                return
            }
        case "file":
            if let id = object.string("file_id"), object.count == 2 {
                self = .file(id: id)
                return
            }
        default:
            break
        }
        self = .other(object)
    }

    var object: JSONObject {
        switch self {
        case .base64(let mediaType, let data):
            ["type": "base64", "media_type": .string(mediaType), "data": .string(data)]
        case .text(let data):
            ["type": "text", "media_type": "text/plain", "data": .string(data)]
        case .url(let url):
            ["type": "url", "url": .string(url)]
        case .file(let id):
            ["type": "file", "file_id": .string(id)]
        case .other(let object):
            object
        }
    }
}

// MARK: - Blocks

public struct TextBlock: Sendable, Hashable {
    public var text: String
    /// `citations` as received (an array, or null). Responses split cited text into several blocks.
    public var citations: JSONValue?
    public var cacheControl: CacheControl?
    /// Fields ClaudeKit does not model, kept for round-tripping.
    public var extra: JSONObject

    public init(text: String, citations: JSONValue? = nil, cacheControl: CacheControl? = nil, extra: JSONObject = [:]) {
        self.text = text
        self.citations = citations
        self.cacheControl = cacheControl
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "text", "citations", "cache_control"]

    init(object: JSONObject) {
        text = object.string("text") ?? ""
        citations = object["citations"]
        cacheControl = CacheControl(json: object["cache_control"])
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "text"
        object["text"] = .string(text)
        object.set("citations", citations)
        object.set("cache_control", cacheControl?.json)
        return object
    }
}

public struct ImageBlock: Sendable, Hashable {
    public var source: BlockSource
    public var cacheControl: CacheControl?
    public var extra: JSONObject

    public init(source: BlockSource, cacheControl: CacheControl? = nil, extra: JSONObject = [:]) {
        self.source = source
        self.cacheControl = cacheControl
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "source", "cache_control"]

    init(object: JSONObject) throws {
        guard let source = object.object("source") else {
            throw ClaudeError.decoding("image block: missing source")
        }
        self.source = BlockSource(object: source)
        cacheControl = CacheControl(json: object["cache_control"])
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "image"
        object["source"] = .object(source.object)
        object.set("cache_control", cacheControl?.json)
        return object
    }
}

public struct DocumentBlock: Sendable, Hashable {
    public var source: BlockSource
    public var title: String?
    public var context: String?
    /// `citations: {enabled: …}`. Enable on all documents of a request or none.
    public var citationsEnabled: Bool?
    public var cacheControl: CacheControl?
    public var extra: JSONObject

    public init(
        source: BlockSource, title: String? = nil, context: String? = nil, citationsEnabled: Bool? = nil,
        cacheControl: CacheControl? = nil, extra: JSONObject = [:]
    ) {
        self.source = source
        self.title = title
        self.context = context
        self.citationsEnabled = citationsEnabled
        self.cacheControl = cacheControl
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "source", "title", "context", "citations", "cache_control"]

    init(object: JSONObject) throws {
        guard let source = object.object("source") else {
            throw ClaudeError.decoding("document block: missing source")
        }
        self.source = BlockSource(object: source)
        title = object.string("title")
        context = object.string("context")
        citationsEnabled = object.object("citations")?.bool("enabled")
        cacheControl = CacheControl(json: object["cache_control"])
        var extra = object.excluding(Self.known)
        // Keep a citations value we cannot model (e.g. null) verbatim.
        if let citations = object["citations"], citationsEnabled == nil { extra["citations"] = citations }
        if let title = object["title"], self.title == nil { extra["title"] = title }
        if let context = object["context"], self.context == nil { extra["context"] = context }
        self.extra = extra
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "document"
        object["source"] = .object(source.object)
        object.set("title", title.map(JSONValue.string))
        object.set("context", context.map(JSONValue.string))
        object.set("citations", citationsEnabled.map { ["enabled": .bool($0)] })
        object.set("cache_control", cacheControl?.json)
        return object
    }
}

public struct ToolUseBlock: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var extra: JSONObject
    /// Set when a streamed input could not be parsed as JSON (only possible with eager input streaming).
    /// `input` is then `{}` and the tool must not run; answer with an `is_error` result.
    public var invalidInputJSON: String?

    public init(id: String, name: String, input: JSONValue, extra: JSONObject = [:]) {
        self.id = id
        self.name = name
        self.input = input
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "id", "name", "input"]

    init(object: JSONObject) throws {
        id = try object.requiredString("id", in: "tool_use block")
        name = try object.requiredString("name", in: "tool_use block")
        input = object["input"] ?? .object([:])
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "tool_use"
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["input"] = input
        return object
    }

    /// Decodes `input` as `T` (e.g. a `Decodable` mirror of the tool's input schema).
    public func decodeInput<T: Decodable>(_ type: T.Type) throws -> T {
        try input.decode(T.self)
    }
}

/// `content` of a `tool_result`: a string or an array of text/image/document blocks.
public enum ToolResultContent: Sendable, Hashable {
    case text(String)
    case blocks([ContentBlock])

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
        default: throw ClaudeError.decoding("tool_result content: expected a string or an array")
        }
    }
}

public struct ToolResultBlock: Sendable, Hashable {
    public var toolUseID: String
    public var content: ToolResultContent?
    public var isError: Bool?
    public var cacheControl: CacheControl?
    public var extra: JSONObject

    public init(
        toolUseID: String, content: ToolResultContent?, isError: Bool? = nil, cacheControl: CacheControl? = nil,
        extra: JSONObject = [:]
    ) {
        self.toolUseID = toolUseID
        self.content = content
        self.isError = (isError == false) ? nil : isError
        self.cacheControl = cacheControl
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "tool_use_id", "content", "is_error", "cache_control"]

    init(object: JSONObject) throws {
        toolUseID = try object.requiredString("tool_use_id", in: "tool_result block")
        content = try object["content"].map(ToolResultContent.init(json:))
        isError = object.bool("is_error")
        cacheControl = CacheControl(json: object["cache_control"])
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "tool_result"
        object["tool_use_id"] = .string(toolUseID)
        object.set("content", content?.json)
        object.set("is_error", isError.map(JSONValue.bool))
        object.set("cache_control", cacheControl?.json)
        return object
    }
}

/// A thinking block. Under the default `display: omitted`, `thinking` is empty; the block must still be
/// passed back unchanged (signature included) on the same model.
public struct ThinkingBlock: Sendable, Hashable {
    public var thinking: String
    public var signature: String?
    public var extra: JSONObject

    public init(thinking: String, signature: String?, extra: JSONObject = [:]) {
        self.thinking = thinking
        self.signature = signature
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "thinking", "signature"]

    init(object: JSONObject) {
        thinking = object.string("thinking") ?? ""
        signature = object.string("signature")
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "thinking"
        object["thinking"] = .string(thinking)
        object.set("signature", signature.map(JSONValue.string))
        return object
    }
}

public struct RedactedThinkingBlock: Sendable, Hashable {
    public var data: String
    public var extra: JSONObject

    public init(data: String, extra: JSONObject = [:]) {
        self.data = data
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "data"]

    init(object: JSONObject) {
        data = object.string("data") ?? ""
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "redacted_thinking"
        object["data"] = .string(data)
        return object
    }
}

/// A server tool call (`web_search`, `web_fetch`, ...). Runs on Anthropic's side; never executed locally.
public struct ServerToolUseBlock: Sendable, Hashable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public var extra: JSONObject

    public init(id: String, name: String, input: JSONValue, extra: JSONObject = [:]) {
        self.id = id
        self.name = name
        self.input = input
        self.extra = extra
    }

    private static let known: Set<String> = ["type", "id", "name", "input"]

    init(object: JSONObject) throws {
        id = try object.requiredString("id", in: "server_tool_use block")
        name = try object.requiredString("name", in: "server_tool_use block")
        input = object["input"] ?? .object([:])
        extra = object.excluding(Self.known)
    }

    var object: JSONObject {
        var object = extra
        object["type"] = "server_tool_use"
        object["id"] = .string(id)
        object["name"] = .string(name)
        object["input"] = input
        return object
    }
}
