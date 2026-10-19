import Foundation
import SQLiteData

// Repositories added with schema v13 (M7: the iPhone). The rules (who answers, when) live in
// AppAgent (the Mac's pickup) and ChatUI (the phone's sheet); these only read and write rows.

// MARK: - The phone's questions to the agent

/// The inbox of questions asked on another device (`agent_request`, `agent_request_file`): the
/// phone submits, the Mac claims, answers through `AppAgent.send` and finishes or fails them.
public struct AgentRequestRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    /// The phone's Send: the request (pending) and its files in one transaction.
    @discardableResult
    public func submit(_ request: AgentRequest, files: [AgentRequestFile] = []) async throws -> AgentRequest {
        var request = request
        request.state = .pending
        request.error = nil
        let stamped = store.stamp(request)
        let rows = files.enumerated().map { index, file in
            var file = file
            file.sortOrder = index
            return store.stamp(file)
        }
        try await store.database.write { db in
            try AgentRequest.upsert { stamped }.execute(db)
            for row in rows {
                try AgentRequestFile.upsert { row }.execute(db)
            }
        }
        return stamped
    }

    /// Pending requests asked on another device than `device`, oldest first (the Mac's pickup).
    public func pending(excludingDevice device: String = AgentRequest.mac) async throws -> [AgentRequest] {
        try await store.database.read { db in
            try AgentRequest
                .where { $0.state.eq(AgentRequestState.pending) && $0.device.neq(device) }
                .order { $0.createdAt.asc() }
                .fetchAll(db)
        }
    }

    /// A request's files, in the student's order.
    public func files(of requestID: AgentRequest.ID) async throws -> [AgentRequestFile] {
        try await store.database.read { db in
            try AgentRequestFile.where { $0.requestID.eq(requestID) }.order { $0.sortOrder.asc() }.fetchAll(db)
        }
    }

    /// Takes a pending request for answering (`running`). False when it is no longer pending
    /// (another pass took it, or it was answered meanwhile).
    public func claim(_ id: AgentRequest.ID) async throws -> Bool {
        let stamp = store.currentDate
        return try await store.database.write { db in
            let pending = try AgentRequest
                .where { $0.id.eq(id) && $0.state.eq(AgentRequestState.pending) }
                .fetchCount(db)
            guard pending == 1 else { return false }
            try AgentRequest.find(id).update {
                $0.state = AgentRequestState.running
                $0.error = String?.none
                $0.startedAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
            return true
        }
    }

    /// The Mac answered it in `conversationID` (the request's own, or the new one it started).
    public func finish(_ id: AgentRequest.ID, conversationID: AgentConversation.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentRequest.find(id).update {
                $0.state = AgentRequestState.answered
                $0.conversationID = AgentConversation.ID?.some(conversationID)
                $0.error = String?.none
                $0.answeredAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// The Mac could not answer it; `error` is readable and has no secrets.
    public func fail(_ id: AgentRequest.ID, error: String) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentRequest.find(id).update {
                $0.state = AgentRequestState.failed
                $0.error = String?.some(error)
                $0.answeredAt = Date?.some(stamp)
                $0.updatedAt = stamp
            }
            .execute(db)
        }
    }

    /// A usage pause or a quit stopped the answer: the request waits again (`pending`).
    public func release(_ id: AgentRequest.ID) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentRequest
                .where { $0.id.eq(id) && $0.state.eq(AgentRequestState.running) }
                .update {
                    $0.state = AgentRequestState.pending
                    $0.startedAt = Date?.none
                    $0.updatedAt = stamp
                }
                .execute(db)
        }
    }

    /// At the pickup's start: requests a quit left `running` wait again.
    public func requeueInterrupted() async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            try AgentRequest
                .where { $0.state.eq(AgentRequestState.running) }
                .update {
                    $0.state = AgentRequestState.pending
                    $0.startedAt = Date?.none
                    $0.updatedAt = stamp
                }
                .execute(db)
        }
    }

    /// Requests of a conversation still waiting for their answer or failed (nil: those that
    /// start a new conversation), oldest first: the sheet's bubbles with the skeleton line or
    /// "Not answered".
    public func unanswered(conversationID: AgentConversation.ID?) async throws -> [AgentRequest] {
        let open: [AgentRequestState] = [.pending, .running, .failed]
        return try await store.database.read { db in
            if let conversationID {
                return try AgentRequest
                    .where { $0.conversationID.eq(conversationID) && $0.state.in(open) }
                    .order { $0.createdAt.asc() }
                    .fetchAll(db)
            }
            return try AgentRequest
                .where { $0.conversationID.is(nil) && $0.state.in(open) }
                .order { $0.createdAt.asc() }
                .fetchAll(db)
        }
    }
}
