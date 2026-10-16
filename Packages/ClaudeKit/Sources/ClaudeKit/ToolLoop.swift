import Foundation

/// The result of running one client tool call.
public struct ToolOutput: Sendable, Hashable {
    public var content: ToolResultContent
    public var isError: Bool

    public init(content: ToolResultContent, isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ text: String) -> ToolOutput {
        ToolOutput(content: .text(text))
    }

    /// A JSON result, serialized deterministically.
    public static func json(_ value: JSONValue) -> ToolOutput {
        ToolOutput(content: .text((try? value.serializedString()) ?? "null"))
    }

    /// A failed call; Claude sees the message and can adapt.
    public static func error(_ message: String) -> ToolOutput {
        ToolOutput(content: .text(message), isError: true)
    }
}

/// Runs one client tool call. Thrown errors become `is_error` results.
public typealias ToolHandler = @Sendable (ToolUseBlock) async throws -> ToolOutput

/// Progress of a tool loop.
public enum ToolLoopEvent: Sendable {
    /// A streaming event of API call number `iteration` (1-based).
    case stream(iteration: Int, StreamEvent)
    /// A turn appended to the history.
    case appended(MessageParam)
    case toolStarted(ToolUseBlock)
    case toolFinished(ToolUseBlock, ToolOutput)
}

/// Why a tool loop stopped.
public enum ToolLoopStop: Sendable, Hashable {
    /// `end_turn` or `stop_sequence`: the final assistant turn was appended.
    case endTurn
    /// Declined. The refused turn was not appended; partial output must be discarded.
    case refusal(StopDetails?)
    /// The output hit `max_tokens` (or the context window). Not appended: retry with a higher
    /// `max_tokens` on the same history. Tools of the truncated turn did not run.
    case truncated
    /// `maxIterations` API calls were made. The history is consistent (tool results appended, or a
    /// paused server-tool turn) and the loop resumes when run again on `messages`.
    case iterationLimit
    /// Any other stop reason; the turn was appended.
    case other(StopReason?)
}

public struct ToolLoopResult: Sendable {
    /// The full history: the request's messages followed by every appended turn.
    public var messages: [MessageParam]
    /// Only the turns this run appended.
    public var appended: [MessageParam]
    /// The last response (appended or not, see `stop`).
    public var finalMessage: Message
    public var stop: ToolLoopStop
    /// API calls made.
    public var iterations: Int
    /// Usage summed over all calls.
    public var usage: Usage
}

/// Send → run client tools → append all `tool_result` blocks in one user message → repeat, until the
/// model ends its turn.
///
/// The history is append-only: earlier turns are never edited or removed, assistant turns go back
/// exactly as received (thinking blocks and signatures included), and the request's system prompt and
/// tool set stay fixed for the whole loop. That keeps the prompt cache and preserved thinking valid.
public struct ToolLoop: Sendable {
    public var client: ClaudeClient
    /// Maximum API calls per run.
    public var maxIterations: Int
    /// Stream each call (default; required for long turns).
    public var streaming: Bool
    /// Run the calls of one turn concurrently. Results are returned in call order either way.
    public var parallelToolExecution: Bool

    public init(client: ClaudeClient, maxIterations: Int = 16, streaming: Bool = true, parallelToolExecution: Bool = true) {
        self.client = client
        self.maxIterations = maxIterations
        self.streaming = streaming
        self.parallelToolExecution = parallelToolExecution
    }

    /// Runs the loop. `request.messages` is the history so far and should end with a user turn.
    public func run(
        _ request: MessageRequest,
        context: CallContext = CallContext(),
        handler: @escaping ToolHandler,
        onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void = { _ in }
    ) async throws -> ToolLoopResult {
        var history = request.messages
        var appended: [MessageParam] = []
        var usage = Usage()
        var iteration = 0

        func append(_ turn: MessageParam) async {
            history.append(turn)
            appended.append(turn)
            await onEvent(.appended(turn))
        }

        while true {
            iteration += 1
            var turnRequest = request
            turnRequest.messages = history
            let message: Message
            if streaming {
                let current = iteration
                message = try await client.streamMessage(turnRequest, context: context) { event in
                    await onEvent(.stream(iteration: current, event))
                }
            } else {
                message = try await client.send(turnRequest, context: context)
            }
            usage = usage + message.usage

            func result(_ stop: ToolLoopStop) -> ToolLoopResult {
                ToolLoopResult(
                    messages: history, appended: appended, finalMessage: message, stop: stop, iterations: iteration,
                    usage: usage)
            }

            switch message.stopReason {
            case .refusal?:
                return result(.refusal(message.stopDetails))
            case .maxTokens?, .modelContextWindowExceeded?:
                return result(.truncated)
            case .pauseTurn?:
                // A server-tool loop paused: send the turn back unchanged and the server resumes.
                await append(.assistant(message))
                if iteration >= maxIterations { return result(.iterationLimit) }
                continue
            case .toolUse?:
                let calls = message.toolUses
                guard !calls.isEmpty else {
                    await append(.assistant(message))
                    return result(.other(message.stopReason))
                }
                await append(.assistant(message))
                let outputs = try await execute(calls, handler: handler, onEvent: onEvent)
                let results = zip(calls, outputs).map { call, output in
                    ContentBlock.toolResult(ToolResultBlock(
                        toolUseID: call.id, content: output.content, isError: output.isError))
                }
                await append(.user(results))
                if iteration >= maxIterations { return result(.iterationLimit) }
            case .endTurn?, .stopSequence?:
                await append(.assistant(message))
                return result(.endTurn)
            default:
                await append(.assistant(message))
                return result(.other(message.stopReason))
            }
        }
    }

    private func execute(
        _ calls: [ToolUseBlock], handler: @escaping ToolHandler,
        onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> [ToolOutput] {
        @Sendable func run(_ call: ToolUseBlock) async -> ToolOutput {
            if let raw = call.invalidInputJSON {
                // Unparseable streamed input: never run the tool; let Claude retry.
                return .error((try? JSONValue.object(["INVALID_JSON": .string(raw)]).serializedString()) ?? "INVALID_JSON")
            }
            await onEvent(.toolStarted(call))
            let output: ToolOutput
            do {
                output = try await handler(call)
            } catch is CancellationError {
                output = .error("cancelled")
            } catch {
                output = .error(String(describing: error))
            }
            await onEvent(.toolFinished(call, output))
            return output
        }

        var outputs: [ToolOutput]
        if parallelToolExecution, calls.count > 1 {
            outputs = await withTaskGroup(of: (Int, ToolOutput).self) { group in
                for (index, call) in calls.enumerated() {
                    group.addTask { (index, await run(call)) }
                }
                var collected = [ToolOutput?](repeating: nil, count: calls.count)
                for await (index, output) in group { collected[index] = output }
                return collected.map { $0 ?? .error("no result") }
            }
        } else {
            outputs = []
            for call in calls { outputs.append(await run(call)) }
        }
        try Task.checkCancellation()
        return outputs
    }
}
