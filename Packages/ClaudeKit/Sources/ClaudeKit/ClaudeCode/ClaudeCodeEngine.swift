import Foundation

// M3.5 (docs/plan-m35.md §3, workstream A): the Claude Code backend. Contract landed on main; the
// engine's body is A's work. Until then it reports `.notInstalled`, so the app behaves as it did
// without an API key (rules routing, no model calls, no chat entry point).

/// Settings of the Claude Code backend.
public struct ClaudeCodeConfiguration: Sendable, Hashable {
    /// The app's folder for the backend (`AppPaths.agent`):
    /// - `Workspace/`: the CLI's working directory, always empty (the CLI keeps the sessions of
    ///   agent conversations under `~/.claude/projects/<this path>`);
    /// - `state.json`: the usage pause (`pausedUntil`) and the launch flags that worked, so a
    ///   relaunch keeps pausing until the reset;
    /// - `Runs/`: one MCP config per tool-loop run (0600, holds that run's bearer token; deleted
    ///   when the run ends).
    public var directory: URL
    /// Where `claude` is looked for, in order, before the login shell's `PATH`.
    public var candidates: [URL]
    /// List prices for each call's notional cost (`Billing.subscription`).
    public var pricing: PricingTable
    /// How long an availability answer is reused before `claude auth status` runs again.
    public var availabilityLifetime: Duration

    public init(
        directory: URL,
        candidates: [URL] = ClaudeCodeConfiguration.defaultCandidates,
        pricing: PricingTable = .standard,
        availabilityLifetime: Duration = .seconds(60)
    ) {
        self.directory = directory
        self.candidates = candidates
        self.pricing = pricing
        self.availabilityLifetime = availabilityLifetime
    }

    /// `~/.local/bin/claude` (the native installer), `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`.
    public static var defaultCandidates: [URL] {
        [
            URL.homeDirectory.appending(path: ".local/bin/claude"),
            URL(filePath: "/opt/homebrew/bin/claude"),
            URL(filePath: "/usr/local/bin/claude"),
        ]
    }

    public var workspace: URL { directory.appending(path: "Workspace", directoryHint: .isDirectory) }
    public var stateFile: URL { directory.appending(path: "state.json") }
    public var runs: URL { directory.appending(path: "Runs", directoryHint: .isDirectory) }
}

#if os(macOS)
/// Runs Claude calls through the student's Claude Code CLI (`claude -p`, their subscription;
/// never `--bare`, which needs an API key).
///
/// What A implements behind this surface (docs/plan-m35.md §3):
/// - locating the binary (`configuration.candidates`, then the login shell's `PATH`) and
///   "installed + signed in" from `claude auth status --json` (`loggedIn`), no model call;
/// - one `claude` process at a time: an actor queue, interactive calls before background ones;
/// - one-shot calls (`--safe-mode --no-session-persistence --tools ""`, `--json-schema` for
///   `outputFormat`), streamed (`--output-format stream-json --verbose --include-partial-messages`),
///   the prompt on stdin (`--input-format stream-json`), `--model`, `--effort`, `--system-prompt`;
/// - tool loops: the request's custom tools served by an MCP server the app hosts for the run
///   (127.0.0.1, random port, random bearer token, streamable HTTP JSON-RPC), passed with
///   `--mcp-config <Runs/file> --strict-mcp-config --allowedTools mcp__studyportal
///   --permission-mode dontAsk --tools ""`; the conversation's CLI session started with
///   `--session-id` and continued with `--resume` (`CallContext.session`), cwd `Workspace/`;
/// - usage limits pause the queue until the stated reset (persisted in `state.json`);
/// - cancellation kills the child; `Process` and pipes with structured concurrency only;
/// - every call reported to the ledger with `billing: .subscription` (notional cost).
public actor ClaudeCodeEngine: ClaudeBackend {
    public nonisolated let configuration: ClaudeCodeConfiguration

    public init(configuration: ClaudeCodeConfiguration) {
        self.configuration = configuration
    }

    public nonisolated var kind: ClaudeBackendKind { .claudeCode }

    public func availability() async -> ClaudeAvailability {
        .notInstalled
    }

    public func refreshAvailability() async -> ClaudeAvailability {
        await availability()
    }

    public func streamMessage(
        _ request: MessageRequest, context: CallContext, ledger: any CostLedger,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void
    ) async throws -> Message {
        throw ClaudeError.unavailable(await availability())
    }

    public func runToolLoop(
        _ request: MessageRequest, context: CallContext, maxIterations: Int, ledger: any CostLedger,
        handler: @escaping ToolHandler, onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> ToolLoopResult {
        throw ClaudeError.unavailable(await availability())
    }
}
#endif
