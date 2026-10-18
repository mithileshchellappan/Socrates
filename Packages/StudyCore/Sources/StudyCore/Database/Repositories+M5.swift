import Foundation
import SQLiteData

// Repositories added with schema v9 (M5: search & tutor).

/// The agent memory (`agent_memory`): what the agent's tools write and the Memory sheet edits.
/// The tools check their quote before they call `remember` / `revise` / `forget` (Agent); the
/// repository only writes. Nothing is deleted: `forget` sets `forgotten_at`.
public struct AgentMemoryRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Memories not forgotten, in the sheet's order: You, Preferences, then by course; oldest
    /// first within each.
    public func active() async throws -> [AgentMemory] {
        let memories = try await store.database.read { db in
            try AgentMemory.where { $0.forgottenAt.is(nil) }.order(by: \.createdAt).fetchAll(db)
        }
        return Self.ordered(memories)
    }

    /// `memories` in the sheet's order (`AgentMemoryKind.displayOrder`, unknown kinds last; course
    /// memories grouped by course in first-written order).
    public static func ordered(_ memories: [AgentMemory]) -> [AgentMemory] {
        let order = AgentMemoryKind.displayOrder
        var courseOrder: [Course.ID: Int] = [:]
        for memory in memories.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let course = memory.courseID, courseOrder[course] == nil { courseOrder[course] = courseOrder.count }
        }
        return memories.enumerated().sorted { first, second in
            let a = first.element
            let b = second.element
            let kindA = order.firstIndex(of: a.kind) ?? order.count
            let kindB = order.firstIndex(of: b.kind) ?? order.count
            if kindA != kindB { return kindA < kindB }
            let courseA = a.courseID.flatMap { courseOrder[$0] } ?? -1
            let courseB = b.courseID.flatMap { courseOrder[$0] } ?? -1
            if courseA != courseB { return courseA < courseB }
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return first.offset < second.offset
        }
        .map(\.element)
    }

    /// Writes a new memory.
    @discardableResult
    public func remember(_ memory: AgentMemory) async throws -> AgentMemory {
        var memory = memory
        memory.text = String(memory.text.prefix(AgentMemory.textLimit))
        return try await store.save(memory)
    }

    /// The agent's `update_memory`: new text (and the quote it was written from); column-only.
    public func revise(_ id: AgentMemory.ID, text: String, quote: String, conversationID: AgentConversation.ID?) async throws {
        let stamp = store.currentDate
        let text = String(text.prefix(AgentMemory.textLimit))
        try await store.database.write { db in
            try AgentMemory.find(id).update {
                $0.text = text
                $0.quote = quote
                $0.conversationID = conversationID
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// The student's edit in the Memory sheet (sets `edited_at`); column-only.
    public func edit(_ id: AgentMemory.ID, text: String) async throws {
        let stamp = store.currentDate
        let text = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(AgentMemory.textLimit))
        try await store.database.write { db in
            try AgentMemory.find(id).update {
                $0.text = text
                $0.editedAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// Forgets a memory (the student's Forget or the agent's `forget`): `forgotten_at`, never a delete.
    public func forget(_ id: AgentMemory.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentMemory.find(id).update {
                $0.forgottenAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }
}
