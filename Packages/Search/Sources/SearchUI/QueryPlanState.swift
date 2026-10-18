import Search
import StudyCore
import SwiftUI

/// "Also searched" for the screen's query (M5, docs/plan-m5.md §1): the cached plan
/// (`search_plan`) at once, else, with a planner installed, one call once the query settled
/// (typing paused 1 s, or ↩) and has a whole word of 3+ letters. At most one call in flight; a new
/// query cancels it. The first results never wait for any of this: the screen searches at once
/// and again when the alternatives land.
@MainActor
@Observable
final class QueryPlanState {
    /// How long typing must pause before the planner is asked.
    static let settle: Duration = .seconds(1)

    private(set) var query = ""
    private(set) var alternatives: [String] = []
    /// Terms the student removed (× on hover) for this query.
    private(set) var removed: Set<String> = []

    @ObservationIgnored private var task: Task<Void, Never>?
    /// The task is waiting for the query to settle (↩ asks at once instead).
    @ObservationIgnored private var settling = false

    /// The alternatives searched and shown: the plan minus the removed terms.
    var shown: [String] { alternatives.filter { !removed.contains($0) } }

    /// Follows the screen's query: a new text drops the old plan and starts on the new one.
    func follow(_ query: String, courseID: Course.ID?, engine: SearchEngine) {
        guard query != self.query else { return }
        self.query = query
        alternatives = []
        removed = []
        start(courseID: courseID, engine: engine, waits: true)
    }

    /// ↩ in the search field: a query still settling is planned now.
    func submit(courseID: Course.ID?, engine: SearchEngine) {
        guard settling else { return }
        start(courseID: courseID, engine: engine, waits: false)
    }

    func remove(_ term: String) {
        removed.insert(term)
    }

    /// The screen went away: a call in flight is cancelled; the next `follow` starts over (the
    /// cache answers a planned query at once).
    func stop() {
        task?.cancel()
        task = nil
        settling = false
        query = ""
        alternatives = []
        removed = []
    }

    private func start(courseID: Course.ID?, engine: SearchEngine, waits: Bool) {
        task?.cancel()
        settling = false
        let query = query
        guard !SearchQuery(query).isEmpty else {
            task = nil
            return
        }
        task = Task { [weak self] in
            if let cached = await QueryPlans.cached(query, in: engine.database) {
                self?.land(cached, for: query)
                return
            }
            guard engine.planner != nil, QueryPlans.isPlannable(query) else { return }
            if waits {
                self?.settling = true
                do { try await Task.sleep(for: Self.settle) } catch { return }
                self?.settling = false
            }
            guard let alternatives = try? await engine.plannedAlternatives(for: SearchQuery(query, courseID: courseID)) else {
                return
            }
            self?.land(alternatives, for: query)
        }
    }

    private func land(_ alternatives: [String], for query: String) {
        guard query == self.query, !Task.isCancelled else { return }
        self.alternatives = alternatives
    }
}
