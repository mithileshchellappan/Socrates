import Foundation
import StudyCore

/// The document bank (docs/plan-docs.md §4 "Adding", "Deleting"): adds the student's files (a drop,
/// Import…, the agent's `keep_document`), copies each into the BlobStore (a file already kept
/// returns its document), reads its text off the main actor one document at a time, then queues
/// its summary (`DocumentRepository.queueSummary`: an `agent_task` of kind `document`, Haiku, run
/// by AppAgent's queue). Deleting keeps what Undo needs; the file is removed at a later launch when
/// `BlobUsage` finds no row using it. Mac only: documents never sync (`Schema.macOnlyTableNames`)
/// and the iPhone has no Documents screen.
///
/// Wiring (the integrator, plan §7.2):
///
///     let bank = DocumentBank(services: services)
///     await bank.start()            // returns at once; after the database opens, before the agent
///     // \.documentActions from it (DocumentsUI), FilingCenter's document drop, AppAgent(…, documents: bank)
///
/// Contract skeleton (md architect): workstream A builds it; the cancel-then-delete order and the
/// summary re-queue after Undo are the contract.
public actor DocumentBank {
    public let services: StudyServices
    let now: @Sendable () -> Date

    /// The summary task's model and effort (`agent_task.model`, `.effort`).
    public static let summaryModel = DocumentSummarizer.model.rawValue
    public static let summaryEffort = DocumentSummarizer.effort.rawValue
    /// How long after `start()` the resumed reading begins, and the file removal.
    public static let resumeDelay: Duration = .seconds(20)
    public static let cleanupDelay: Duration = .seconds(60)

    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.now = now
    }

    var documents: DocumentRepository { DocumentRepository(store: services.records) }

    /// At launch. Returns at once: nothing is read, OCR'd or removed on the launch path. It
    /// schedules, at `.utility` after `resumeDelay`, reading the documents a quit left unread
    /// (`waitingForText`, one at a time) and queueing summaries still missing (`waitingForSummary`
    /// → `queueSummary`); at `.background` after `cleanupDelay`, removing the files of documents
    /// deleted in an earlier session that `BlobUsage.isUsed` finds unused.
    public func start() {}

    /// Adds files (a drop, Import…; security-scoped URLs are accessed here): one addition per file
    /// taken, in order (a file already kept: its document, `isNew` false). Files of other types,
    /// over `StudyDocument.maximumBytes` or unreadable are skipped (logged); throws a
    /// `DocumentReadError` only when no file could be taken ("This file is larger than 200 MB.").
    /// Reading starts at once off the main actor; the summary is queued when the text is read.
    @discardableResult
    public func add(_ urls: [URL], by author: Author = .user) async throws -> [DocumentAddition] {
        _ = (urls, author)
        return []
    }

    /// A file the student attached on the agent panel ("keep this"): its bytes are in the
    /// BlobStore already.
    public func add(attachment: AgentAttachment, by author: Author = .agent) async throws -> DocumentAddition {
        _ = (attachment, author)
        throw DocumentReadError("This file can’t be kept yet.")
    }

    /// Deletes a document: its open `document` task is cancelled first through
    /// `AgentTaskRepository.cancel` (AppAgent's queue stops a running summary when its row turns
    /// `cancelled`), then the rows go (`DocumentRepository.delete`: pages and chunks cascade). A
    /// adds: its file joins the pending-removal list (removed at a later launch when unused, never
    /// in this session: Undo). Nil when it is gone already.
    public func delete(_ id: StudyDocument.ID) async throws -> DocumentDeletion? {
        let tasks = AgentTaskRepository(store: services.records)
        for task in try await documents.openTasks(of: id) {
            try await tasks.cancel(task.id)
        }
        return try await documents.delete(id)
    }

    /// Undo of `delete`: the rows back, then the work the delete stopped: a summary still pending
    /// is queued again here; A adds reading a text still `pending` (off the main actor) and taking
    /// the file off the pending-removal list.
    public func restore(_ deletion: DocumentDeletion) async throws {
        try await documents.restore(deletion)
        try await documents.queueSummary(
            deletion.document.id, model: Self.summaryModel, effort: Self.summaryEffort, by: deletion.document.createdBy
        )
    }

    /// Read Again after a failure: the text when it failed (read again off the main actor), else
    /// the summary (`resetSummary` then `queueSummary`).
    public func retry(_ id: StudyDocument.ID) async {
        _ = id
    }
}
