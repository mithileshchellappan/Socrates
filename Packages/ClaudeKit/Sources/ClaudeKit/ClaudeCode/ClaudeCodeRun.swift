#if os(macOS)
import Foundation

/// A usage limit stopped a run (docs/plan-m35.md §3.6). The engine pauses its queue until
/// `resetsAt` (now + 1 h when unknown) and throws `ClaudeError.usageLimited`.
struct UsageLimitHit: Error, CustomStringConvertible {
    var resetsAt: Date?

    var description: String {
        "usage limit reached" + (resetsAt.map { " until \($0.formatted(.iso8601))" } ?? "")
    }
}

/// Why a tool-loop launch is relaunched (never seen by callers).
enum RunRelaunch: Error {
    /// `system/init` did not show the app's MCP server connected and only its tools.
    case isolation
    /// `--session-id` on an existing session ("already in use").
    case sessionInUse
    /// `--resume` on an unknown session ("No conversation found").
    case sessionNotFound
}

/// How a tool loop names its CLI session.
enum SessionFlag: Sendable {
    case none
    case start(UUID)
    case resume(UUID)

    var arguments: [String] {
        switch self {
        case .none: ["--no-session-persistence"]
        case .start(let id): ["--session-id", id.uuidString.lowercased()]
        case .resume(let id): ["--resume", id.uuidString.lowercased()]
        }
    }
}

/// Everything one CLI launch needs.
struct ClaudeCodeCall: Sendable {
    var binary: URL
    var configuration: ClaudeCodeConfiguration
    var request: MessageRequest
    var context: CallContext
    var ledger: any CostLedger

    static let toolPrefix = ClaudeCodeConfiguration.toolNamePrefix

    // MARK: Arguments

    /// Flags shared by one-shot calls and tool loops (no built-in tool).
    var commonArguments: [String] { arguments(tools: "") }

    /// The shared flags with `--tools <tools>` (the CLI's built-in tools, comma separated; "" =
    /// none).
    func arguments(tools: String) -> [String] {
        let system = request.system.map(\.text).joined(separator: "\n\n")
        return [
            "-p", "--tools", tools, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", request.model.rawValue, "--effort", request.effort.rawValue,
            // An empty value would bring back the CLI's own coding-agent prompt.
            "--system-prompt", system.isEmpty ? "Answer the user's message." : system,
        ]
    }

    func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ClaudeCodeEngine.childEnvironment(binary: binary)
        environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = String(request.maxTokens)
        environment.merge(extra) { _, new in new }
        return environment
    }

    /// The stdin line: one stream-json user message.
    static func inputLine(_ blocks: [JSONValue]) throws -> Data {
        let line: JSONValue = [
            "type": "user",
            "message": ["role": "user", "content": .array(blocks)],
            "parent_tool_use_id": .null,
            "session_id": "",
        ]
        return try line.serialized() + Data([0x0A])
    }

    /// Text, image and document blocks of user turns, in order, without `cache_control` (not sent).
    static func promptBlocks(_ turns: [MessageParam], droppingToolResults: Bool) throws -> [JSONValue] {
        var blocks: [JSONValue] = []
        for block in turns.flatMap(\.content.blocks) {
            switch block {
            case .text, .image, .document:
                guard var object = block.json.objectValue else { continue }
                object["cache_control"] = nil
                blocks.append(.object(object))
            case .toolResult where droppingToolResults:
                continue
            default:
                throw ClaudeError.invalidArgument("Claude Code takes text, image and document blocks in the prompt, not \(block.type)")
            }
        }
        guard !blocks.isEmpty else { throw ClaudeError.invalidArgument("the user turn has nothing to send") }
        return blocks
    }

    // MARK: Ledger

    /// One `CallRecord` per API call (`billing: .subscription`, the cost notional at list prices).
    func record(_ message: Message?, error: String?, startedAt: Date, elapsed: Duration) async {
        let model = message.map(\.model).flatMap { $0.rawValue.isEmpty ? nil : $0 } ?? request.model
        let usage = message?.usage ?? Usage()
        let cost = configuration.pricing.cost(of: usage, model: model)
        let requestID = message.flatMap { $0.id.isEmpty ? nil : $0.id }
        let record = CallRecord(
            model: model, requestedModel: request.model, purpose: context.purpose, lectureID: context.lectureID,
            requestID: requestID, usage: usage, costUSD: cost, startedAt: startedAt, duration: elapsed,
            stopReason: message?.stopReason, error: error, streamed: true, attempts: 1, billing: .subscription)
        let logger = ClaudeClient.logger
        if let error {
            logger.error(
                "\(context.purpose, privacy: .public) \(model.rawValue, privacy: .public) via Claude Code failed: \(error, privacy: .public)"
            )
        } else {
            logger.info(
                "\(context.purpose, privacy: .public) \(model.rawValue, privacy: .public) \(requestID ?? "-", privacy: .public) via Claude Code in=\(usage.inputTokens) cacheRead=\(usage.cacheReadInputTokens) cacheWrite=\(usage.cacheCreationInputTokens) out=\(usage.outputTokens) stop=\(message?.stopReason?.rawValue ?? "-", privacy: .public) notionalCost=\(cost ?? -1) ms=\(record.durationMilliseconds)"
            )
        }
        do {
            try await ledger.record(record)
        } catch {
            logger.error("Cost ledger failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// One more `CallRecord` for the API calls a web run's tools made inside the CLI (WebSearch
    /// sends its own request, which is not streamed): the CLI's `total_cost_usd` minus the
    /// streamed calls, no tokens, no request id. Nothing below a fifth of a cent.
    func recordUnstreamedCost(result: JSONObject?, streamed: [Message], startedAt: Date, elapsed: Duration) async {
        guard let total = result?["total_cost_usd"]?.doubleValue else { return }
        let recorded = streamed.reduce(0.0) { $0 + (configuration.pricing.cost(of: $1.usage, model: $1.model) ?? 0) }
        // The tools' own calls run on another model (WebSearch/WebFetch on Haiku 4.5 in CLI
        // 2.1.268): `modelUsage` prices them per model. `total - recorded` would also count the
        // streamed model at the CLI's price, which is wrong for a model the CLI does not know yet
        // (it priced Haiku 5.5 about 150 times too high in the M4 live check).
        let streamedModels = Set(streamed.map(\.model.rawValue))
        let rest: Double
        if let perModel = result?.object("modelUsage"), !perModel.isEmpty {
            rest = perModel.filter { !streamedModels.contains($0.key) }
                .reduce(0.0) { $0 + ($1.value.objectValue?["costUSD"]?.doubleValue ?? 0) }
        } else {
            rest = total - recorded
        }
        guard rest >= 0.002 else { return }
        let record = CallRecord(
            model: request.model, requestedModel: request.model, purpose: context.purpose, lectureID: context.lectureID,
            requestID: nil, usage: Usage(), costUSD: rest, startedAt: startedAt, duration: elapsed,
            stopReason: nil, error: nil, streamed: false, attempts: 1, billing: .subscription)
        ClaudeClient.logger.info(
            "\(context.purpose, privacy: .public) web tools inside Claude Code notionalCost=\(rest) (total \(total), streamed \(recorded))"
        )
        do {
            try await ledger.record(record)
        } catch {
            ClaudeClient.logger.error("Cost ledger failed: \(String(describing: error), privacy: .public)")
        }
    }
}

/// What a tool loop sends on stdin, by what the CLI session already holds.
struct ToolLoopPrompts: Sendable {
    /// Every user turn after the last assistant turn, merged (tool results dropped: the session
    /// has them). A turn whose run failed before the CLI started (a usage pause) never reached the
    /// session; sending only the newest would lose it, and its `<mail>` envelope with it.
    let unsent: [JSONValue]
    /// The newest user turn alone: the session exists and holds the turns before it (an earlier
    /// run reached the CLI but stored no answer).
    let newest: [JSONValue]
    /// The stored history as one delimited text block, then `unsent`: the CLI deleted the session
    /// (it prunes sessions older than its `cleanupPeriodDays`), so a new one starts from the text.
    let replay: [JSONValue]

    init(_ messages: [MessageParam]) throws {
        let answered = messages.lastIndex { $0.role == .assistant }
        let pending = messages[(answered.map { $0 + 1 } ?? messages.startIndex)...].filter { $0.role == .user }
        guard let last = pending.last else { throw ClaudeError.invalidArgument("a tool loop needs a user turn") }
        let unsent = try ClaudeCodeCall.promptBlocks(pending, droppingToolResults: true)
        self.unsent = unsent
        newest = (try? ClaudeCodeCall.promptBlocks([last], droppingToolResults: true)) ?? unsent
        replay = answered.map { [Self.history(messages[...$0])] + unsent } ?? unsent
    }

    /// The student's words and the agent's text answers in order, as one text block; the context
    /// blocks (a `<mail>` envelope, before the words) only of the latest user turn that had any.
    static func history(_ turns: ArraySlice<MessageParam>) -> JSONValue {
        func texts(_ turn: MessageParam) -> [String] {
            turn.content.blocks.compactMap(\.textValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let withContext = turns.lastIndex { $0.role == .user && texts($0).count > 1 }
        var parts: [String] = []
        for index in turns.indices {
            let turn = turns[index]
            let text = texts(turn)
            guard let words = text.last else { continue }
            if turn.role == .user {
                parts.append("<student>\n\((index == withContext ? text : [words]).joined(separator: "\n\n"))\n</student>")
            } else {
                parts.append("<assistant>\n\(text.joined(separator: "\n\n"))\n</assistant>")
            }
        }
        let text = """
            The conversation so far, for context (its earlier session is gone):
            <conversation>
            \(parts.joined(separator: "\n"))
            </conversation>
            """
        return ["type": "text", "text": .string(text)]
    }
}

/// The parts of the CLI's stdout that are not API messages.
struct CLIOutput {
    var initLine: JSONObject?
    var result: JSONObject?
    /// A `rate_limit_event` said `rejected`, with its `resetsAt` if given.
    var rejected = false
    var rejectedResetsAt: Date?
    /// Texts of the CLI's own error turns (`assistant` lines with `error`, model `<synthetic>`).
    var errorTexts: [String] = []

    var isSuccess: Bool {
        guard let result else { return false }
        return result.string("subtype") == "success" && result.bool("is_error") != true
    }

    /// The error texts the CLI printed, for detection and a readable message (never prompt
    /// content: a successful result's text is the answer and is not included).
    func failureTexts(standardError: String) -> [String] {
        var texts = errorTexts
        if let result, !isSuccess {
            if let text = result.string("result"), !text.isEmpty { texts.append(text) }
            texts.append(contentsOf: (result.array("errors") ?? []).compactMap(\.stringValue))
        }
        if let line = standardError.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            texts.append(String(line))
        }
        return texts
    }

    mutating func observe(_ object: JSONObject) {
        switch object.string("type") {
        case "system" where object.string("subtype") == "init":
            if initLine == nil { initLine = object }
        case "result":
            result = object
        case "rate_limit_event":
            let info = object.object("rate_limit_info") ?? [:]
            switch info.string("status") {
            case "rejected":
                rejected = true
                if let seconds = info["resetsAt"]?.doubleValue { rejectedResetsAt = Date(timeIntervalSince1970: seconds) }
            case "allowed_warning":
                ClaudeClient.logger.notice("Claude Code usage nearing its limit (\(info.string("rateLimitType") ?? "?", privacy: .public))")
            default:
                break
            }
        case "assistant":
            let message = object.object("message") ?? [:]
            guard object["error"] != nil || message.string("model") == "<synthetic>" else { return }
            let text = (message.array("content") ?? []).compactMap { $0["text"]?.stringValue }.joined(separator: " ")
            if !text.isEmpty { errorTexts.append(text) }
        default:
            break
        }
    }

    /// The error a failed run throws: a usage limit, a sign-in problem, or the CLI's message.
    func failure(standardError: String, status: Int32) -> any Error {
        let texts = failureTexts(standardError: standardError)
        if let limit = texts.first(where: UsageLimitText.isLimit) ?? (rejected ? "" : nil) {
            let resetsAt = rejectedResetsAt ?? UsageLimitText.resetDate(in: limit, now: Date())
            return UsageLimitHit(resetsAt: resetsAt)
        }
        if texts.contains(where: { $0.contains("/login") || $0.localizedCaseInsensitiveContains("not logged in") }) {
            return ClaudeError.unavailable(.signedOut)
        }
        // M5: the run ran out of turns (a one-shot web run that kept searching): the request's
        // doing, so the caller decides (StudyPass counts it as done without sources).
        if result?.string("subtype") == "error_max_turns" {
            let turns = result?.int("num_turns").map { " after \($0) turns" } ?? ""
            return ClaudeError.turnLimit("the run reached its turn limit\(turns)")
        }
        let reason = texts.first.map { String($0.prefix(300)) }
            ?? result?.string("subtype").map { "the run ended with \($0)" }
            ?? "the process exited with status \(status) without an answer"
        // The CLI has already retried these; as retryable errors the work stays pending.
        let lower = reason.lowercased()
        // A CLI too old for the model ("Claude Code 2.1.268 does not support this model; version
        // 2.1.280 or newer is required. Run 'claude update'…", M4 live check): nothing about the
        // request, so the work waits for the student's update instead of counting attempts.
        if lower.contains("claude update") || lower.contains("or newer is required") {
            return ClaudeError.claudeCodeProcess(reason)
        }
        if lower.contains("overloaded") || lower.contains("529") {
            return ClaudeError.overloaded(APIErrorInfo(status: 529, type: "overloaded_error", message: reason))
        }
        if lower.contains("api error: 5") || lower.contains("internal server error") {
            return ClaudeError.server(APIErrorInfo(status: 500, type: "api_error", message: reason))
        }
        if lower.contains("connection error") || lower.contains("timed out") || lower.contains("econn")
            || lower.contains("fetch failed") {
            return ClaudeError.transport(code: URLError.Code.networkConnectionLost.rawValue, description: reason)
        }
        // No result line: the process failed on its own (crashed, killed, a flag a CLI update
        // dropped), not because of what was asked; the work waits instead of counting an attempt.
        guard result != nil else { return ClaudeError.claudeCodeProcess(reason) }
        return ClaudeError.claudeCode(reason)
    }

    /// The `total_cost_usd` the CLI reports beside the sum of the recorded calls (debug only).
    func logCost(recorded: [Message], pricing: PricingTable) {
        guard let total = result?["total_cost_usd"]?.doubleValue else { return }
        let sum = recorded.reduce(0.0) { $0 + (pricing.cost(of: $1.usage, model: $1.model) ?? 0) }
        ClaudeClient.logger.debug("Claude Code total_cost_usd=\(total) recorded=\(sum) turns=\(self.result?.int("num_turns") ?? -1)")
    }
}

/// Folds `stream_event` lines into API messages.
struct MessageTracker {
    private(set) var accumulator: MessageAccumulator?
    private(set) var iteration = 0
    private(set) var completed: [Message] = []
    private var requestID: String?
    private var segmentStart = Date()
    private var segmentClock = ContinuousClock.now
    /// Open tool_use blocks by stream index → id.
    private var openToolUses: [Int: String] = [:]

    enum Step {
        case ignored
        case event(StreamEvent)
        case toolUseCompleted(StreamEvent, ToolUseBlock)
        case messageCompleted(StreamEvent, Message)
    }

    var isMessageOpen: Bool { accumulator.map { !$0.isComplete } ?? false }

    var usage: Usage { completed.reduce(Usage()) { $0 + $1.usage } }

    /// Applies one `stream_event` line. A new `message_start` while a message is open records
    /// the open one as interrupted first (through `interrupted`).
    mutating func apply(_ line: JSONObject, interrupted: (Message?, Date, Duration) async -> Void) async -> Step {
        guard line["parent_tool_use_id"]?.isNull ?? true, let json = line["event"] else { return .ignored }
        if json["type"]?.stringValue == "message_start" {
            if isMessageOpen {
                await interrupted(accumulator?.snapshot, segmentStart, ContinuousClock.now - segmentClock)
                restartSegment()
            }
            requestID = json["message"]?["id"]?.stringValue
            accumulator = MessageAccumulator()
            openToolUses = [:]
            iteration += 1
        }
        let event: StreamEvent
        do {
            event = try StreamEvent(json: json, requestID: requestID)
        } catch {
            ClaudeClient.logger.notice("Claude Code stream event skipped: \(String(describing: error), privacy: .public)")
            return .ignored
        }
        guard accumulator != nil else { return .ignored }
        do {
            try accumulator?.apply(event)
        } catch {
            ClaudeClient.logger.notice("Claude Code stream event not applied: \(String(describing: error), privacy: .public)")
            return .event(event)
        }
        switch event {
        case .contentBlockStart(let index, .toolUse(let use)):
            openToolUses[index] = use.id
        case .contentBlockStop(let index):
            if let id = openToolUses.removeValue(forKey: index),
               let use = accumulator?.snapshot?.toolUses.first(where: { $0.id == id }) {
                return .toolUseCompleted(event, use)
            }
        case .messageStop:
            if let message = try? accumulator?.finalMessage() {
                completed.append(message)
                return .messageCompleted(event, message)
            }
        default:
            break
        }
        return .event(event)
    }

    /// Where the segment of the completed message began, and how long it took; starts the next.
    mutating func takeSegment() -> (Date, Duration) {
        defer { restartSegment() }
        return (segmentStart, ContinuousClock.now - segmentClock)
    }

    /// The open message, if any, with its segment (recorded as failed with partial usage).
    var openMessage: (Message?, Date, Duration)? {
        guard isMessageOpen else { return nil }
        return (accumulator?.snapshot, segmentStart, ContinuousClock.now - segmentClock)
    }

    private mutating func restartSegment() {
        segmentStart = Date()
        segmentClock = ContinuousClock.now
    }
}

enum ClaudeCodeRun {
    static func parse(_ line: Data) -> JSONObject? {
        (try? JSONValue.parse(line))?.objectValue
    }

    // MARK: - One-shot

    /// One model call (docs/plan-m35.md §3.4): `--safe-mode --no-session-persistence --tools ""`,
    /// the single user turn on stdin. With `outputFormat`, the returned message's text is the
    /// `structured_output` JSON (sorted keys) and `onEvent` sees events of that message;
    /// otherwise it sees the API message's own events.
    ///
    /// With `web` (M4 research runs): `--tools` and `--allowedTools` name only the CLI's
    /// WebSearch/WebFetch, `--permission-mode dontAsk`, `--max-turns`, no MCP server, isolation
    /// `variant`. The `system/init` line must list exactly those tools and no MCP server, else the
    /// child is killed before the first model call and `RunRelaunch.isolation` is thrown. The CLI
    /// runs its tools across several API calls (each one ledger row, plus one for the tools' own
    /// unstreamed calls); the answer is the final message (or the structured output), whose
    /// events `onEvent` sees at the end.
    static func oneShot(
        _ call: ClaudeCodeCall, web: (tools: WebToolSet, variant: IsolationVariant)? = nil,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void
    ) async throws -> Message {
        let request = call.request
        guard request.messages.count == 1, let turn = request.messages.first, turn.role == .user else {
            throw ClaudeError.invalidArgument("Claude Code one-shot calls take exactly one user turn; use ToolLoop for conversations")
        }
        guard web != nil || request.tools.isEmpty else {
            throw ClaudeError.invalidArgument("tools need a ToolLoop on the Claude Code backend")
        }
        let input = try ClaudeCodeCall.inputLine(try ClaudeCodeCall.promptBlocks([turn], droppingToolResults: false))
        var arguments: [String]
        if let web {
            arguments = call.arguments(tools: web.tools.names.joined(separator: ",")) + web.tools.arguments(variant: web.variant)
        } else {
            arguments = call.commonArguments + ["--safe-mode", "--no-session-persistence"]
        }
        if let format = request.outputFormat {
            arguments += ["--json-schema", try format.schema.serializedString()]
        }
        try FileManager.default.createDirectory(at: call.configuration.workspace, withIntermediateDirectories: true)
        let spec = ChildProcessSpec(
            executable: call.binary, arguments: arguments, environment: call.environment(),
            directory: call.configuration.workspace, input: input)

        let structured = request.outputFormat != nil
        let runStarted = Date()
        let runClock = ContinuousClock.now
        var tracker = MessageTracker()
        var output = CLIOutput()
        var answer: Message?
        var initChecked = false
        var isolationFailed = false
        let processResult: ChildProcessResult
        do {
            processResult = try await ChildProcess.run(spec) { line in
                guard let object = parse(line) else { return .proceed }
                output.observe(object)
                if let web {
                    if object.string("type") == "system", object.string("subtype") == "init", !initChecked {
                        initChecked = true
                        guard web.tools.holds(object, structured: structured, variant: web.variant) else {
                            isolationFailed = true
                            return .stop
                        }
                        return .proceed
                    }
                    if object.string("type") == "stream_event", !initChecked {
                        // No init event before the first model call: isolation is unverified.
                        isolationFailed = true
                        return .stop
                    }
                }
                guard object.string("type") == "stream_event" else { return .proceed }
                let step = await tracker.apply(object) { partial, started, elapsed in
                    await call.record(partial, error: "interrupted", startedAt: started, elapsed: elapsed)
                }
                // A web run's events come at the end, as the final message's.
                let forward = web == nil && !structured && tracker.iteration == 1
                switch step {
                case .ignored:
                    return .proceed
                case .event(let event), .toolUseCompleted(let event, _):
                    if forward { await onEvent(event) }
                    return .proceed
                case .messageCompleted(let event, let message):
                    if forward { await onEvent(event) }
                    let (started, elapsed) = tracker.takeSegment()
                    await call.record(message, error: nil, startedAt: started, elapsed: elapsed)
                    guard answer == nil else { return .proceed }
                    if structured {
                        // The structured output comes in the result line. A cut-off or declined
                        // message is final too: the CLI would ask the model again (one more full
                        // call per attempt).
                        guard [.maxTokens, .refusal, .modelContextWindowExceeded].contains(message.stopReason) else { return .proceed }
                        answer = message
                        return .stop
                    }
                    // The CLI runs its web tools and calls the model again.
                    if web != nil, message.stopReason == .toolUse || message.stopReason == .pauseTurn { return .proceed }
                    answer = message
                    // A cut-off or declined answer is final; the CLI must not continue it.
                    return message.stopReason == .endTurn || message.stopReason == .stopSequence ? .proceed : .stop
                }
            }
        } catch {
            if let (partial, started, elapsed) = tracker.openMessage {
                await call.record(partial, error: error is CancellationError ? "cancelled" : String(describing: error), startedAt: started, elapsed: elapsed)
            }
            throw error
        }
        if let (partial, started, elapsed) = tracker.openMessage {
            await call.record(partial, error: "interrupted", startedAt: started, elapsed: elapsed)
        }
        if isolationFailed {
            ClaudeClient.logger.notice("Claude Code web isolation \(web?.variant.rawValue ?? "?", privacy: .public) failed its init check")
            throw RunRelaunch.isolation
        }
        output.logCost(recorded: tracker.completed, pricing: call.configuration.pricing)
        if web != nil {
            await call.recordUnstreamedCost(
                result: output.result, streamed: tracker.completed, startedAt: runStarted, elapsed: ContinuousClock.now - runClock)
        }

        if let answer {
            if web != nil || structured {
                for event in syntheticEvents(for: answer) { await onEvent(event) }
            }
            return answer
        }
        if structured, output.isSuccess, let value = output.result?["structured_output"], !value.isNull,
           let last = tracker.completed.last {
            let message = Message(
                id: last.id, model: last.model, content: [.text(try value.serializedString())], stopReason: .endTurn,
                usage: tracker.usage, requestID: last.requestID ?? last.id)
            for event in syntheticEvents(for: message) { await onEvent(event) }
            return message
        }
        if let last = tracker.completed.last,
           [.refusal, .maxTokens, .modelContextWindowExceeded].contains(last.stopReason) {
            return last
        }
        let failure: any Error = output.isSuccess
            ? ClaudeError.claudeCode(structured ? "the answer had no structured output" : "the answer was empty")
            : output.failure(standardError: processResult.standardError, status: processResult.status)
        if tracker.completed.isEmpty {
            // Nothing reached the API (or the CLI refused before streaming): still one ledger row.
            await call.record(nil, error: String(describing: failure), startedAt: Date(), elapsed: .zero)
        }
        throw failure
    }

    /// The events of a message delivered at once (structured output: the JSON as one text block).
    static func syntheticEvents(for message: Message) -> [StreamEvent] {
        var shell = message
        shell.content = []
        shell.stopReason = nil
        var events: [StreamEvent] = [.messageStart(shell)]
        for (index, block) in message.content.enumerated() {
            if case .text(let text) = block {
                events.append(.contentBlockStart(index: index, block: .text("")))
                events.append(.contentBlockDelta(index: index, delta: .text(text.text)))
            } else {
                events.append(.contentBlockStart(index: index, block: block))
            }
            events.append(.contentBlockStop(index: index))
        }
        events.append(.messageDelta(
            delta: ["stop_reason": message.stopReason.map { .string($0.rawValue) } ?? .null],
            usage: message.usage.json))
        events.append(.messageStop)
        return events
    }

    // MARK: - Tool loop

    /// One tool-loop launch (docs/plan-m35.md §3.5). Throws `RunRelaunch` when the engine should
    /// launch again with another isolation variant or session flag.
    ///
    /// M5 (docs/plan-m5.md §5.1): `.webSearch` / `.webFetch` beside the custom tools become the
    /// CLI's own WebSearch / WebFetch (`--tools` names only those asked for, `--allowedTools` adds
    /// them after the MCP server); the init check then expects exactly the app's tools plus those
    /// built-ins. The CLI's tool_use / tool_result blocks of its web tools are appended like any
    /// other turn, and the run records one more ledger row for the web tools' own (unstreamed)
    /// calls. Domain filters cannot be expressed on the CLI: logged and ignored.
    static func toolLoop(
        _ call: ClaudeCodeCall, maxIterations: Int, prompt: [JSONValue], variant: IsolationVariant,
        session: SessionFlag, handler: @escaping ToolHandler,
        onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> ToolLoopResult {
        let request = call.request
        var tools: [CustomTool] = []
        var webTools: [Tool] = []
        for tool in request.tools {
            switch tool {
            case .custom(let custom): tools.append(custom)
            case .webSearch, .webFetch: webTools.append(tool)
            default:
                throw ClaudeError.invalidArgument("Claude Code tool loops take custom tools, web search and web fetch, not \(tool.name)")
            }
        }
        // The CLI's built-in tools this loop may use (nil: none).
        let web = try WebToolSet(webTools)
        let builtIns = web?.names ?? []
        let runStarted = Date()
        let runClock = ContinuousClock.now
        let matcher = ToolUseMatcher()
        let toolTurns = ClaudeCodeQueue()
        let server = MCPToolServer(tools: tools) { name, arguments in
            let id = await matcher.claim(name: ClaudeCodeCall.toolPrefix + name, input: arguments)
            let use = ToolUseBlock(id: id ?? "toolu_studyportal_\(UUID().uuidString.lowercased())", name: name, input: arguments)
            do {
                return try await toolTurns.run(.interactive) {
                    await onEvent(.toolStarted(use))
                    let output: ToolOutput
                    do {
                        // The run holds the engine's queue: a model call from the tool must not wait for it.
                        output = try await ClaudeCodeEngine.$insideToolCall.withValue(true) { try await handler(use) }
                    } catch is CancellationError {
                        output = .error("cancelled")
                    } catch {
                        output = .error(String(describing: error))
                    }
                    await onEvent(.toolFinished(use, output))
                    return output
                }
            } catch {
                return .error("cancelled")
            }
        }
        let (port, serverTask) = try await server.start()
        defer { serverTask.cancel() }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: call.configuration.workspace, withIntermediateDirectories: true)
        try fileManager.createDirectory(
            at: call.configuration.runs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configFile = call.configuration.runs.appending(path: "\(UUID().uuidString.lowercased()).json")
        guard fileManager.createFile(
            atPath: configFile.path, contents: try server.configuration(port: port).serialized(),
            attributes: [.posixPermissions: 0o600])
        else { throw ClaudeError.claudeCodeProcess("could not write the tool server's configuration") }
        defer { try? fileManager.removeItem(at: configFile) }

        let allowed = ["mcp__\(MCPToolServer.serverName)"] + builtIns
        let arguments = call.arguments(tools: builtIns.joined(separator: ",")) + variant.arguments + [
            "--mcp-config", configFile.path, "--strict-mcp-config", "--allowedTools", allowed.joined(separator: ","),
            "--permission-mode", "dontAsk", "--disable-slash-commands", "--max-turns", String(maxIterations),
        ] + session.arguments
        let spec = ChildProcessSpec(
            executable: call.binary, arguments: arguments,
            environment: call.environment(["MCP_CONNECTION_NONBLOCKING": "false"]),
            directory: call.configuration.workspace, input: try ClaudeCodeCall.inputLine(prompt))

        var tracker = MessageTracker()
        var output = CLIOutput()
        var appended: [MessageParam] = []
        var pendingResults: [ContentBlock] = []
        var stop: ToolLoopStop?
        var initChecked = false
        var isolationFailed = false

        func append(_ turn: MessageParam) async {
            appended.append(turn)
            await onEvent(.appended(turn))
        }
        func flushResults() async {
            guard !pendingResults.isEmpty else { return }
            let blocks = pendingResults
            pendingResults = []
            await append(.user(blocks))
        }

        let processResult: ChildProcessResult
        do {
            processResult = try await ChildProcess.run(spec) { line in
                guard let object = parse(line) else { return .proceed }
                output.observe(object)
                switch object.string("type") {
                case "system" where object.string("subtype") == "init":
                    guard !initChecked else { return .proceed }
                    initChecked = true
                    guard isolationHolds(object, variant: variant, builtIns: builtIns) else {
                        isolationFailed = true
                        return .stop
                    }
                    return .proceed
                case "stream_event":
                    guard initChecked else {
                        // No init event before the first model call: isolation is unverified.
                        isolationFailed = true
                        return .stop
                    }
                    if object["event"]?["type"]?.stringValue == "message_start" { await flushResults() }
                    let step = await tracker.apply(object) { partial, started, elapsed in
                        await call.record(partial, error: "interrupted", startedAt: started, elapsed: elapsed)
                    }
                    let iteration = tracker.iteration
                    switch step {
                    case .ignored:
                        return .proceed
                    case .event(let event):
                        await onEvent(.stream(iteration: iteration, event))
                        return .proceed
                    case .toolUseCompleted(let event, let use):
                        await onEvent(.stream(iteration: iteration, event))
                        await matcher.completed(use)
                        return .proceed
                    case .messageCompleted(let event, let message):
                        await onEvent(.stream(iteration: iteration, event))
                        let (started, elapsed) = tracker.takeSegment()
                        // The row first: TurnRecorder links the appended turn to it by request id.
                        await call.record(message, error: nil, startedAt: started, elapsed: elapsed)
                        switch message.stopReason {
                        case .refusal?:
                            stop = .refusal(message.stopDetails)
                            return .stop
                        case .maxTokens?, .modelContextWindowExceeded?:
                            stop = .truncated
                            return .stop
                        case .toolUse?, .pauseTurn?:
                            await append(.assistant(message))
                            stop = nil
                        case .endTurn?, .stopSequence?:
                            await append(.assistant(message))
                            stop = .endTurn
                        default:
                            await append(.assistant(message))
                            stop = .other(message.stopReason)
                        }
                        return .proceed
                    }
                case "user":
                    guard object["parent_tool_use_id"]?.isNull ?? true,
                          let content = object["message"]?["content"], let blocks = try? MessageContent(json: content).blocks,
                          blocks.contains(where: { $0.type == "tool_result" })
                    else { return .proceed }
                    // The CLI prints one line per result; like `ToolLoop`, one user turn holds
                    // them all (appended before the next API message or at the end).
                    pendingResults.append(contentsOf: blocks)
                    return .proceed
                default:
                    return .proceed
                }
            }
        } catch {
            if let (partial, started, elapsed) = tracker.openMessage {
                await call.record(partial, error: error is CancellationError ? "cancelled" : String(describing: error), startedAt: started, elapsed: elapsed)
            }
            // Results the CLI already printed are stored too (a Stop during a tool call).
            await flushResults()
            throw error
        }
        if let (partial, started, elapsed) = tracker.openMessage {
            await call.record(partial, error: "interrupted", startedAt: started, elapsed: elapsed)
        }
        await flushResults()
        output.logCost(recorded: tracker.completed, pricing: call.configuration.pricing)

        if isolationFailed {
            ClaudeClient.logger.notice("Claude Code isolation \(variant.rawValue, privacy: .public) failed its init check")
            throw RunRelaunch.isolation
        }
        if web != nil {
            // WebSearch / WebFetch make their own API calls inside the CLI (not streamed): one
            // more ledger row for the run, priced from `modelUsage`, as one-shot web runs do.
            await call.recordUnstreamedCost(
                result: output.result, streamed: tracker.completed, startedAt: runStarted, elapsed: ContinuousClock.now - runClock)
        }
        if tracker.completed.isEmpty {
            let texts = output.failureTexts(standardError: processResult.standardError)
            if texts.contains(where: { $0.contains("already in use") }) { throw RunRelaunch.sessionInUse }
            if texts.contains(where: { $0.contains("No conversation found") }) { throw RunRelaunch.sessionNotFound }
        }
        func result(_ stop: ToolLoopStop, final: Message) -> ToolLoopResult {
            ToolLoopResult(
                messages: request.messages + appended, appended: appended, finalMessage: final, stop: stop,
                iterations: tracker.completed.count, usage: tracker.usage)
        }
        if let last = tracker.completed.last {
            switch stop {
            case .refusal?, .truncated?, .endTurn?:
                // Final either way: the CLI was stopped, or the answer is complete.
                return result(stop ?? .endTurn, final: last)
            default:
                break
            }
            if output.result?.string("subtype") == "error_max_turns" { return result(.iterationLimit, final: last) }
            if output.isSuccess { return result(stop ?? .other(last.stopReason), final: last) }
        }
        let failure = output.failure(standardError: processResult.standardError, status: processResult.status)
        if tracker.completed.isEmpty {
            await call.record(nil, error: String(describing: failure), startedAt: Date(), elapsed: .zero)
        }
        throw failure
    }

    /// The `system/init` check: the app's server connected and no other server connected; the
    /// tools exactly the app's own (`mcp__studyportal__*`) plus the built-ins the loop asked for
    /// (M5: WebSearch / WebFetch), each of those present.
    static func isolationHolds(_ initLine: JSONObject, variant: IsolationVariant, builtIns: [String] = []) -> Bool {
        let servers = initLine.array("mcp_servers") ?? []
        func isConnected(_ server: JSONValue) -> Bool { server["status"]?.stringValue == "connected" }
        let connected = servers.contains { $0["name"]?.stringValue == MCPToolServer.serverName && isConnected($0) }
        let otherServers = servers.filter { $0["name"]?.stringValue != MCPToolServer.serverName && isConnected($0) }
        let listed = (initLine.array("tools") ?? []).compactMap(\.stringValue)
        let foreign = listed.filter { !$0.hasPrefix(ClaudeCodeCall.toolPrefix) && !builtIns.contains($0) }
        let missing = builtIns.filter { !listed.contains($0) }
        let holds = connected && otherServers.isEmpty && foreign.isEmpty && missing.isEmpty
        if !holds {
            let statuses = servers.map { "\($0["name"]?.stringValue ?? "?")=\($0["status"]?.stringValue ?? "?")" }
            ClaudeClient.logger.notice(
                "Claude Code init (\(variant.rawValue, privacy: .public)): servers \(statuses.joined(separator: ","), privacy: .public), other tools \(foreign.joined(separator: ","), privacy: .public), missing \(missing.joined(separator: ","), privacy: .public)"
            )
        }
        return holds
    }
}

/// Pairs the CLI's `tools/call` requests with the `tool_use` blocks it streamed: same name
/// (`mcp__studyportal__<name>`) and equal input, in order. A call that arrives before its block
/// has streamed waits briefly; failing an exact match, the first block of that name is used.
actor ToolUseMatcher {
    private struct Waiter {
        let id: UInt64
        let name: String
        let input: JSONValue
        let continuation: CheckedContinuation<String?, Never>
    }

    private var available: [ToolUseBlock] = []
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0

    func completed(_ use: ToolUseBlock) {
        if let index = waiters.firstIndex(where: { $0.name == use.name && $0.input == use.input }) {
            waiters.remove(at: index).continuation.resume(returning: use.id)
        } else {
            available.append(use)
        }
    }

    /// The CLI tool_use id for a call (prefixed name), or nil when none streamed.
    func claim(name: String, input: JSONValue, wait: Duration = .seconds(3)) async -> String? {
        if let index = available.firstIndex(where: { $0.name == name && $0.input == input }) {
            return available.remove(at: index).id
        }
        let id = nextID
        nextID += 1
        let timer = Task.detached { [self] in
            try? await Task.sleep(for: wait)
            await self.expire(id)
        }
        let matched: String? = await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: id, name: name, input: input, continuation: continuation))
        }
        timer.cancel()
        if let matched { return matched }
        if let index = available.firstIndex(where: { $0.name == name }) {
            return available.remove(at: index).id
        }
        ClaudeClient.logger.notice("Claude Code tool call without a streamed tool_use: \(name, privacy: .public)")
        return nil
    }

    private func expire(_ id: UInt64) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: nil)
    }
}
#endif
