import Foundation
import os

/// Settings shared by every call of a `ClaudeClient`.
public struct ClaudeConfiguration: Sendable, Hashable {
    public var baseURL: URL
    /// `anthropic-version` header.
    public var apiVersion: String
    /// `anthropic-beta` values added to every request.
    public var defaultBetas: Set<String>
    public var retryPolicy: RetryPolicy
    /// Idle timeout of a non-streaming call (the whole response arrives at once, so this bounds the call).
    public var requestTimeout: TimeInterval
    /// Idle timeout between bytes of a stream (the API sends `ping` events while the model works).
    public var streamIdleTimeout: TimeInterval
    /// Non-streaming calls above this `max_tokens` are refused with `.streamingRequired`.
    public var maxNonStreamingTokens: Int
    /// Applied to requests that leave `fallbacks` nil, on models that accept server-side fallbacks.
    public var refusalFallback: FallbackPolicy
    public var pricing: PricingTable

    public static let anthropicBaseURL: URL = {
        guard let url = URL(string: "https://api.anthropic.com") else { preconditionFailure("invalid base URL") }
        return url
    }()

    public init(
        baseURL: URL = ClaudeConfiguration.anthropicBaseURL,
        apiVersion: String = "2023-06-01",
        defaultBetas: Set<String> = [],
        retryPolicy: RetryPolicy = .default,
        requestTimeout: TimeInterval = 600,
        streamIdleTimeout: TimeInterval = 180,
        maxNonStreamingTokens: Int = 16_384,
        refusalFallback: FallbackPolicy = .recommended,
        pricing: PricingTable = .standard
    ) {
        self.baseURL = baseURL
        self.apiVersion = apiVersion
        self.defaultBetas = defaultBetas
        self.retryPolicy = retryPolicy
        self.requestTimeout = requestTimeout
        self.streamIdleTimeout = streamIdleTimeout
        self.maxNonStreamingTokens = maxNonStreamingTokens
        self.refusalFallback = refusalFallback
        self.pricing = pricing
    }
}

/// Client for the Anthropic Messages API.
///
/// Every call (successful or failed, retries folded in) is reported to the `CostLedger` with its usage
/// and cost. Prefer `streamMessage` for anything long: non-streaming calls go quiet until the whole
/// response is ready and run into idle timeouts.
///
/// M3.5: with a `backend` (e.g. `ClaudeCodeEngine`, the student's Claude Code CLI) every call goes to
/// the backend instead of the HTTP code below; `ToolLoop` hands whole loops to it. Callers do not
/// change. Gate model work on `isAvailable()`, never on an API key.
public struct ClaudeClient: Sendable {
    public let configuration: ClaudeConfiguration
    private let keyProvider: any APIKeyProvider
    private let transport: any HTTPTransport
    let ledger: any CostLedger
    /// Runs the calls instead of the HTTP code (M3.5); nil: the Messages API.
    let backend: (any ClaudeBackend)?
    private let sleep: @Sendable (Duration) async throws -> Void
    private let random: @Sendable () -> Double

    static let logger = Logger(subsystem: "com.example.studyportal", category: "claude")

    public init(
        configuration: ClaudeConfiguration = ClaudeConfiguration(),
        keyProvider: any APIKeyProvider,
        ledger: any CostLedger = NullCostLedger(),
        transport: any HTTPTransport = URLSessionTransport.shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.configuration = configuration
        self.keyProvider = keyProvider
        self.ledger = ledger
        self.transport = transport
        self.sleep = sleep
        self.random = random
        backend = nil
    }

    /// A client whose calls run on `backend` (M3.5: `ClaudeCodeEngine` on the Mac,
    /// `UnavailableClaudeBackend` elsewhere). `configuration` is used for `prepared` and the
    /// pricing a backend may read.
    public init(
        backend: any ClaudeBackend,
        ledger: any CostLedger = NullCostLedger(),
        configuration: ClaudeConfiguration = ClaudeConfiguration()
    ) {
        self.configuration = configuration
        keyProvider = StaticAPIKeyProvider(nil)
        self.ledger = ledger
        transport = URLSessionTransport.shared
        sleep = { try await Task.sleep(for: $0) }
        random = { Double.random(in: 0..<1) }
        self.backend = backend
    }

    // MARK: - Availability

    /// What serves the calls.
    public var backendKind: ClaudeBackendKind { backend?.kind ?? .messagesAPI }

    /// Whether calls can run now, without a model call (Messages API: a key is saved).
    public func availability() async -> ClaudeAvailability {
        if let backend { return await backend.availability() }
        return await hasAPIKey() ? .ready(ClaudeBackendStatus(kind: .messagesAPI)) : .missingAPIKey
    }

    /// `availability()` found again, without a cached answer.
    public func refreshAvailability() async -> ClaudeAvailability {
        if let backend { return await backend.refreshAvailability() }
        return await availability()
    }

    /// The gate for model work (replaces "an API key is saved"). True while a usage pause holds:
    /// background calls then wait in the backend's queue.
    public func isAvailable() async -> Bool {
        await availability().isReady
    }

    private func hasAPIKey() async -> Bool {
        guard let key = try? await keyProvider.apiKey() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Calls

    /// Non-streaming call. Refused for `max_tokens` above `maxNonStreamingTokens`; use `streamMessage`.
    public func send(_ request: MessageRequest, context: CallContext = CallContext()) async throws -> Message {
        let request = prepared(request)
        try request.validate()
        if let backend {
            return try await backend.streamMessage(request, context: context, ledger: ledger, onEvent: { _ in })
        }
        guard request.maxTokens <= configuration.maxNonStreamingTokens else {
            throw ClaudeError.streamingRequired(maxTokens: request.maxTokens)
        }
        let urlRequest = try makeURLRequest(request, stream: false, apiKey: try await apiKey())
        let started = Date()
        let clock = ContinuousClock.now

        let outcome: AttemptOutcome<Message> = await retrying {
            let (head, data) = try await transport.data(for: urlRequest)
            guard (200..<300).contains(head.status) else {
                throw failure(status: head.status, body: data, headers: head.headers)
            }
            do {
                var message = try Message(json: JSONValue.parse(data))
                message.requestID = head.headers["request-id"]
                return message
            } catch let error as ClaudeError {
                throw AttemptFailure(error: error, retryable: false, retryAfter: nil)
            } catch {
                throw AttemptFailure(
                    error: .decoding("response body is not JSON"), retryable: false, retryAfter: nil)
            }
        }
        await record(
            request: request, context: context, outcome: outcome, partial: nil, started: started,
            elapsed: ContinuousClock.now - clock, streamed: false)
        return try outcome.result.get()
    }

    /// Streaming call. `onEvent` sees every event as it arrives (called off the main actor); the
    /// accumulated final message is returned.
    ///
    /// Failures before the first event (HTTP errors, overload) are retried; once events have been
    /// delivered a failure is thrown, since the consumer has already seen partial output.
    public func streamMessage(
        _ request: MessageRequest,
        context: CallContext = CallContext(),
        onEvent: @escaping @Sendable (StreamEvent) async -> Void = { _ in }
    ) async throws -> Message {
        let request = prepared(request)
        try request.validate()
        if let backend {
            return try await backend.streamMessage(request, context: context, ledger: ledger, onEvent: onEvent)
        }
        let urlRequest = try makeURLRequest(request, stream: true, apiKey: try await apiKey())
        let started = Date()
        let clock = ContinuousClock.now
        var accumulator = MessageAccumulator()
        var delivered = false

        let outcome: AttemptOutcome<Message> = await retrying {
            accumulator = MessageAccumulator()
            let (head, stream) = try await transport.bytes(for: urlRequest)
            guard (200..<300).contains(head.status) else {
                let body = try await collect(stream, limit: 1 << 20)
                throw failure(status: head.status, body: body, headers: head.headers)
            }
            let requestID = head.headers["request-id"]
            var parser = SSEParser()

            func handle(_ sse: SSEEvent) async throws {
                let event: StreamEvent
                do {
                    event = try StreamEvent(sse: sse, requestID: requestID)
                } catch let error as ClaudeError {
                    throw AttemptFailure(error: error, retryable: !delivered && error.isRetryable, retryAfter: nil)
                }
                do {
                    try accumulator.apply(event)
                } catch let error as ClaudeError {
                    throw AttemptFailure(error: error, retryable: false, retryAfter: nil)
                }
                switch event {
                case .ping, .unknown: break
                default: delivered = true
                }
                await onEvent(event)
            }

            do {
                for try await chunk in stream {
                    for byte in chunk {
                        if let sse = parser.push(byte) { try await handle(sse) }
                    }
                }
            } catch let error as URLError where error.code != .cancelled {
                // A dropped connection mid-stream is only retried if nothing reached the consumer yet.
                let code = error.code.rawValue
                throw AttemptFailure(
                    error: .transport(code: code, description: error.localizedDescription),
                    retryable: !delivered && RetryPolicy.isRetryableURLErrorCode(code), retryAfter: nil)
            }
            if let sse = parser.finish() { try await handle(sse) }
            try Task.checkCancellation()
            guard accumulator.isComplete else {
                throw AttemptFailure(error: .streamEndedUnexpectedly, retryable: !delivered, retryAfter: nil)
            }
            do {
                return try accumulator.finalMessage()
            } catch let error as ClaudeError {
                throw AttemptFailure(error: error, retryable: false, retryAfter: nil)
            }
        }
        await record(
            request: request, context: context, outcome: outcome, partial: accumulator.snapshot, started: started,
            elapsed: ContinuousClock.now - clock, streamed: true)
        return try outcome.result.get()
    }

    /// The events of a streaming call as an async sequence. Cancelling iteration cancels the call.
    public func events(
        _ request: MessageRequest, context: CallContext = CallContext()
    ) -> AsyncThrowingStream<StreamEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: StreamEvent.self, throwing: (any Error).self)
        let task = Task {
            do {
                _ = try await streamMessage(request, context: context) { event in
                    continuation.yield(event)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Request building

    /// Applies client defaults (refusal fallback, default betas).
    public func prepared(_ request: MessageRequest) -> MessageRequest {
        var request = request
        if request.fallbacks == nil, request.model.supportsServerSideFallback {
            request.fallbacks = configuration.refusalFallback
        }
        request.betas.formUnion(configuration.defaultBetas)
        return request
    }

    /// The HTTP request for `request`. The key only ever goes into the `x-api-key` header.
    func makeURLRequest(_ request: MessageRequest, stream: Bool, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: configuration.baseURL.appending(path: "v1/messages"))
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = try request.encodedBody(stream: stream)
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        urlRequest.setValue(configuration.apiVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let betas = request.requiredBetas
        if !betas.isEmpty {
            urlRequest.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.timeoutInterval = stream ? configuration.streamIdleTimeout : configuration.requestTimeout
        return urlRequest
    }

    private func apiKey() async throws -> String {
        guard let key = try await keyProvider.apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else { throw ClaudeError.missingAPIKey }
        return key
    }

    // MARK: - Retries

    private struct AttemptFailure: Error {
        var error: ClaudeError
        var retryable: Bool
        var retryAfter: Duration?
    }

    private struct AttemptOutcome<Value: Sendable>: Sendable {
        var result: Result<Value, any Error>
        var attempts: Int
    }

    private func failure(status: Int, body: Data, headers: [String: String]) -> AttemptFailure {
        AttemptFailure(
            error: ClaudeError.from(status: status, body: body, headers: headers),
            retryable: configuration.retryPolicy.shouldRetry(status: status, headers: headers),
            retryAfter: RetryPolicy.retryAfter(headers: headers))
    }

    private func retrying<Value: Sendable>(_ attempt: () async throws -> Value) async -> AttemptOutcome<Value> {
        let policy = configuration.retryPolicy
        var attempts = 0
        while true {
            attempts += 1
            let failure: AttemptFailure
            do {
                return AttemptOutcome(result: .success(try await attempt()), attempts: attempts)
            } catch let error as AttemptFailure {
                failure = error
            } catch let error as URLError where error.code == .cancelled {
                return AttemptOutcome(result: .failure(CancellationError()), attempts: attempts)
            } catch let error as URLError {
                let code = error.code.rawValue
                failure = AttemptFailure(
                    error: .transport(code: code, description: error.localizedDescription),
                    retryable: RetryPolicy.isRetryableURLErrorCode(code), retryAfter: nil)
            } catch let error as ClaudeError {
                failure = AttemptFailure(error: error, retryable: error.isRetryable, retryAfter: nil)
            } catch {
                // CancellationError and anything unexpected end the call.
                return AttemptOutcome(result: .failure(error), attempts: attempts)
            }

            let retry = attempts - 1
            guard failure.retryable, retry < policy.maxRetries, !Task.isCancelled else {
                return AttemptOutcome(result: .failure(failure.error), attempts: attempts)
            }
            let delay = policy.delay(beforeRetry: retry, retryAfter: failure.retryAfter, random: random)
            Self.logger.notice(
                "Retrying after \(failure.error.description, privacy: .public) in \(delay.description, privacy: .public)"
            )
            do {
                try await sleep(delay)
            } catch {
                return AttemptOutcome(result: .failure(error), attempts: attempts)
            }
        }
    }

    private func collect(_ stream: AsyncThrowingStream<[UInt8], any Error>, limit: Int) async throws -> Data {
        var data = Data()
        for try await chunk in stream {
            data.append(contentsOf: chunk.prefix(max(0, limit - data.count)))
            if data.count >= limit { break }
        }
        return data
    }

    // MARK: - Ledger

    private func record(
        request: MessageRequest, context: CallContext, outcome: AttemptOutcome<Message>, partial: Message?,
        started: Date, elapsed: Duration, streamed: Bool
    ) async {
        let message: Message?
        let errorDescription: String?
        switch outcome.result {
        case .success(let value):
            message = value
            errorDescription = nil
        case .failure(let error):
            message = partial
            errorDescription = (error as? ClaudeError)?.description
                ?? (error is CancellationError ? "cancelled" : String(describing: type(of: error)))
        }
        let servedModel = message.map(\.model).flatMap { $0.rawValue.isEmpty ? nil : $0 } ?? request.model
        let usage = message?.usage ?? Usage()
        let cost = configuration.pricing.cost(of: usage, model: servedModel)
        let requestID = message?.requestID ?? failureRequestID(outcome)
        let callRecord = CallRecord(
            model: servedModel, requestedModel: request.model, purpose: context.purpose, lectureID: context.lectureID,
            requestID: requestID, usage: usage, costUSD: cost, startedAt: started, duration: elapsed,
            stopReason: message?.stopReason, error: errorDescription, streamed: streamed, attempts: outcome.attempts)

        if let errorDescription {
            Self.logger.error(
                "\(context.purpose, privacy: .public) \(servedModel.rawValue, privacy: .public) failed after \(outcome.attempts) attempt(s): \(errorDescription, privacy: .public)"
            )
        } else {
            Self.logger.info(
                "\(context.purpose, privacy: .public) \(servedModel.rawValue, privacy: .public) \(requestID ?? "-", privacy: .public) in=\(usage.inputTokens) cacheRead=\(usage.cacheReadInputTokens) cacheWrite=\(usage.cacheCreationInputTokens) out=\(usage.outputTokens) stop=\(message?.stopReason?.rawValue ?? "-", privacy: .public) cost=\(cost ?? -1) ms=\(callRecord.durationMilliseconds)"
            )
            if cost == nil {
                Self.logger.warning("No price for model \(servedModel.rawValue, privacy: .public)")
            }
        }
        do {
            try await ledger.record(callRecord)
        } catch {
            Self.logger.error("Cost ledger failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func failureRequestID(_ outcome: AttemptOutcome<Message>) -> String? {
        if case .failure(let error) = outcome.result { return (error as? ClaudeError)?.requestID }
        return nil
    }
}
