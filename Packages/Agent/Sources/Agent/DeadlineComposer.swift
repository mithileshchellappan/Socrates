import Deadlines
import Foundation
import StudyCore

/// Calendar's "New deadline" field (docs/plan-m3.md §3.4).
///
/// - `preview`: the local parse (`DeadlineParser`) with cached courses; never touches the network.
/// - `submit`: with an agent runtime whose client is available (M3.5: Claude Code) the text goes to a `deadlines`
///   conversation and `.agent(id)` returns at once; when the run ends without writing anything
///   (it failed, or only answered), the local parse is added when it has a date (the student's
///   words are never lost; a quit mid-run is caught up at the next launch by
///   `AgentRuntime.recoverInterrupted`). Without it the local parse is added directly
///   (`created_by = user`, a `chat` source quoting the text, into the calendar when it is due
///   work); no date → `.notUnderstood`.
public actor DeadlineComposer {
    let services: StudyServices
    let memory: DeadlineMemory
    let runtime: AgentRuntime?
    let now: @Sendable () -> Date
    private var courses: [Course] = []
    private var coursesLoadedAt: Date?
    /// Courses are read again after this long (a course added meanwhile is found).
    static let courseCacheLifetime: TimeInterval = 60

    public init(
        services: StudyServices,
        memory: DeadlineMemory,
        runtime: AgentRuntime?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.services = services
        self.memory = memory
        self.runtime = runtime
        self.now = now
    }

    /// The dashed preview of what ↩ would add (local, no network); nil for empty text or no date.
    public func preview(_ text: String, now: Date) async -> DeadlineDraft? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return DeadlineParser.parse(text, now: now, courses: await cachedCourses())
    }

    /// ↩ in the composer.
    public func submit(_ text: String, now: Date) async throws -> DeadlineSubmission {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notUnderstood }
        let draft = DeadlineParser.parse(trimmed, now: now, courses: await cachedCourses(reload: true))
        if let runtime, await runtime.isAvailable() {
            let id = try await runtime.start(.deadlines, text: trimmed)
            let memory = memory
            let services = services
            Task {
                guard let ended = await runtime.outcome(id), ended.state != .running, let draft else { return }
                await Self.addUnlessWritten(draft, text: trimmed, conversationID: id, services: services, memory: memory)
            }
            return .agent(id)
        }
        guard let draft else { return .notUnderstood }
        let result = try await memory.record(Self.finding(draft, text: trimmed, conversationID: nil))
        return .added(result.item.id)
    }

    /// The local parse of what the student told a conversation that wrote nothing (no source
    /// quotes it): added as their own words.
    static func addUnlessWritten(
        _ draft: DeadlineDraft, text: String, conversationID: AgentConversation.ID, services: StudyServices, memory: DeadlineMemory
    ) async {
        do {
            let wrote = try await services.database.read { db in
                try TrackedItemSource.where { $0.conversationID.eq(AgentConversation.ID?.some(conversationID)) }.fetchCount(db) > 0
            }
            guard !wrote else { return }
            _ = try await memory.record(finding(draft, text: text, conversationID: conversationID))
        } catch {
            AgentModule.log.error("Adding the composer's parse failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The student's own words, parsed deterministically: verified and trusted by construction.
    static func finding(_ draft: DeadlineDraft, text: String, conversationID: AgentConversation.ID?) -> ItemFinding {
        ItemFinding(
            draft: draft, source: .chat(conversationID), quote: text, confidence: 1, dateVerified: true, trusted: true,
            createdBy: .user
        )
    }

    private func cachedCourses(reload: Bool = false) async -> [Course] {
        let current = now()
        if !reload, let loaded = coursesLoadedAt, current.timeIntervalSince(loaded) < Self.courseCacheLifetime, current >= loaded {
            return courses
        }
        do {
            courses = try await services.database.read { db in try Course.order(by: \.sortOrder).fetchAll(db) }
            coursesLoadedAt = current
        } catch {
            AgentModule.log.error("Reading courses failed: \(String(describing: error), privacy: .public)")
        }
        return courses
    }
}
