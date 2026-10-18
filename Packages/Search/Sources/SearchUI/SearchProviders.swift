import Search
import SwiftUI

/// What the search screen asks beyond the keyword index (M5): the query planner ("Also
/// searched", Haiku through Claude Code) and the on-device semantic index. Installed by the app
/// as `\.searchProviders` (the Mac: `HaikuQueryPlanner` on the app's client and its
/// `SemanticIndex`; iOS, renders and snapshots: none). Without them the screen searches keywords
/// and still shows a cached plan from `search_plan`.
public struct SearchProviders: Sendable {
    public var planner: (any QueryPlanning)?
    public var semantic: (any SemanticSearching)?

    public init(planner: (any QueryPlanning)? = nil, semantic: (any SemanticSearching)? = nil) {
        self.planner = planner
        self.semantic = semantic
    }
}

extension EnvironmentValues {
    /// The search screen's planner and semantic index (`SearchProviders`); none by default.
    @Entry public var searchProviders = SearchProviders()
}
