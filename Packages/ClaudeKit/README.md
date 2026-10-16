# ClaudeKit

Hand-written Swift client for the Anthropic Messages API (`POST /v1/messages`). No dependencies; the app wires it to StudyCore.

## Use

App-side wiring (ClaudeKit does not import StudyCore):

```swift
import ClaudeKit
import StudyCore

struct APICallLedger: CostLedger {
    let repository: APICallRepository
    func record(_ call: CallRecord) async throws {
        try await repository.log(APICall(
            model: call.model.rawValue, purpose: call.purpose, requestID: call.requestID, lectureID: call.lectureID,
            inputTokens: call.usage.inputTokens, outputTokens: call.usage.outputTokens,
            cacheReadTokens: call.usage.cacheReadInputTokens, cacheWriteTokens: call.cacheWriteTokens,
            costUSD: call.costUSD ?? 0, durationMs: call.durationMilliseconds,
            stopReason: call.stopReason?.rawValue, error: call.error, createdAt: call.startedAt))
    }
}
```

```swift
let client = ClaudeClient(
    keyProvider: ClosureAPIKeyProvider { try services.secrets.secret(for: .anthropicAPIKey) },
    ledger: APICallLedger(repository: APICallRepository(store: services.records)))

// Streaming (use for anything long). onEvent runs off the main actor.
let request = MessageRequest(
    model: .opus55, maxTokens: 64_000, effort: .medium,
    messages: [.user([.pdf(slidesData, title: "Slides"), .text("…")])],
    system: MessageRequest.systemPrompt(coursePrompt, cacheControl: .ephemeral),
    thinking: .summarized)
let message = try await client.streamMessage(request, context: CallContext(purpose: "summary", lectureID: id)) { event in … }
try message.requireComplete()          // throws .refused / .truncated
let text = message.text

// Structured output
let routing = try await client.structured(Routing.self, haikuRequest)   // request.outputFormat = .jsonSchema(…)

// Tool loop (append-only; tools and system prompt fixed for the whole loop)
let result = try await ToolLoop(client: client).run(request, handler: { call in … return .json(…) })
// persist result.messages; result.stop tells why it ended
```

## Backends (M3.5)

Since M3.5 the app's client runs on the student's Claude Code CLI, not the API: `ClaudeClient(backend: ClaudeCodeEngine(configuration:), ledger:)` (built by `ClaudeClient.socrates(services:)` in MailIntelligence). With a backend, `streamMessage`, `send`, `structured` and `ToolLoop.run` go to it; callers do not change. Gate model work on `client.isAvailable()`. `CallContext.priority` orders the backend's queue, `CallContext.session` continues a conversation's CLI session, `CallRecord.billing` marks notional cost. The contract is in `Backend.swift`.

## Claude Code backend (`ClaudeCode/`, macOS only)

`ClaudeCodeEngine` runs every call through `claude -p` on the student's subscription (verified against CLI 2.1.268). Never `--bare` (it ignores the subscription login and needs `ANTHROPIC_API_KEY`), never `--dangerously-skip-permissions`. All `Process`/Network code is under `#if os(macOS)`; iOS uses `UnavailableClaudeBackend`.

| File | Role |
|---|---|
| `ClaudeCodeEngine.swift` | `ClaudeCodeConfiguration`; the actor: availability, queue + usage pause (`scheduled`), isolation and session relaunches |
| `ClaudeCodeRun.swift` | one launch: flags, stdin prompt, stdout stream-json → events, messages, ledger rows, stop |
| `ChildProcess.swift` | `Process` + pipes, stdout split on `\n`, exit via `terminationHandler`, cancellation = SIGTERM then SIGKILL after 2 s |
| `ClaudeCodeQueue.swift` | one holder at a time, interactive before background, FIFO within, cancelled waiters leave |
| `MCPToolServer.swift` | the per-run MCP server (Network `NetworkListener`, HTTP/1.1, JSON-RPC) |
| `ClaudeCodeState.swift` | `state.json`, reading "resets 5:20pm (Europe/Lisbon)" |

### Availability (no model call)
The binary is the first executable of `configuration.candidates` (`~/.local/bin/claude`, `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`), else (once per engine) the last absolute line of `/bin/zsh -lc 'command -v claude'`; none → `.notInstalled`. `claude auth status --json` (≈0.2 s) → `loggedIn` true, else (or on failure) `.signedOut`; `claude --version` ("2.1.268 (Claude Code)") and `subscriptionType` fill `ClaudeBackendStatus`, whose `pausedUntil` is the usage pause while it holds. Answers are cached for `availabilityLifetime` (60 s), concurrent checks share one probe, `refreshAvailability()` and any CLI failure drop the cache. Probes do not wait in the queue.

Child environment, complete: `HOME`, `USER`, `LOGNAME`, `PATH` (the binary's folder + system folders), `LANG`, `TMPDIR`, plus `CLAUDE_CODE_MAX_OUTPUT_TOKENS` (calls) and `MCP_CONNECTION_NONBLOCKING=false` (tool loops). Nothing else from the app's environment, so never `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_*` or `CLAUDECODE`. cwd is the empty `Agent/Workspace/`.

### One-shot calls (`streamMessage`, `send`, `structured`)
```
claude -p --tools "" --input-format stream-json --output-format stream-json --verbose --include-partial-messages
       --model <request.model> --effort <request.effort> --system-prompt <system blocks joined by blank lines>
       --safe-mode --no-session-persistence [--json-schema <outputFormat.schema>]
env CLAUDE_CODE_MAX_OUTPUT_TOKENS=<maxTokens>
stdin {"type":"user","message":{"role":"user","content":[blocks]},"parent_tool_use_id":null,"session_id":""}⏎ EOF
```

| Request | Sent as |
|---|---|
| `model`, `effort` | `--model`, `--effort` (always explicit) |
| `system` | `--system-prompt`, blocks joined with blank lines; an empty system becomes one neutral line (an empty flag would bring back the CLI's coding-agent prompt) |
| `maxTokens` | `CLAUDE_CODE_MAX_OUTPUT_TOKENS` |
| `outputFormat` | `--json-schema` |
| `messages` | exactly one user turn (text, image, document blocks) on stdin; more turns or a custom tool → `ClaudeError.invalidArgument` (use `ToolLoop`); `.webSearch` / `.webFetch` → the CLI's own web tools (below) |
| not sent | `cache_control`, `fallbacks`, betas, `extraBody`, `tool_choice` (never forced), `stop_sequences`, `thinking` (the CLI's adaptive thinking; never disabled) |

Response: every stdout line is JSON. `stream_event.event` is a raw Messages API event → `StreamEvent(json:requestID:)` with the request id = the message id from `message_start` → `onEvent` and `MessageAccumulator` → the returned `Message` (`requestID` = message id). A first message that stops on `max_tokens` or `refusal` is returned as is and the CLI is stopped, so it cannot continue on its own. With `--json-schema` the CLI may make a second API call (its structured-output tool round): every call is a ledger row, `onEvent` sees synthetic events of the final message, and that message is one text block of `result.structured_output` serialized with sorted keys (`decodeJSON` works), `requestID` = the last API message's id, `usage` summed. Unknown line types are ignored; `result` (`subtype`, `is_error`, `result`, `structured_output`, `total_cost_usd`, `num_turns`), `rate_limit_event` and the CLI's own error turns (`assistant` lines with `error` / model `<synthetic>`) are read for errors.

Errors: a usage limit → see below; "/login" or "not logged in" → `ClaudeError.unavailable(.signedOut)`; text naming an overload/529, a 5xx or a connection failure → `.overloaded`/`.server`/`.transport` (retryable, so `isServiceTrouble` keeps the work pending); a run without a `result` line (the process could not start, crashed, was killed, or rejected a flag after a CLI update) or a tool server that cannot listen → `.claudeCodeProcess` (service trouble: the work waits, no attempt counted); M5: a result `error_max_turns` without an answer → `.turnLimit` (about the request: neither retryable nor service trouble; StudyPass counts a research run as done without sources; a tool loop that streamed a message reports `.iterationLimit` instead); anything else → `.claudeCode(<the CLI's message, ≤ 300 chars>)`. A successful result's text is the answer and never goes into an error.

### Web tools in one-shot calls (M4, the study pass's research runs)
`streamMessage` accepts `.webSearch` / `.webFetch` in `request.tools` (anything else still throws `invalidArgument`; custom tools need `ToolLoop`). The CLI then runs its own WebSearch/WebFetch and no other tool:
```
claude -p --tools WebSearch,WebFetch <the other shared flags> <isolation: --safe-mode | --setting-sources "">
       --strict-mcp-config --allowedTools WebSearch,WebFetch --permission-mode dontAsk --disable-slash-commands
       --max-turns <largest maxUses of the tools, else 8> --no-session-persistence [--json-schema <schema>]
```
- Only the tools asked for are named (`--tools` and `--allowedTools`). `maxUses` becomes the run's `--max-turns` (the CLI has no per-tool limit). `allowedDomains` / `blockedDomains` cannot be expressed on the CLI: they are ignored and logged (notice).
- **Isolation**: the `system/init` line must list exactly those tools (plus `StructuredOutput`, the CLI's structured-output tool, when `--json-schema` is set) and no MCP server; else the child is killed before the first model call and relaunched with the other variant: `--safe-mode` first (it turns MCP servers, plugins and hooks off), then `--setting-sources ""`. The variant that passed is kept per CLI version in `state.json` (`webIsolation`, optional, so older files still read); both failing → `.claudeCode` (counts as an attempt, not service trouble). A stream event before `system/init` also fails the check.
- **Answer**: messages that stop on `tool_use` / `pause_turn` let the CLI go on; the answer is the first message that stops otherwise (`max_tokens` / `refusal` stop the CLI as before), or with `outputFormat` the result's `structured_output` (as for plain one-shots). `onEvent` sees only the answer's events, synthetic, at the end.
- **Ledger**: one `CallRecord` per streamed API call of the run, plus one more for the calls the CLI's tools make inside the run (WebSearch and WebFetch run on another model, Haiku 4.5 in CLI 2.1.268, and are not streamed): the result's `modelUsage` `costUSD` of the models the run did not stream (`total_cost_usd` minus the streamed calls only when `modelUsage` is missing: the CLI misprices models it does not know yet), no tokens, no request id, recorded when it is at least $0.002.
- Live check (2026-10-18, CLI 2.1.268): `--safe-mode` passed first; the init listed `StructuredOutput, WebFetch, WebSearch` and no MCP server; `--strict-mcp-config` without `--mcp-config` is accepted; the tools' own calls appear in `modelUsage` as `claude-haiku-4-5-…` and are the extra ledger row. A CLI too old for the model ("version 2.1.280 or newer is required. Run 'claude update'") is `claudeCodeProcess` (service trouble: the work waits).

### Tool loops (`ToolLoop.run` → `runToolLoop`)
The request's custom tools are served by an MCP server (M5: `.webSearch` / `.webFetch` may sit beside them, see "Web tools in tool loops"; any other tool → `invalidArgument`). The MCP server is the app hosts for the run: `NetworkListener` on 127.0.0.1, port 0, a random 32-byte hex bearer token, streamable HTTP at `POST /mcp` with JSON responses: `initialize` (echoes 2025-11-25/2025-06-18/2025-03-26/2024-11-05, else the newest; `capabilities.tools`, `serverInfo.name` "studyportal"), notifications → 202, `tools/list` (name, description, inputSchema), `tools/call`, `ping`; anything else (incl. the 2026-07-28 `server/discover` probe) → JSON-RPC "Method not found", which makes the CLI fall back to `initialize`. Wrong or missing token → 401, GET/DELETE → 405, other paths → 404. Its config `{"mcpServers":{"studyportal":{"type":"http","url":…,"headers":{"Authorization":"Bearer …"},"alwaysLoad":true}}}` is written to `Agent/Runs/<uuid>.json` (0600, folder 0700), deleted after the run and at engine start. `alwaysLoad` keeps the tools in the first request (never deferred behind tool search).
```
claude -p <one-shot flags without --safe-mode --no-session-persistence --json-schema>
       <isolation: --setting-sources "" | --safe-mode>
       --mcp-config Agent/Runs/<uuid>.json --strict-mcp-config --allowedTools mcp__studyportal
       --permission-mode dontAsk --disable-slash-commands --max-turns <maxIterations>
       <--session-id <id> | --resume <id> | --no-session-persistence>
```
- **Session**: `CallContext.session` (the conversation id): `resumes` false → `--session-id`, true → `--resume`; the CLI's "already in use" swaps to `--resume`, "No conversation found" to `--session-id`, once. No session → `--no-session-persistence`. The prompt on stdin is the text/image/document blocks of every user turn after the last assistant turn, merged into one message (`tool_result` blocks dropped: the CLI session owns tool state), so a turn whose run failed before the CLI started is not lost; after "already in use" only the newest turn (the session holds the others); after "No conversation found" (the CLI prunes sessions older than its `cleanupPeriodDays`) the stored history goes first as one `<conversation>` text block (the student's words, the text answers, the latest context envelope).
- **Isolation**: the first line, `system/init`, must list `studyportal` with status `connected`, no other server connected (M5), and no tool outside `mcp__studyportal__*` (plus the built-ins a web loop asked for, each of them listed), else the child is killed at once (before the model answers) and relaunched with the other variant: `--setting-sources ""` first, then `--safe-mode`. The variant that passed is kept per CLI version in `state.json`; both failing → `.claudeCode`. (A first-run session killed by a failed check already holds the prompt; the relaunch resumes it, the CLI adds "Continue from where you left off." and a synthetic empty answer, and the prompt goes again. At most once per CLI version.) Live check 2026-10-17, CLI 2.1.268: `--safe-mode` failed the check (it also turns off `--mcp-config` servers), `--setting-sources ""` passed with `studyportal` connected and no CLAUDE.md in the context; hence that order.
- **Tool calls**: `tools/call` runs `handler` with a `ToolUseBlock` whose name is the bare name and whose id is the CLI's matching `tool_use` (name `mcp__studyportal__<name>` and equal input, in stream order; a call that arrives first waits ≤ 3 s, then the first of that name, else a synthetic id). Calls run one at a time (as `ToolLoop` with `parallelToolExecution: false`), with `.toolStarted`/`.toolFinished` around them; thrown errors become `is_error` results. A model call made from inside a tool handler bypasses the queue (task-local), since the loop holds it. Live check (2.1.268): the stream events reached the app only after its `tools/call` had waited 3 s, so the handler got a synthetic id. The cause was the app's reading, not the CLI: `FileHandle.bytes` serializes every handle's reads, so the stderr reader blocked stdout until stderr spoke or closed. Each pipe now has its own readability handler (`ChildProcess`).
- **Events**: `.stream(iteration, event)` per API call (iteration = API calls so far); per completed API message the ledger row is awaited first, then `.appended(.assistant(message))` (thinking and signatures verbatim; the CLI's own `assistant` lines are not appended again; its `tool_use` names keep the `mcp__studyportal__` prefix, `ClaudeCodeConfiguration.toolNamePrefix`). The CLI prints one `user` line per tool result; they are appended as one `.appended(.user(blocks))` (verbatim) before the next API message, or at the end. Subagent lines (`parent_tool_use_id` set) are ignored.
- **Stop**: `end_turn`/`stop_sequence` → `.endTurn`; `refusal` → `.refusal` (not appended, CLI stopped); `max_tokens`/context window → `.truncated` (not appended, CLI stopped); `result.subtype == "error_max_turns"` → `.iterationLimit`; another stop reason on a successful result → `.other`; failures throw as for one-shot calls. `ToolLoopResult`: `messages` = request + appended, `iterations` = API calls, `usage` summed.

### Web tools in tool loops (M5, the tutor)
`runToolLoop` takes `.webSearch` / `.webFetch` beside the custom tools (Agent's `ToolSet` keeps them away from mail and write tools). The CLI runs its own WebSearch / WebFetch next to the app's MCP tools:
```
claude -p --tools WebSearch,WebFetch <the other shared flags> <isolation>
       --mcp-config Agent/Runs/<uuid>.json --strict-mcp-config --allowedTools mcp__studyportal,WebSearch,WebFetch
       --permission-mode dontAsk --disable-slash-commands --max-turns <maxIterations> <session flag>
```
- `--tools` and `--allowedTools` name only the built-ins asked for (`WebToolSet.names`; without web tools `--tools ""` as before). The tools' `maxUses` is not used here (the loop's `--max-turns` is `maxIterations`); `allowedDomains` / `blockedDomains` are logged (notice) and ignored, as for one-shots.
- **Init check**: `studyportal` connected, no other server connected, the tools exactly `mcp__studyportal__*` plus those built-ins (each listed). Anything else kills the child before the first model call and relaunches with the next isolation variant, as above.
- **Turns**: the CLI's `tool_use` blocks for WebSearch / WebFetch (bare names, no prefix) and its `user` lines with their `tool_result`s are appended like the MCP tools' (`.appended`), so a conversation's stored turns hold the pages the answer read (ChatUI checks web citations against them). No `.toolStarted` / `.toolFinished` for them (the app does not run them).
- **Ledger**: one `CallRecord` per streamed API call, plus one row per run for the web tools' own unstreamed calls (`recordUnstreamedCost`: the result's `modelUsage` `costUSD` of the models the run did not stream, at least $0.002), as for one-shot web runs.
- The HTTP `ToolLoop` path is unchanged (it sends the server tools to the API as before).

### Queue and priorities
ma (supersedes "one process at a time"): `ClaudeCodeSlots` holds the `claude` processes (about 0.5 GB each) in slots per `CallContext.priority`: ONE `.interactive` slot (the agent panel, drafts, the composer) and `ClaudeCodeConfiguration.backgroundSlots` `.background` slots (default 2: pipelines, triage, sub-agent tasks). An interactive call never waits behind background holders (its slot is its own); FIFO within a priority; a cancelled waiter leaves the queue. So at most 3 processes. `ClaudeClient.setBackgroundSlotLimit(_:)` (→ `ClaudeBackend.setBackgroundSlotLimit`, `ClaudeCodeEngine.setBackgroundSlotLimit`) lowers the background slots at run time (the app passes 1 while `memory_pressure` reports < 25 % free, nil to go back); never below 1, running calls are not stopped. The usage pause is unchanged (every call throws `.usageLimited` at once while it holds). A model call made from inside a tool handler still bypasses the slots (task-local `insideToolCall`). `ClaudeCodeQueue` stays the per-run queue of MCP tool calls (one at a time). Cancelling the caller kills the child (SIGTERM, SIGKILL after 2 s) and records the open API message as failed with its partial usage.

### Usage limits and `state.json`
A `rate_limit_event` with `status: "rejected"` (its `resetsAt`, epoch seconds) or a failure text like "You've hit your session limit · resets 5:20pm (Europe/Lisbon)" (the next such time in that zone; "Oct 20, 5pm" and a trailing `|<epoch>` are read too; unknown → now + 1 h) pauses the engine: `pausedUntil` goes to `Agent/state.json` (read at launch) and into the availability status. While it holds, every call throws `ClaudeError.usageLimited(resetsAt:)` at once (service trouble): background pipelines check `availability().pausedUntil` before model work, leave it pending, go on with what needs no model (rules, indexing) and wake themselves at the reset. The call that hit the limit is not rerun. `state.json` also keeps `isolation` (variant per CLI version).

### Ledger
One `CallRecord` per API call: `requestID` = the message id, `model` from `message_start`, usage from `message_start` + `message_delta`, `costUSD` from `configuration.pricing` (notional), `billing: .subscription`, `streamed: true`, `attempts: 1`, purpose and lecture from `CallContext`. An interrupted message is recorded with its partial usage and the error; a run that failed before any API message still leaves one row (zero usage, the error). The CLI's `total_cost_usd` is logged at `.debug` beside the recorded sum. Logs use category "claude"; prompts, mail and tool content are never logged `.public` (stderr only `.private`).

### Requests for the integrator
M5 (web tools in tool loops, not checked live: no model calls while building): the integrator's live check (plan-m5 §7.5) should confirm for the tutor's run which isolation variant passed with `--tools WebSearch,WebFetch` beside `--mcp-config` (the variant kept in `state.json` is per CLI version and shared with the mail chat), that the init line lists `mcp__studyportal__*`, `WebSearch` and `WebFetch` and only `studyportal` as a connected server, that the web tools' `tool_use` / `tool_result` turns are stored, and the extra ledger row for the web tools (`modelUsage`). If the init line also lists a tool the CLI adds on its own beside the built-ins asked for, `ClaudeCodeRun.isolationHolds` is the place to allow it. Design notes (decisions row) are in the Search README ("M5 design notes").

Done in the M3.5 integration (docs/decisions.md, 2026-10-17): the live check passed with `--setting-sources ""` (now tried first), `studyportal` connected, the tool ran, `--resume` continued, `billing = subscription` with message ids; quitting the app calls `ClaudeCodeEngine.terminateRunningProcesses()`. The original list:
- The live check (plan-m35 §5.6) should confirm, and note in decisions: which isolation variant passed (`Agent/state.json` → `isolation`), that `studyportal` connected with `alwaysLoad`, that `--max-turns` (hidden in `--help`, present in 2.1.268) and `--json-schema` under `--tools ""` behave as described, and the `api_call` rows (`billing = subscription`, request ids linked by TurnRecorder). Also that the loopback listener raises no firewall prompt for the signed app.
- Settings ▸ Accounts can show `ClaudeBackendStatus.pausedUntil` from `client.availability()`; the CLI's subscription string is `subscription`.
- Nothing for `project.yml`: Network is a system framework.

## Shape of the API

| Type | Role |
|---|---|
| `ClaudeClient` | `send` (non-streaming, ≤ 16 384 `max_tokens`), `streamMessage` (SSE, returns the accumulated `Message`), `events` (AsyncSequence), `structured` |
| `MessageRequest` | model, `max_tokens`, required `effort`, messages, system blocks, tools, `tool_choice` (`auto`/`none` only), adaptive `thinking` (display omitted/summarized/updates), `output_config.format`, `cache_control`, `fallbacks`, betas, `extraBody` |
| `ContentBlock` | text, image, document (base64 PDF/text/url/file), tool_use, tool_result, thinking, redacted_thinking, server_tool_use, `.other` (any other block, verbatim) |
| `Message` / `MessageParam` | response / request turn; `MessageParam.assistant(message)` gives the turn to append |
| `SSEParser`, `StreamEvent`, `MessageAccumulator` | byte-level SSE parsing, typed events, accumulation |
| `ClaudeError` | typed errors (`rateLimited(retryAfter:)`, `overloaded`, `server`, `invalidRequest`, `authentication`, …, `refused(stopDetails)`, `truncated`) |
| `RetryPolicy` | 408/409/429/5xx/529 + connection errors, exponential backoff with jitter, `retry-after`, `x-should-retry` |
| `PricingTable`, `CostLedger`, `CallRecord` | per-call usage and USD cost, reported once per logical call |
| `ToolLoop` | send → run client tools (parallel) → one user message of `tool_result`s → repeat |

## Decisions

| Decision | Why |
|---|---|
| No StudyCore dependency; the app adapts `SecretStore` → `APIKeyProvider` and `APICallRepository` → `CostLedger` | keeps the client testable alone and free of the database; StudyCore stays the only schema owner |
| Wire models are built on a `JSONValue` tree, encoded with sorted keys | unknown fields and block types round-trip unchanged, and the same conversation always encodes to the same bytes (prompt cache, preserved thinking) |
| Requests cannot express `temperature`/`top_p`/`top_k`, disabled or budgeted thinking, or forced `tool_choice` | all return 400 on Opus 5.5; `effort` is a required field so it is always explicit (API default is `medium`) |
| Refusal fallback `fallbacks: "default"` (beta `server-side-fallback-2026-07-01`) on by default for Opus 5.5 and Sonnet 5.5 (`ClaudeConfiguration.refusalFallback`, `.disabled` per request) | a classifier false positive becomes a fallback answer instead of an outage; the cost is recorded at the serving model's price (Opus 5 / 4.8 at $5/$25) |
| Custom tools default to `strict: true`, `eager_input_streaming` off | inputs are small in this app; strict keeps schema-valid inputs. If eager streaming is turned on, unparseable input is flagged (`invalidInputJSON`) and the tool loop answers `is_error` without running the tool |
| Non-streaming calls above 16 384 `max_tokens` throw `.streamingRequired`; stream idle timeout 180 s, non-streaming 600 s; ephemeral `URLSession` with no cache | long calls must stream; responses never hit a disk cache |
| Streaming retries only before the first content event reaches the consumer | after that the consumer has seen partial output; the error is thrown instead |
| One `CallRecord` per logical call (retries folded in, `attempts` counted), failures included with partial usage | "log every call's usage + cost"; a ledger error is logged and never fails the call |
| Tool loop: refused or `max_tokens`-truncated turns are not appended; tools of a truncated turn never run; after a mid-output refusal fallback the appended turn drops pre-boundary thinking/tool blocks as the API requires | append-only history that the caller can always continue or retry |
| Haiku 5.5 price tier chosen by total prompt tokens (input + cache reads + cache writes) | the 100K threshold is on prompt length |

