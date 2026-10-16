import Foundation

/// A raw HTTP response head: status and lowercased header names.
public struct HTTPResponseHead: Sendable, Hashable {
    public var status: Int
    /// Header names lowercased.
    public var headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
    }

    init(_ response: HTTPURLResponse) {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key.lowercased()] = value }
        }
        self.init(status: response.statusCode, headers: headers)
    }
}

/// The HTTP layer under `ClaudeClient`; swapped for a fake in tests.
public protocol HTTPTransport: Sendable {
    /// Sends a request and returns the full body.
    func data(for request: URLRequest) async throws -> (HTTPResponseHead, Data)
    /// Sends a request and returns the body as byte chunks as they arrive.
    func bytes(for request: URLRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<[UInt8], any Error>)
}

/// `URLSession` transport. Uses an ephemeral session so responses (which can contain private
/// content) are never written to a disk cache.
public struct URLSessionTransport: HTTPTransport {
    public let session: URLSession

    /// One shared session for the process (sessions are long-lived; do not create one per call).
    public static let shared = URLSessionTransport()

    public init(session: URLSession) {
        self.session = session
    }

    /// A dedicated ephemeral session. `URLRequest.timeoutInterval` (set per call by the client) is the
    /// idle timeout; `resourceTimeout` bounds a whole call, including long streams.
    public init(resourceTimeout: TimeInterval = 2 * 60 * 60) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }

    public func data(for request: URLRequest) async throws -> (HTTPResponseHead, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (HTTPResponseHead(http), data)
    }

    public func bytes(for request: URLRequest) async throws -> (HTTPResponseHead, AsyncThrowingStream<[UInt8], any Error>) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: [UInt8].self, throwing: (any Error).self)
        let pump = Task {
            var chunk: [UInt8] = []
            chunk.reserveCapacity(4096)
            do {
                for try await byte in bytes {
                    chunk.append(byte)
                    // Hand over complete lines immediately so events are not delayed.
                    if byte == 0x0A || chunk.count >= 16_384 {
                        continuation.yield(chunk)
                        chunk.removeAll(keepingCapacity: true)
                    }
                }
                if !chunk.isEmpty { continuation.yield(chunk) }
                continuation.finish()
            } catch {
                if !chunk.isEmpty { continuation.yield(chunk) }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in pump.cancel() }
        return (HTTPResponseHead(http), stream)
    }
}
