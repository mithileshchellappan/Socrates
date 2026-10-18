import StudyCore
import SwiftUI

// The agent panel's hooks for feature screens (ma, docs/plan-agent.md §3, §6). The panel itself is
// ChatUI's; screens only say what they show (`.agentContext`), open it (`\.openAgentPanel`) and
// make room while it is expanded (`\.agentPanelExpanded`), without depending on ChatUI.

/// What a screen publishes for the agent panel: the context as it is on screen, and an optional
/// closure the panel calls at ↩ for the exact values that move all the time (Review's playhead).
/// Equal when the published context is equal: the closure never makes the panel re-render.
public struct AgentContextSource: Equatable, Sendable {
    public var context: AgentContext
    public var refine: (@MainActor @Sendable () -> AgentContext)?

    public init(context: AgentContext, refine: (@MainActor @Sendable () -> AgentContext)? = nil) {
        self.context = context
        self.refine = refine
    }

    /// The context at this moment (`refine` merged over the published one).
    @MainActor
    public func current() -> AgentContext {
        guard let refine else { return context }
        return context.merging(refine())
    }

    public static func == (lhs: AgentContextSource, rhs: AgentContextSource) -> Bool {
        lhs.context == rhs.context
    }
}

/// The deepest screen's publication wins (a screen inside the detail over the app's own guess).
public struct AgentContextPreferenceKey: PreferenceKey {
    public static let defaultValue: AgentContextSource? = nil

    public static func reduce(value: inout AgentContextSource?, nextValue: () -> AgentContextSource?) {
        if let next = nextValue() { value = next }
    }
}

extension View {
    /// Tells the agent panel what this screen shows (the lecture with its slide, the calendar's
    /// week, …). Publish the settled values (no playhead: it would re-render the panel ten times a
    /// second); give `refine` for values to read at ↩. The app merges it over what it knows itself
    /// (`AgentContext.merging`).
    public func agentContext(_ context: AgentContext, refine: (@MainActor @Sendable () -> AgentContext)? = nil) -> some View {
        preference(key: AgentContextPreferenceKey.self, value: AgentContextSource(context: context, refine: refine))
    }
}

/// Opens the agent panel (compact, its composer focused), or expanded. Calendar's [+] uses it.
public struct OpenAgentPanelAction: Sendable {
    private let handler: @MainActor @Sendable (_ expanded: Bool) -> Void

    public init(_ handler: @escaping @MainActor @Sendable (_ expanded: Bool) -> Void) {
        self.handler = handler
    }

    @MainActor
    public func callAsFunction(expanded: Bool = false) {
        handler(expanded)
    }
}

extension EnvironmentValues {
    /// Opens the agent panel; a no-op until the app installs the panel (previews, iOS, no Claude Code).
    @Entry public var openAgentPanel = OpenAgentPanelAction { _ in }
    /// The agent panel is expanded into the window's trailing sidebar: a screen with its own
    /// inspector (Review, Calendar) hides it meanwhile (never two inspectors).
    @Entry public var agentPanelExpanded = false
}
