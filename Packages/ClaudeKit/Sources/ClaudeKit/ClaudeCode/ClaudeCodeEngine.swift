import Foundation

// M3.5 (docs/plan-m35.md §3, workstream A): the Claude Code backend. Flags, mappings, isolation,
// the MCP tool server, the queue and the usage pause are documented in Packages/ClaudeKit/README.md.

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

    /// The names the CLI gives the request's custom tools (`mcp__studyportal__search_mail`). The
    /// `tool_use` blocks of appended assistant turns carry them verbatim; `handler`,
    /// `.toolStarted` and `.toolFinished` see the bare name.
    public static let toolNamePrefix = "mcp__studyportal__"

    public var workspace: URL { directory.appending(path: "Workspace", directoryHint: .isDirectory) }
    public var stateFile: URL { directory.appending(path: "state.json") }
    public var runs: URL { directory.appending(path: "Runs", directoryHint: .isDirectory) }
}

#if os(macOS)
/// Runs Claude calls through the student's Claude Code CLI (`claude -p`, their subscription).
/// Never `--bare` (it ignores the subscription login and needs an API key), never
/// `--dangerously-skip-permissions`.
///
/// - Availability: the binary (`configuration.candidates`, then once the login shell's `PATH`)
///   and `claude auth status --json` (`loggedIn`), cached for `availabilityLifetime`; no model
///   call.
/// - One `claude` process at a time (`ClaudeCodeQueue`): interactive calls first, FIFO within a
///   priority.
/// - `streamMessage`: one-shot calls; `runToolLoop`: tool loops whose tools the CLI calls through
///   an MCP server the app hosts for the run.
/// - A usage limit pauses the queue until the stated reset (kept in `state.json`): every call
///   throws `ClaudeError.usageLimited` at once meanwhile (service trouble: background work stays
///   pending and its pipeline wakes itself at the reset).
/// - Every API call is one `CallRecord` (`billing: .subscription`, notional cost).
/// - Cancelling the caller kills the child process.
public actor ClaudeCodeEngine: ClaudeBackend {
    public nonisolated let configuration: ClaudeCodeConfiguration
    private let queue = ClaudeCodeQueue()
    private var state: ClaudeCodeState
    private var cached: (availability: ClaudeAvailability, binary: URL?, expires: ContinuousClock.Instant)?
    private var probing: Task<(ClaudeAvailability, URL?), Never>?
    private var shellBinary: URL?
    private var searchedShell = false

    public init(configuration: ClaudeCodeConfiguration) {
        self.configuration = configuration
        state = ClaudeCodeState.load(from: configuration.stateFile)
        // MCP configs left by runs the app did not finish (each holds that run's bearer token).
        let fileManager = FileManager.default
        for file in (try? fileManager.contentsOfDirectory(at: configuration.runs, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: file)
        }
    }

    public nonisolated var kind: ClaudeBackendKind { .claudeCode }

    /// Ends every `claude` process the app started (SIGTERM), for the app's quit
    /// (`NSApplication.willTerminateNotification`): a tool loop's MCP server lives in the app and
    /// stops with it, so a child left running could not finish its run.
    public static func terminateRunningProcesses() {
        ChildProcess.terminateAll()
    }

    // MARK: - Availability

    public func availability() async -> ClaudeAvailability {
        await current().availability
    }

    public func refreshAvailability() async -> ClaudeAvailability {
        cached = nil
        return await availability()
    }

    /// The availability (with the usage pause applied) and the binary; cached.
    private func current() async -> (availability: ClaudeAvailability, binary: URL?) {
        if let cached, ContinuousClock.now < cached.expires {
            return (paused(cached.availability), cached.binary)
        }
        let task = probing ?? Task { await self.probe() }
        probing = task
        let (availability, binary) = await task.value
        if probing == task { probing = nil }
        cached = (availability, binary, ContinuousClock.now + configuration.availabilityLifetime)
        return (paused(availability), binary)
    }

    /// Installed and signed in, without a model call: `claude auth status --json` (about 0.2 s)
    /// and `claude --version`.
    private func probe() async -> (ClaudeAvailability, URL?) {
        guard let binary = await locate() else {
            ClaudeClient.logger.info("Claude Code not found")
            return (.notInstalled, nil)
        }
        let environment = Self.childEnvironment(binary: binary)
        var auth: JSONObject?
        do {
            let answer = try await ChildProcess.output(
                ChildProcessSpec(
                    executable: binary, arguments: ["auth", "status", "--json"], environment: environment,
                    directory: nil, input: nil),
                timeout: .seconds(20))
            auth = Self.jsonObject(in: answer.output)
        } catch {
            ClaudeClient.logger.error("claude auth status failed: \(String(describing: error), privacy: .public)")
        }
        guard let auth, auth.bool("loggedIn") == true else {
            ClaudeClient.logger.info("Claude Code is not signed in")
            return (.signedOut, binary)
        }
        var version: String?
        if let answer = try? await ChildProcess.output(
            ChildProcessSpec(executable: binary, arguments: ["--version"], environment: environment, directory: nil, input: nil),
            timeout: .seconds(20)) {
            // "2.1.268 (Claude Code)"
            version = answer.output.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        let status = ClaudeBackendStatus(kind: .claudeCode, version: version, subscription: auth.string("subscriptionType"))
        ClaudeClient.logger.info(
            "Claude Code \(version ?? "?", privacy: .public) ready (\(auth.string("authMethod") ?? "?", privacy: .public), \(status.subscription ?? "?", privacy: .public))"
        )
        return (.ready(status), binary)
    }

    /// `configuration.candidates` in order, then (once) the login shell's `command -v claude`.
    private func locate() async -> URL? {
        let fileManager = FileManager.default
        if let found = configuration.candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return found
        }
        if let shellBinary, fileManager.isExecutableFile(atPath: shellBinary.path) { return shellBinary }
        guard !searchedShell else { return nil }
        searchedShell = true
        let spec = ChildProcessSpec(
            executable: URL(filePath: "/bin/zsh"), arguments: ["-lc", "command -v claude"],
            environment: Self.childEnvironment(binary: nil), directory: nil, input: nil)
        guard let answer = try? await ChildProcess.output(spec, timeout: .seconds(10)) else { return nil }
        // Profile scripts may print first; the path is the last absolute line.
        let path = answer.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }
        guard let path, fileManager.isExecutableFile(atPath: path) else { return nil }
        shellBinary = URL(filePath: path)
        return shellBinary
    }

    // MARK: - Usage pause

    private func paused(_ availability: ClaudeAvailability) -> ClaudeAvailability {
        guard case .ready(var status) = availability else { return availability }
        status.pausedUntil = activePause()
        return .ready(status)
    }

    /// The pause while it holds; an expired one is cleared.
    private func activePause() -> Date? {
        guard let until = state.pausedUntil else { return nil }
        if until > Date() { return until }
        state.pausedUntil = nil
        state.save(to: configuration.stateFile)
        ClaudeClient.logger.info("Claude Code usage pause ended")
        return nil
    }

    private func pause(until: Date) {
        state.pausedUntil = until
        state.save(to: configuration.stateFile)
        ClaudeClient.logger.notice("Claude Code usage limit reached; paused until \(until.formatted(.iso8601), privacy: .public)")
    }

    // MARK: - Calls

    public func streamMessage(
        _ request: MessageRequest, context: CallContext, ledger: any CostLedger,
        onEvent: @escaping @Sendable (StreamEvent) async -> Void
    ) async throws -> Message {
        try await scheduled(context.priority) { binary in
            let call = ClaudeCodeCall(
                binary: binary, configuration: configuration, request: request, context: context, ledger: ledger)
            return try await ClaudeCodeRun.oneShot(call, onEvent: onEvent)
        }
    }

    public func runToolLoop(
        _ request: MessageRequest, context: CallContext, maxIterations: Int, ledger: any CostLedger,
        handler: @escaping ToolHandler, onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> ToolLoopResult {
        let prompts = try ToolLoopPrompts(request.messages)
        return try await scheduled(context.priority) { binary in
            let call = ClaudeCodeCall(
                binary: binary, configuration: configuration, request: request, context: context, ledger: ledger)
            return try await toolLoop(call, maxIterations: maxIterations, prompts: prompts, handler: handler, onEvent: onEvent)
        }
    }

    /// Launches until isolation holds and the session flag fits: `--setting-sources ""` first (or
    /// the variant that worked for this CLI version; the live check found that `--safe-mode` also
    /// drops the `--mcp-config` server in 2.1.268, and a relaunch repeats the prompt in the
    /// session), else `--safe-mode`; `--session-id` ↔ `--resume` swapped once when the CLI says
    /// the session is in use or unknown. The prompt is every user turn the session lacks
    /// (`ToolLoopPrompts`).
    private func toolLoop(
        _ call: ClaudeCodeCall, maxIterations: Int, prompts: ToolLoopPrompts, handler: @escaping ToolHandler,
        onEvent: @escaping @Sendable (ToolLoopEvent) async -> Void
    ) async throws -> ToolLoopResult {
        let version = await current().availability.status?.version ?? "unknown"
        var variant = state.isolation[version] ?? .noSettingSources
        var tried: Set<IsolationVariant> = []
        var session: SessionFlag = call.context.session.map { $0.resumes ? .resume($0.id) : .start($0.id) } ?? .none
        var prompt = prompts.unsent
        var swappedSession = false
        while true {
            tried.insert(variant)
            do {
                let result = try await ClaudeCodeRun.toolLoop(
                    call, maxIterations: maxIterations, prompt: prompt, variant: variant, session: session,
                    handler: handler, onEvent: onEvent)
                if state.isolation[version] != variant {
                    state.isolation[version] = variant
                    state.save(to: configuration.stateFile)
                    ClaudeClient.logger.info("Claude Code \(version, privacy: .public) isolation: \(variant.rawValue, privacy: .public)")
                }
                return result
            } catch RunRelaunch.isolation {
                guard !tried.contains(variant.other) else {
                    throw ClaudeError.claudeCode("the app's tools did not connect in an isolated session")
                }
                variant = variant.other
            } catch RunRelaunch.sessionInUse {
                guard case .start(let id) = session, !swappedSession else {
                    throw ClaudeError.claudeCode("the conversation's session is in use")
                }
                swappedSession = true
                session = .resume(id)
                // An earlier run of this conversation reached the CLI: it holds those turns.
                prompt = prompts.newest
            } catch RunRelaunch.sessionNotFound {
                guard case .resume(let id) = session, !swappedSession else {
                    throw ClaudeError.claudeCode("the conversation's session was not found")
                }
                swappedSession = true
                session = .start(id)
                // The CLI deleted the session (it prunes old ones): the history goes along as text.
                prompt = prompts.replay
                ClaudeClient.logger.notice("Claude Code session gone; the conversation starts again with its history replayed")
            }
        }
    }

    /// Runs `body` with the binary when the queue gives the turn and no usage pause holds. During
    /// a pause every call throws `.usageLimited` at once: a background call never sleeps through
    /// it, since its pipeline's other work (rules, indexing) must go on; it stays pending and the
    /// pipeline wakes itself at the reset.
    private func scheduled<T: Sendable>(_ priority: CallPriority, _ body: (URL) async throws -> T) async throws -> T {
        let (availability, binary) = await current()
        guard availability.isReady, let binary else { throw ClaudeError.unavailable(availability) }
        if let until = activePause() { throw ClaudeError.usageLimited(resetsAt: until) }
        // A call made by a tool of a running loop does not queue behind that loop (it would wait
        // for itself); it runs beside it.
        let queued = !Self.insideToolCall
        if queued { try await queue.acquire(priority) }
        if let until = activePause() {
            // The previous holder hit the limit while this call waited.
            if queued { await queue.release() }
            throw ClaudeError.usageLimited(resetsAt: until)
        }
        do {
            let value = try await body(binary)
            if queued { await queue.release() }
            return value
        } catch let hit as UsageLimitHit {
            if queued { await queue.release() }
            let until = hit.resetsAt.flatMap { $0 > Date() ? $0 : nil } ?? Date().addingTimeInterval(3600)
            pause(until: until)
            throw ClaudeError.usageLimited(resetsAt: until)
        } catch {
            if queued { await queue.release() }
            if let error = error as? ClaudeError {
                switch error {
                case .unavailable, .claudeCode, .claudeCodeProcess: cached = nil  // signed out or gone: check again
                default: break
                }
            }
            throw error
        }
    }

    // MARK: - Helpers

    /// Set while a tool loop's tool handler runs (see `scheduled`).
    @TaskLocal static var insideToolCall = false

    /// The child's whole environment: HOME, USER, LOGNAME, PATH (with the binary's folder), LANG,
    /// TMPDIR. Nothing else from the app (never `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`,
    /// `CLAUDE_CODE_*`, `CLAUDECODE`).
    static func childEnvironment(binary: URL?) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var path = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        if let directory = binary?.deletingLastPathComponent().path, !path.contains(directory) {
            path.insert(directory, at: 0)
        }
        return [
            "HOME": parent["HOME"] ?? NSHomeDirectory(),
            "USER": parent["USER"] ?? NSUserName(),
            "LOGNAME": parent["LOGNAME"] ?? parent["USER"] ?? NSUserName(),
            "PATH": path.joined(separator: ":"),
            "LANG": parent["LANG"] ?? "en_US.UTF-8",
            "TMPDIR": parent["TMPDIR"] ?? NSTemporaryDirectory(),
        ]
    }

    /// The JSON object in a command's output (tolerates text around it).
    static func jsonObject(in output: String) -> JSONObject? {
        guard let open = output.firstIndex(of: "{"), let close = output.lastIndex(of: "}"), open < close else { return nil }
        return (try? JSONValue.parse(String(output[open...close])))?.objectValue
    }
}
#endif
