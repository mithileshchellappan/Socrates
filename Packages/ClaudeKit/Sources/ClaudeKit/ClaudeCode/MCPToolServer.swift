#if os(macOS)
import Foundation
import Network

/// The app's MCP server for one tool-loop run (docs/plan-m35.md §3.5): the request's custom tools,
/// served to the Claude Code CLI over streamable HTTP (`POST /mcp`, JSON responses only) on
/// 127.0.0.1 at a random port, behind a random bearer token. Minimal HTTP/1.1 (keep-alive,
/// Content-Length or chunked bodies); Network framework's structured-concurrency listener.
final class MCPToolServer: Sendable {
    /// What `tools/call` runs: the bare tool name and its arguments.
    typealias CallTool = @Sendable (_ name: String, _ arguments: JSONValue) async -> ToolOutput

    /// Kept from before the app was renamed: the tool names in stored agent turns
    /// (`mcp__studyportal__…`, `ClaudeCodeConfiguration.toolNamePrefix`) carry it, and the
    /// app reads them back (bare names, the untrusted-content trace).
    static let serverName = "studyportal"
    /// Protocol versions echoed in `initialize`; anything else gets the newest of these.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let maximumHeadBytes = 64 * 1024
    private static let maximumBodyBytes = 16 * 1024 * 1024

    let token: String
    private let tools: [CustomTool]
    private let callTool: CallTool

    init(tools: [CustomTool], callTool: @escaping CallTool) {
        var generator = SystemRandomNumberGenerator()
        token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        self.tools = tools
        self.callTool = callTool
    }

    /// Starts listening; returns the port and the task serving it (cancel it to stop).
    func start() async throws -> (port: UInt16, task: Task<Void, Never>) {
        let listener = try NetworkListener<TCP>(
            using: NWParametersBuilder<TCP>.parameters { TCP() }
                .localEndpoint(.hostPort(host: .ipv4(.loopback), port: .any)))
        let (states, stateUpdates) = AsyncStream.makeStream(of: NetworkListener<TCP>.State.self)
        listener.onStateUpdate { _, state in stateUpdates.yield(state) }
        let task = Task.detached { [self] in
            do {
                try await listener.run { connection in
                    await self.serve(connection)
                }
            } catch {
                ClaudeClient.logger.debug("MCP server stopped: \(String(describing: error), privacy: .public)")
            }
            stateUpdates.finish()
        }
        for await state in states {
            switch state {
            case .ready:
                if let port = listener.port?.rawValue { return (port, task) }
            case .failed(let error):
                task.cancel()
                throw ClaudeError.claudeCodeProcess("the tool server could not listen (\(error))")
            case .cancelled:
                task.cancel()
                throw ClaudeError.claudeCodeProcess("the tool server stopped before it was ready")
            default:
                continue
            }
        }
        task.cancel()
        throw ClaudeError.claudeCodeProcess("the tool server stopped before it was ready")
    }

    /// `--mcp-config` content for the CLI. `alwaysLoad`: the tools are in the first request's
    /// prompt (never deferred behind tool search) and the CLI connects before it starts.
    func configuration(port: UInt16) -> JSONValue {
        [
            "mcpServers": [
                Self.serverName: [
                    "type": "http",
                    "url": .string("http://127.0.0.1:\(port)/mcp"),
                    "headers": ["Authorization": .string("Bearer \(token)")],
                    "alwaysLoad": true,
                ]
            ]
        ]
    }

    // MARK: - HTTP

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    private struct Response {
        var status: Int
        var reason: String
        var headers: [(String, String)] = []
        var body = Data()

        static func json(_ value: JSONValue, status: Int = 200, reason: String = "OK") -> Response {
            Response(
                status: status, reason: reason, headers: [("Content-Type", "application/json")],
                body: (try? value.serialized()) ?? Data("null".utf8))
        }

        static func empty(_ status: Int, _ reason: String, headers: [(String, String)] = []) -> Response {
            Response(status: status, reason: reason, headers: headers)
        }

        func encoded(close: Bool) -> Data {
            var head = "HTTP/1.1 \(status) \(reason)\r\n"
            for (name, value) in headers { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(body.count)\r\n"
            head += close ? "Connection: close\r\n\r\n" : "Connection: keep-alive\r\n\r\n"
            return Data(head.utf8) + body
        }
    }

    private enum ReadOutcome {
        case request(Request)
        case closed
        case invalid(Response)
    }

    private func serve(_ connection: NetworkConnection<TCP>) async {
        var buffer = Data()
        do {
            while !Task.isCancelled {
                let request: Request
                switch try await read(connection, buffer: &buffer) {
                case .closed:
                    return
                case .invalid(let response):
                    try await connection.send(response.encoded(close: true))
                    return
                case .request(let value):
                    request = value
                }
                let close = request.headers["connection"]?.lowercased() == "close"
                let response = await respond(to: request)
                try await connection.send(response.encoded(close: close))
                if close { return }
            }
        } catch {
            // The peer closed the connection or the run ended.
        }
    }

    private func read(_ connection: NetworkConnection<TCP>, buffer: inout Data) async throws -> ReadOutcome {
        let separator = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        while true {
            headEnd = buffer.range(of: separator)
            if headEnd != nil { break }
            if buffer.count > Self.maximumHeadBytes { return .invalid(.empty(431, "Request Header Fields Too Large")) }
            guard try await receive(connection, into: &buffer) else { return .closed }
        }
        guard let headEnd else { return .closed }
        let head = String(decoding: buffer[buffer.startIndex..<headEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid(.empty(400, "Bad Request")) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        // The path and the token before any body byte is read: a stranger's request is answered
        // from its headers alone and the connection closed (its body is never parsed).
        guard path == "/mcp" else { return .invalid(.empty(404, "Not Found")) }
        guard authorized(headers["authorization"]) else { return .invalid(.empty(401, "Unauthorized")) }
        let bodyStart = headEnd.upperBound
        let body: Data
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            reading: while true {
                switch Self.chunkedBody(buffer, from: bodyStart, limit: Self.maximumBodyBytes) {
                case .complete(let decoded, let end):
                    body = decoded
                    buffer = Data(buffer[end...])
                    break reading
                case .incomplete:
                    // The encoded bytes too (chunk lines), so a stream of tiny chunks is bounded.
                    if buffer.endIndex - bodyStart > Self.maximumBodyBytes + Self.maximumHeadBytes {
                        return .invalid(.empty(413, "Content Too Large"))
                    }
                    guard try await receive(connection, into: &buffer) else { return .closed }
                case .invalid(let response):
                    return .invalid(response)
                }
            }
        } else {
            var length = 0
            if let text = headers["content-length"] {
                // Digits only (no sign, no overflow: at most 9 of them).
                guard !text.isEmpty, text.count <= 9, text.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let value = Int(text) else {
                    return .invalid(.empty(400, "Bad Request"))
                }
                length = value
            }
            guard length <= Self.maximumBodyBytes else { return .invalid(.empty(413, "Content Too Large")) }
            while buffer.endIndex - bodyStart < length {
                guard try await receive(connection, into: &buffer) else { return .closed }
            }
            body = Data(buffer[bodyStart..<(bodyStart + length)])
            buffer = Data(buffer[(bodyStart + length)...])
        }
        return .request(Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers, body: body))
    }

    /// Appends received bytes; false once the peer has closed and nothing arrived.
    private func receive(_ connection: NetworkConnection<TCP>, into buffer: inout Data) async throws -> Bool {
        let (content, metadata) = try await connection.receive(atLeast: 1, atMost: 64 * 1024)
        buffer.append(content)
        return !(content.isEmpty && metadata.endOfStream)
    }

    private enum ChunkedBody {
        /// The decoded body and the index after its last line.
        case complete(Data, Data.Index)
        /// More bytes are needed.
        case incomplete
        /// A malformed chunk (400) or a body over the limit (413): answered, then closed.
        case invalid(Response)
    }

    /// The chunked body starting at `start`. Hostile input never traps: a chunk size must be 1–8
    /// hex digits (no sign, no overflow) and the decoded body at most `limit` bytes.
    private static func chunkedBody(_ data: Data, from start: Data.Index, limit: Int) -> ChunkedBody {
        let crlf = Data("\r\n".utf8)
        var body = Data()
        var index = start
        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else { return .incomplete }
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
                .split(separator: ";", omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !sizeText.isEmpty, sizeText.count <= 8, sizeText.allSatisfy(\.isHexDigit), let size = Int(sizeText, radix: 16) else {
                return .invalid(.empty(400, "Bad Request"))
            }
            guard size <= limit - body.count else { return .invalid(.empty(413, "Content Too Large")) }
            let chunkStart = lineEnd.upperBound
            if size == 0 {
                // Trailers (none expected) end with an empty line.
                guard let end = data.range(of: crlf, in: chunkStart..<data.endIndex) else { return .incomplete }
                if end.lowerBound == chunkStart { return .complete(body, end.upperBound) }
                guard let trailerEnd = data.range(of: Data("\r\n\r\n".utf8), in: chunkStart..<data.endIndex) else { return .incomplete }
                return .complete(body, trailerEnd.upperBound)
            }
            // `size` is at most `limit` here, so these sums cannot overflow.
            guard data.endIndex - chunkStart >= size + 2 else { return .incomplete }
            let dataEnd = chunkStart + size
            guard data[dataEnd..<(dataEnd + 2)].elementsEqual(crlf) else { return .invalid(.empty(400, "Bad Request")) }
            body.append(data[chunkStart..<dataEnd])
            index = dataEnd + 2
        }
    }

    /// A request `read` passed: its path is /mcp and its token is right (checked from the headers,
    /// before its body was read).
    private func respond(to request: Request) async -> Response {
        guard request.method == "POST" else { return .empty(405, "Method Not Allowed", headers: [("Allow", "POST")]) }
        let message: JSONValue
        do {
            message = try JSONValue.parse(request.body)
        } catch {
            return .json(Self.error(id: .null, code: -32700, message: "Parse error"), status: 400, reason: "Bad Request")
        }
        switch message {
        case .array(let batch):
            var replies: [JSONValue] = []
            for item in batch {
                if let reply = await handle(item) { replies.append(reply) }
            }
            return replies.isEmpty ? .empty(202, "Accepted") : .json(.array(replies))
        default:
            guard let reply = await handle(message) else { return .empty(202, "Accepted") }
            return .json(reply)
        }
    }

    private func authorized(_ header: String?) -> Bool {
        guard let header else { return false }
        let expected = Array("Bearer \(token)".utf8)
        let given = Array(header.utf8)
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    // MARK: - JSON-RPC

    /// The reply to one JSON-RPC message; nil for notifications and responses.
    private func handle(_ message: JSONValue) async -> JSONValue? {
        guard let object = message.objectValue else {
            return Self.error(id: .null, code: -32600, message: "Invalid Request")
        }
        guard let method = object.string("method") else { return nil }  // a response to us: none expected
        guard let id = object["id"] else { return nil }  // a notification (initialized, cancelled, …)
        let params = object.object("params") ?? [:]
        switch method {
        case "initialize":
            let requested = params.string("protocolVersion") ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return Self.result(id: id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(Self.serverName), "version": "1"],
            ])
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            let listed: [JSONValue] = tools.map { tool in
                ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
            }
            return Self.result(id: id, ["tools": .array(listed)])
        case "tools/call":
            guard let name = params.string("name") else {
                return Self.error(id: id, code: -32602, message: "Invalid params: name is missing")
            }
            let output: ToolOutput
            if tools.contains(where: { $0.name == name }) {
                output = await callTool(name, params["arguments"] ?? .object([:]))
            } else {
                output = .error("Unknown tool \(name)")
            }
            return Self.result(id: id, ["content": .array(Self.content(output.content)), "isError": .bool(output.isError)])
        default:
            // Includes `server/discover` (2026-07-28 era): "method not found" makes the client fall
            // back to `initialize`.
            return Self.error(id: id, code: -32601, message: "Method not found")
        }
    }

    private static func content(_ content: ToolResultContent) -> [JSONValue] {
        switch content {
        case .text(let text):
            return [["type": "text", "text": .string(text)]]
        case .blocks(let blocks):
            return blocks.map { block in
                switch block {
                case .text(let text):
                    return ["type": "text", "text": .string(text.text)]
                case .image(let image):
                    if case .base64(let mediaType, let data) = image.source {
                        return ["type": "image", "data": .string(data), "mimeType": .string(mediaType)]
                    }
                    return ["type": "text", "text": .string((try? block.json.serializedString()) ?? "")]
                default:
                    return ["type": "text", "text": .string((try? block.json.serializedString()) ?? "")]
                }
            }
        }
    }

    private static func result(id: JSONValue, _ result: JSONObject) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": .object(result)]
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}
#endif
