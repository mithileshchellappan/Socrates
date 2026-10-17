import ClaudeKit
import Deadlines
import Foundation
import StudyCore

/// The agent tool runtime, the deadline tools, transcript extraction and the composer's agent
/// path: workstream A fills this in (docs/plan-m3.md §3). Logs through
/// `Log.logger(category: "agent")`.
public enum AgentModule {
    public static let moduleName = "Agent"

    /// `api_call.purpose` prefix of this package's calls ("agent.deadlines", "agent.transcript").
    public static let purposePrefix = "agent."
}
