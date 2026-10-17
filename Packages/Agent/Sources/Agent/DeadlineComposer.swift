import Deadlines
import Foundation
import StudyCore

/// Calendar's "New deadline" field (docs/plan-m3.md §3.4).
///
/// - `preview`: the local parse (`DeadlineParser`) with cached courses; never touches the network.
/// - `submit`: with an agent runtime and a saved API key the text goes to a `deadlines`
///   conversation and `.agent(id)` returns at once; if that conversation fails, the local parse is
///   added when it has a date (the student's words are never lost). Without a key the local parse
///   is added directly (`created_by = user`, a `chat` source quoting the text, into the calendar
///   when it is due work); no date → `.notUnderstood`.
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
        if let runtime, services.secrets.hasSecret(for: .anthropicAPIKey) {
            let id = try await runtime.start(.deadlines, text: trimmed)
            let memory = memory
            Task {
                guard let ended = await runtime.outcome(id), ended.state == .failed, let draft else { return }
                do {
                    _ = try await memory.record(Self.finding(draft, text: trimmed, conversationID: id))
                } catch {
                    AgentModule.log.error("Adding the composer's parse failed: \(String(describing: error), privacy: .public)")
                }
            }
            return .agent(id)
        }
        guard let draft else { return .notUnderstood }
        let result = try await memory.record(Self.finding(draft, text: trimmed, conversationID: nil))
        return .added(result.item.id)
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
