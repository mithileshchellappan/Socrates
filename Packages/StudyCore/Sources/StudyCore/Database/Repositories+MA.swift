import Foundation
import SQLiteData

// Repositories added with schema v11 (milestone ma: one agent across the app). The rules (which
// change may be applied, how a task runs) live in AppAgent; these only read and write rows.

// MARK: - Sub-agent tasks

/// The sub-agent task queue's rows (`agent_task`). Every state change is one column-only update.
public struct AgentTaskRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Queues a task.
    @discardableResult
    public func enqueue(_ task: AgentTask) async throws -> AgentTask {
        var task = task
        task.state = .queued
        return try await store.save(task)
    }

    /// Queued, running and paused tasks, oldest first (the panel's task line and list).
    public func open() async throws -> [AgentTask] {
        try await store.database.read { db in
            try AgentTask.where { $0.state.in(AgentTaskState.open) }.order { $0.createdAt.asc() }.fetchAll(db)
        }
    }

    /// The tasks a conversation spawned, oldest first (the panel shows finished results in its thread).
    public func tasks(parent conversationID: AgentConversation.ID) async throws -> [AgentTask] {
        try await store.database.read { db in
            try AgentTask.where { $0.parentConversationID.eq(conversationID) }.order { $0.createdAt.asc() }.fetchAll(db)
        }
    }

    /// Starts up to `slots` minus the running ones, oldest queued first (the student's before the
    /// agent's), in one transaction: they are `running` with one more attempt. A paused task whose
    /// time has come is queued again first.
    public func claim(slots: Int, now: Date) async throws -> [AgentTask] {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let due = try AgentTask
                .where { $0.state.eq(AgentTaskState.paused) }
                .fetchAll(db)
                .filter { ($0.pausedUntil ?? .distantPast) <= now }
            for task in due {
                try AgentTask.find(task.id).update {
                    $0.state = AgentTaskState.queued
                    $0.pausedUntil = Date?.none
                    $0.updatedAt = stamp
                }
                .execute(db)
            }
            let running = try AgentTask.where { $0.state.eq(AgentTaskState.running) }.fetchCount(db)
            let free = max(0, slots - running)
            guard free > 0 else { return [] }
            let queued = try AgentTask.where { $0.state.eq(AgentTaskState.queued) }.order { $0.createdAt.asc() }.fetchAll(db)
            let picked = Array(queued.sorted { first, second in
                if first.createdBy != second.createdBy { return first.createdBy == .user }
                return first.createdAt < second.createdAt
            }.prefix(free))
            var started: [AgentTask] = []
            for var task in picked {
                task.state = .running
                task.attempts += 1
                task.startedAt = task.startedAt ?? stamp
                task.updatedAt = stamp
                try AgentTask.find(task.id).update {
                    $0.state = AgentTaskState.running
                    $0.attempts = task.attempts
                    $0.startedAt = task.startedAt
                    $0.updatedAt = stamp
                }
                .execute(db)
                started.append(task)
            }
            return started
        }
    }

    /// Records the task's own conversation (set on its first run).
    public func setConversation(_ id: AgentTask.ID, _ conversationID: AgentConversation.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentTask.find(id).update {
                $0.conversationID = AgentConversation.ID?.some(conversationID)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// Ends a task: `succeeded` with its result, or `failed` / `cancelled` with a readable error.
    public func finish(_ id: AgentTask.ID, _ state: AgentTaskState, result: String? = nil, error: String? = nil) async throws {
        let stamp = store.currentDate
        let result = result.map { String($0.prefix(AgentTask.resultLimit)) }
        try await store.database.write { db in
            try AgentTask.find(id).update {
                $0.state = state
                $0.result = result
                $0.error = error
                $0.finishedAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// A usage limit stopped the task: it waits until `until`, then queues again (`claim`).
    public func pause(_ id: AgentTask.ID, until: Date) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentTask.find(id).update {
                $0.state = AgentTaskState.paused
                $0.pausedUntil = Date?.some(until)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// Cancels an open task (the runner ends a running one's process first); nothing for a
    /// finished one.
    public func cancel(_ id: AgentTask.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentTask
                .where { $0.id.eq(id) && $0.state.in(AgentTaskState.open) }
                .update {
                    $0.state = AgentTaskState.cancelled
                    $0.finishedAt = Date?.some(stamp)
                    $0.updatedAt = stamp
                }
                .execute(db)
        }
    }

    /// At launch: tasks a quit left `running` queue again; one at its attempt limit fails.
    public func requeueInterrupted() async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            for task in try AgentTask.where({ $0.state.eq(AgentTaskState.running) }).fetchAll(db) {
                if task.attempts >= AgentTask.maximumAttempts {
                    try AgentTask.find(task.id).update {
                        $0.state = AgentTaskState.failed
                        $0.error = String?.some("Interrupted \(task.attempts) times")
                        $0.finishedAt = Date?.some(stamp)
                        $0.updatedAt = stamp
                    }
                    .execute(db)
                } else {
                    try AgentTask.find(task.id).update {
                        $0.state = AgentTaskState.queued
                        $0.updatedAt = stamp
                    }
                    .execute(db)
                }
            }
        }
    }

    /// Finished tasks of a conversation whose result no user turn has carried yet.
    public func unreported(parent conversationID: AgentConversation.ID) async throws -> [AgentTask] {
        try await store.database.read { db in
            try AgentTask
                .where { $0.parentConversationID.eq(conversationID) && $0.reportedAt.is(nil) && $0.finishedAt.isNot(nil) }
                .order { $0.finishedAt.asc() }
                .fetchAll(db)
        }
    }

    /// The next user turn carried these results.
    public func markReported(_ ids: [AgentTask.ID]) async throws {
        guard !ids.isEmpty else { return }
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentTask.where { $0.id.in(ids) }.update {
                $0.reportedAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }
}

// MARK: - Activity log

/// The activity log (`agent_change`): every automatic change, written with the change itself.
/// Rows are never deleted; Undo stamps `undone_at` after the change applier put the target back.
public struct AgentChangeRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Writes a change row (use `insert(_:db:)` inside the transaction that makes the change).
    @discardableResult
    public func log(_ change: AgentChange) async throws -> AgentChange {
        try await store.save(change)
    }

    /// Writes a change row inside the caller's transaction (the change and its row commit together).
    public static func insert(_ change: AgentChange, db: Database) throws {
        try AgentChange.upsert { change }.execute(db)
    }

    /// Changes applied since `date`, newest first ("what did you change yesterday?").
    public func recent(since date: Date, limit: Int = 50) async throws -> [AgentChange] {
        try await store.database.read { db in
            try AgentChange
                .where { $0.appliedAt.gte(date) }
                .order { $0.appliedAt.desc() }
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// The changes of one row, newest first (the item's or session's history; conflicts).
    public func changes(target: AgentChangeTarget, id: UUID) async throws -> [AgentChange] {
        try await store.database.read { db in
            try AgentChange
                .where { $0.targetTable.eq(target) && $0.targetID.eq(id) }
                .order { $0.appliedAt.desc() }
                .fetchAll(db)
        }
    }

    /// The change a `[[change 1a2b3c4d]]` marker names: nil unless exactly one id starts with `key`.
    public func change(key: String) async throws -> AgentChange? {
        let key = key.lowercased()
        guard key.count == 8, key.allSatisfy(\.isHexDigit) else { return nil }
        return try await store.database.read { db in
            let ids = try String.fetchAll(db, sql: #"SELECT "id" FROM "agent_change" WHERE "id" LIKE ? LIMIT 2"#, arguments: [key + "%"])
            guard ids.count == 1, let id = UUID(uuidString: ids[0]) else { return nil }
            return try AgentChange.find(id).fetchOne(db)
        }
    }

    /// The change written with an item source (an item's popover Undo).
    public func change(sourceID: TrackedItemSource.ID) async throws -> AgentChange? {
        try await store.database.read { db in
            try AgentChange.where { $0.trackedItemSourceID.eq(sourceID) }.order { $0.appliedAt.desc() }.fetchOne(db)
        }
    }

    /// Stamps `undone_at` (the applier already put the target back, in the same transaction when
    /// it can: `markUndone(_:at:db:)`).
    public func markUndone(_ id: AgentChange.ID, at date: Date) async throws {
        try await store.database.write { db in try Self.markUndone(id, at: date, db: db) }
    }

    public static func markUndone(_ id: AgentChange.ID, at date: Date, db: Database) throws {
        try AgentChange.find(id).update {
            $0.undoneAt = Date?.some(date)
            $0.updatedAt = date
        }
        .execute(db)
    }

    /// A newer change of the same target and field replaced `old` (kept, with its sources).
    public static func supersede(_ old: AgentChange.ID, by new: AgentChange.ID, at date: Date, db: Database) throws {
        try AgentChange.find(old).update {
            $0.supersededBy = AgentChange.ID?.some(new)
            $0.updatedAt = date
        }
        .execute(db)
    }
}

// MARK: - Triage inbox

/// The triage inbox (`agent_event`).
public struct AgentEventRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// Records a new fact; nil (nothing written) when an event with its `source_key` exists.
    @discardableResult
    public func record(_ event: AgentEvent) async throws -> AgentEvent? {
        let stamped = store.stamp(event)
        return try await store.database.write { db in
            let exists = try AgentEvent.where { $0.sourceKey.eq(event.sourceKey) }.fetchCount(db) > 0
            guard !exists else { return nil }
            try AgentEvent.upsert { stamped }.execute(db)
            return stamped
        }
    }

    /// Pending events, oldest first.
    public func pending(limit: Int = 50) async throws -> [AgentEvent] {
        try await store.database.read { db in
            try AgentEvent.where { $0.state.eq(AgentEventState.pending) }.order { $0.createdAt.asc() }.limit(limit).fetchAll(db)
        }
    }

    /// Sets the state of events a batch read (column-only); a failure counts an attempt and turns
    /// `failed` at the limit, else stays `pending`.
    public func setState(
        _ ids: [AgentEvent.ID], _ state: AgentEventState, apiCallID: APICall.ID? = nil, taskID: AgentTask.ID? = nil, error: String? = nil
    ) async throws {
        guard !ids.isEmpty else { return }
        let stamp = store.currentDate
        try await store.database.write { db in
            for event in try AgentEvent.where({ $0.id.in(ids) }).fetchAll(db) {
                var next = state
                var attempts = event.attempts
                if state == .failed {
                    attempts += 1
                    if attempts < AgentEvent.maximumAttempts { next = .pending }
                }
                let triaged: Date? = next == .pending ? nil : stamp
                try AgentEvent.find(event.id).update {
                    $0.state = next
                    $0.attempts = attempts
                    $0.error = error
                    $0.apiCallID = apiCallID ?? event.apiCallID
                    $0.taskID = taskID ?? event.taskID
                    $0.triagedAt = triaged
                    $0.updatedAt = stamp
                }
                .execute(db)
            }
        }
    }
}

// MARK: - Reminders

/// The agent's reminders (`agent_reminder`); delivery is AppAgent's (macOS notifications).
public struct AgentReminderRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    @discardableResult
    public func schedule(_ reminder: AgentReminder) async throws -> AgentReminder {
        try await store.save(reminder)
    }

    /// Reminders not delivered nor cancelled that fire before `date`, soonest first.
    public func pending(before date: Date) async throws -> [AgentReminder] {
        try await store.database.read { db in
            try AgentReminder
                .where { $0.deliveredAt.is(nil) && $0.cancelledAt.is(nil) && $0.fireAt.lt(date) }
                .order { $0.fireAt.asc() }
                .fetchAll(db)
        }
    }

    public func markDelivered(_ id: AgentReminder.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentReminder.find(id).update {
                $0.deliveredAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// Cancels one reminder, or every open reminder of an item (its change was undone, it is done).
    public func cancel(_ id: AgentReminder.ID? = nil, itemID: TrackedItem.ID? = nil) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            if let id {
                try AgentReminder.where { $0.id.eq(id) && $0.cancelledAt.is(nil) }
                    .update { $0.cancelledAt = Date?.some(stamp); $0.updatedAt = stamp }
                    .execute(db)
            }
            if let itemID {
                try AgentReminder.where { $0.trackedItemID.eq(itemID) && $0.cancelledAt.is(nil) && $0.deliveredAt.is(nil) }
                    .update { $0.cancelledAt = Date?.some(stamp); $0.updatedAt = stamp }
                    .execute(db)
            }
        }
    }
}
