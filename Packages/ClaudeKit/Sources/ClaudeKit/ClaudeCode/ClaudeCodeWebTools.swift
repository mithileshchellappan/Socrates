#if os(macOS)
import Foundation

// M4 (docs/plan-m4.md §3.4, §7 "A details" 1): one-shot calls with Claude Code's own web tools,
// for the study pass's research runs. The request's `.webSearch` / `.webFetch` become the CLI's
// built-in WebSearch / WebFetch; nothing else is allowed in such a run.

/// The CLI's built-in web tools a one-shot call asked for.
struct WebToolSet: Sendable, Hashable {
    /// CLI tool names in a fixed order ("WebSearch", "WebFetch").
    let names: [String]
    /// `--max-turns`: the largest `maxUses` of the tools (the CLI has no per-tool limit), else 8.
    let maxTurns: Int

    static let defaultMaxTurns = 8
    static let webSearch = "WebSearch"
    static let webFetch = "WebFetch"
    /// The tool the CLI adds for `--json-schema` (its structured-output round).
    static let structuredOutputTool = "StructuredOutput"

    /// Nil for a request without tools. Custom and raw tools throw `invalidArgument` (they need a
    /// tool loop). Domain filters cannot be expressed on the CLI: they are logged and ignored.
    init?(_ tools: [Tool]) throws {
        guard !tools.isEmpty else { return nil }
        var wanted: Set<String> = []
        var uses: [Int] = []
        var filtered = false
        for tool in tools {
            switch tool {
            case .webSearch(let search):
                wanted.insert(Self.webSearch)
                if let maxUses = search.maxUses { uses.append(maxUses) }
                filtered = filtered || search.allowedDomains != nil || search.blockedDomains != nil
            case .webFetch(let fetch):
                wanted.insert(Self.webFetch)
                if let maxUses = fetch.maxUses { uses.append(maxUses) }
                filtered = filtered || fetch.allowedDomains != nil || fetch.blockedDomains != nil
            default:
                throw ClaudeError.invalidArgument(
                    "Claude Code one-shot calls take only web search and web fetch; \(tool.name) needs a ToolLoop")
            }
        }
        if filtered {
            ClaudeClient.logger.notice("Claude Code cannot restrict web tools to domains; the domain filters are ignored")
        }
        names = [Self.webSearch, Self.webFetch].filter(wanted.contains)
        maxTurns = max(1, uses.max() ?? Self.defaultMaxTurns)
    }

    /// The flags after the shared ones: isolation, no MCP server, only these tools allowed without
    /// asking, the turn limit, no session file.
    func arguments(variant: IsolationVariant) -> [String] {
        variant.arguments + [
            "--strict-mcp-config", "--allowedTools", names.joined(separator: ","), "--permission-mode", "dontAsk",
            "--disable-slash-commands", "--max-turns", String(maxTurns), "--no-session-persistence",
        ]
    }

    /// The `system/init` check: exactly these tools (plus the CLI's structured-output tool when a
    /// schema is set) and no MCP server. Anything else means the student's setup leaked in.
    func holds(_ initLine: JSONObject, structured: Bool, variant: IsolationVariant) -> Bool {
        let servers = (initLine.array("mcp_servers") ?? []).map { $0["name"]?.stringValue ?? "?" }
        var listed = Set((initLine.array("tools") ?? []).compactMap(\.stringValue))
        if structured { listed.remove(Self.structuredOutputTool) }
        let holds = servers.isEmpty && listed == Set(names)
        if !holds {
            let other = listed.subtracting(names).sorted()
            ClaudeClient.logger.notice(
                "Claude Code web init (\(variant.rawValue, privacy: .public)): servers \(servers.joined(separator: ","), privacy: .public), tools \(listed.sorted().joined(separator: ","), privacy: .public), unexpected \(other.joined(separator: ","), privacy: .public)"
            )
        }
        return holds
    }
}
#endif
