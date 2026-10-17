import Foundation

/// A streaming event from `POST /v1/messages` with `stream: true`.
public enum StreamEvent: Sendable, Hashable {
    /// The message shell: id, model (the serving model), input usage; `content` is empty.
    case messageStart(Message)
    /// A block opened. Text/thinking/tool_use blocks start empty; server-tool result and `fallback`
    /// blocks arrive complete here.
    case contentBlockStart(index: Int, block: ContentBlock)
    case contentBlockDelta(index: Int, delta: ContentDelta)
    case contentBlockStop(index: Int)
    /// `stop_reason`, `stop_sequence`, `stop_details`, and cumulative usage.
    case messageDelta(delta: JSONObject, usage: JSONObject?)
    case messageStop
    case ping
    /// An event type ClaudeKit does not know; ignored by the accumulator.
    case unknown(type: String, data: JSONValue)

    /// Decodes one SSE event. `error` events throw the matching `ClaudeError`.
    public init(sse: SSEEvent, requestID: String? = nil) throws {
        let json: JSONValue
        do {
            json = try JSONValue.parse(sse.data)
        } catch {
            throw ClaudeError.decoding("stream event \(sse.event ?? "?"): data is not JSON")
        }
        try self.init(json: json, requestID: requestID, eventName: sse.event)
    }

    /// Decodes one raw Messages API stream event (`{"type":"message_start",…}`), e.g. the `event`
    /// of a Claude Code `stream_event` line (M3.5). `requestID` goes into `messageStart`'s message.
    /// `error` events throw the matching `ClaudeError`.
    public init(json: JSONValue, requestID: String?) throws {
        try self.init(json: json, requestID: requestID, eventName: nil)
    }

    private init(json: JSONValue, requestID: String?, eventName: String?) throws {
        guard let object = json.objectValue else {
            throw ClaudeError.decoding("stream event \(eventName ?? "?"): data is not an object")
        }
        let type = object.string("type") ?? eventName ?? ""
        switch type {
        case "message_start":
            guard let message = object["message"] else {
                throw ClaudeError.decoding("message_start without message")
            }
            var decoded = try Message(json: message)
            decoded.requestID = requestID
            self = .messageStart(decoded)
        case "content_block_start":
            guard let index = object.int("index"), let block = object["content_block"] else {
                throw ClaudeError.decoding("content_block_start without index or content_block")
            }
            self = .contentBlockStart(index: index, block: try ContentBlock(json: block))
        case "content_block_delta":
            guard let index = object.int("index"), let delta = object.object("delta") else {
                throw ClaudeError.decoding("content_block_delta without index or delta")
            }
            self = .contentBlockDelta(index: index, delta: ContentDelta(object: delta))
        case "content_block_stop":
            guard let index = object.int("index") else {
                throw ClaudeError.decoding("content_block_stop without index")
            }
            self = .contentBlockStop(index: index)
        case "message_delta":
            self = .messageDelta(delta: object.object("delta") ?? [:], usage: object.object("usage"))
        case "message_stop":
            self = .messageStop
        case "ping":
            self = .ping
        case "error":
            throw ClaudeError.fromStreamError(object.object("error") ?? [:], requestID: requestID)
        default:
            self = .unknown(type: type, data: json)
        }
    }
}

/// A `content_block_delta` payload.
public enum ContentDelta: Sendable, Hashable {
    case text(String)
    case thinking(String)
    case signature(String)
    /// A fragment of a tool input; concatenate all fragments and parse at `content_block_stop`.
    case inputJSON(String)
    case citation(JSONValue)
    case unknown(JSONObject)

    init(object: JSONObject) {
        switch object.string("type") {
        case "text_delta": self = .text(object.string("text") ?? "")
        case "thinking_delta": self = .thinking(object.string("thinking") ?? "")
        case "signature_delta": self = .signature(object.string("signature") ?? "")
        case "input_json_delta": self = .inputJSON(object.string("partial_json") ?? "")
        case "citations_delta": self = .citation(object["citation"] ?? .null)
        default: self = .unknown(object)
        }
    }
}

/// Folds stream events into the final `Message`, the same shape a non-streaming call returns.
public struct MessageAccumulator: Sendable {
    private var message: Message?
    private var blocks: [Int: BlockBuilder] = [:]
    private var order: [Int] = []
    public private(set) var isComplete = false

    public init() {}

    /// The message so far (partial while streaming). Open blocks are included as accumulated.
    public var snapshot: Message? {
        guard var message else { return nil }
        message.content = order.compactMap { blocks[$0]?.block }
        return message
    }

    public mutating func apply(_ event: StreamEvent) throws {
        switch event {
        case .messageStart(let start):
            message = start
            for block in start.content.enumerated() {
                blocks[block.offset] = BlockBuilder(block: block.element)
                order.append(block.offset)
            }
        case .contentBlockStart(let index, let block):
            guard message != nil else { throw ClaudeError.decoding("content_block_start before message_start") }
            if blocks[index] == nil { order.append(index) }
            blocks[index] = BlockBuilder(block: block)
        case .contentBlockDelta(let index, let delta):
            guard var builder = blocks[index] else {
                throw ClaudeError.decoding("content_block_delta for unopened block \(index)")
            }
            builder.apply(delta)
            blocks[index] = builder
        case .contentBlockStop(let index):
            guard var builder = blocks[index] else {
                throw ClaudeError.decoding("content_block_stop for unopened block \(index)")
            }
            builder.finish()
            blocks[index] = builder
        case .messageDelta(let delta, let usage):
            guard var current = message else { throw ClaudeError.decoding("message_delta before message_start") }
            for (key, value) in delta {
                switch key {
                case "stop_reason": current.stopReason = value.stringValue.map(StopReason.init(rawValue:))
                case "stop_sequence": current.stopSequence = value.stringValue
                case "stop_details": current.stopDetails = value.objectValue.map(StopDetails.init(json:))
                default: current.extra[key] = value
                }
            }
            if let usage { current.usage.merge(usage) }
            message = current
        case .messageStop:
            isComplete = true
        case .ping, .unknown:
            break
        }
    }

    /// The complete message. Throws if the stream has not reached `message_stop`.
    public func finalMessage() throws -> Message {
        guard isComplete, var message = snapshot else { throw ClaudeError.streamEndedUnexpectedly }
        message.content = order.compactMap { index in
            guard var builder = blocks[index] else { return nil }
            if !builder.isFinished { builder.finish() }
            return builder.block
        }
        return message
    }
}

/// Accumulates one content block.
struct BlockBuilder: Sendable {
    private(set) var block: ContentBlock
    private var partialJSON = ""
    private var receivedJSON = false
    private(set) var isFinished = false

    init(block: ContentBlock) {
        self.block = block
    }

    mutating func apply(_ delta: ContentDelta) {
        switch (delta, block) {
        case (.text(let text), .text(var textBlock)):
            textBlock.text += text
            block = .text(textBlock)
        case (.citation(let citation), .text(var textBlock)):
            var citations = textBlock.citations?.arrayValue ?? []
            citations.append(citation)
            textBlock.citations = .array(citations)
            block = .text(textBlock)
        case (.thinking(let text), .thinking(var thinking)):
            thinking.thinking += text
            block = .thinking(thinking)
        case (.signature(let signature), .thinking(var thinking)):
            thinking.signature = (thinking.signature ?? "") + signature
            block = .thinking(thinking)
        case (.inputJSON(let fragment), _):
            partialJSON += fragment
            receivedJSON = true
        default:
            break
        }
    }

    /// Parses accumulated tool input at `content_block_stop`.
    mutating func finish() {
        isFinished = true
        guard receivedJSON else { return }
        let trimmed = partialJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed: JSONValue?
        if trimmed.isEmpty {
            parsed = .object([:])
        } else {
            parsed = try? JSONValue.parse(trimmed)
        }
        switch block {
        case .toolUse(var use):
            if let parsed, parsed.objectValue != nil {
                use.input = parsed
            } else {
                use.input = .object([:])
                use.invalidInputJSON = partialJSON
            }
            block = .toolUse(use)
        case .serverToolUse(var use):
            use.input = parsed ?? .object([:])
            block = .serverToolUse(use)
        case .other(var object) where parsed != nil:
            object["input"] = parsed
            block = .other(object)
        default:
            break
        }
    }
}
