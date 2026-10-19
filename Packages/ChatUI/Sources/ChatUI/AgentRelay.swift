import Foundation
import StudyCore

// M7, the iPhone's agent (docs/plan-m7.md §4): the phone never runs Claude. Send writes the
// question as an `agent_request` row (with its files as `agent_request_file` rows: the BlobStore
// does not sync) into the same `app` conversation the Mac's panel shows; the Mac's AppAgent picks
// it up (`AgentRequestPickup`) and answers through `AppAgent.send`; the answer's turns come back
// through iCloud sync.
//
// A new chat: the phone writes the empty `app` conversation row itself (state `finished`, the
// title from the first words as the Mac names one) and the request names it. The Mac's runtime
// answers a conversation without turns like a new one: `AgentRuntime.send` starts a new Claude
// Code session (`--session-id`, not `--resume`) while the conversation has no assistant turn, and
// the first turn carries the memory, catalog and context blocks as `start` would. So a follow-up
// asked before the Mac answered goes to the same conversation, and the history menu lists the
// new chat at once (on the phone and, through sync, on the Mac).

extension AgentPanelActions {
    /// The phone's actions (the sheet): `send` writes a request (and its files) for the Mac and
    /// returns the conversation's id (a new chat's row is written first); nothing streams here;
    /// Cancel of a sub-agent task cancels its row (the Mac's queue follows `agent_task`); Stop and
    /// Undo are the Mac's.
    ///
    /// - Parameters:
    ///   - isAvailable: the Mac can answer (iCloud sync runs: `CloudSync.isRunning`). False: no
    ///     launcher, no sheet, nothing disabled.
    ///   - device: `agent_request.device` (`AgentRequest.iPhone`).
    public static func relay(services: StudyServices, isAvailable: Bool, device: String = AgentRequest.iPhone) -> AgentPanelActions {
        AgentPanelActions(
            isAvailable: isAvailable,
            send: { text, context, attachments, conversationID in
                try await AgentRelay(services: services, device: device).send(text, context: context, attachments: attachments, to: conversationID)
            },
            cancelTask: { id in
                do {
                    try await AgentTaskRepository(store: services.records).cancel(id)
                } catch {
                    ChatUILog.ui.error("Cancelling a task failed: \(String(describing: error), privacy: .public)")
                }
            }
        )
    }
}

/// Writes the phone's questions for the Mac (`AgentPanelActions.relay`).
struct AgentRelay: Sendable {
    let services: StudyServices
    let device: String

    /// Nothing to send (no words, no files).
    struct EmptyMessage: Error {}

    func send(
        _ text: String, context: AgentContext, attachments: [AgentAttachment], to conversationID: AgentConversation.ID?
    ) async throws -> AgentConversation.ID {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { throw EmptyMessage() }
        let requestID = UUID()
        // The files' bytes ride in the request's rows (blobs do not sync).
        var files: [AgentRequestFile] = []
        for (index, attachment) in attachments.enumerated() {
            let data = try Data(contentsOf: services.blobs.url(for: attachment.blob), options: .mappedIfSafe)
            files.append(AgentRequestFile(
                requestID: requestID, sortOrder: index, fileName: attachment.fileName, contentType: attachment.contentType, data: data
            ))
        }
        var created: AgentConversation.ID?
        let id: AgentConversation.ID
        if let conversationID {
            id = conversationID
        } else {
            // A new chat: its row now, named as the Mac names one (the first words, else the
            // first file's name).
            let date = services.records.currentDate
            let title = trimmed.isEmpty ? (attachments.first?.fileName ?? String(localized: "Files")) : trimmed
            let conversation = try await ConversationRepository(store: services.records).start(AgentConversation(
                kind: .app, courseID: context.courseID, title: String(title.prefix(60)), state: .finished, createdAt: date, updatedAt: date
            ))
            id = conversation.id
            created = conversation.id
        }
        do {
            try await AgentRequestRepository(store: services.records).submit(
                AgentRequest(id: requestID, conversationID: id, text: trimmed, context: context, device: device), files: files
            )
        } catch {
            // No empty new chat is left behind by a question that did not go.
            if let created {
                _ = try? await services.database.write { db in try AgentConversation.find(created).delete().execute(db) }
            }
            throw error
        }
        return id
    }
}
