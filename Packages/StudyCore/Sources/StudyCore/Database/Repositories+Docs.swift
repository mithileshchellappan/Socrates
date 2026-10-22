import Foundation
import SQLiteData

// Repositories added with schema v14 (md: the document bank). The rules (what is read, when the
// summary runs, what the agent sees) live in Documents (`DocumentBank`, `DocumentSummarizer`) and
// AppAgent; these only read and write rows. docs/plan-docs.md §3–4.

/// The kept documents (`document`, `document_page`).
public struct DocumentRepository: Sendable {
    public let store: RecordStore
    public init(store: RecordStore) { self.store = store }

    // MARK: Reading

    /// Every document of `role`, newest first: by default the student's own (the Documents list,
    /// the agent's catalog; mt: course materials' files and snapshots are role `material`); nil:
    /// every document.
    public func all(role: DocumentRole? = .personal) async throws -> [StudyDocument] {
        try await store.database.read { db in
            if let role {
                return try StudyDocument.where { $0.role.eq(role) }.order { $0.addedAt.desc() }.fetchAll(db)
            }
            return try StudyDocument.order { $0.addedAt.desc() }.fetchAll(db)
        }
    }

    public func document(_ id: StudyDocument.ID) async throws -> StudyDocument? {
        try await store.fetch(StudyDocument.self, id: id)
    }

    /// The document whose original has this SHA-256 (a file added twice is "known").
    public func document(sha256: String) async throws -> StudyDocument? {
        try await store.database.read { db in
            try StudyDocument.where { $0.blobSHA256.eq(sha256) }.order { $0.addedAt.asc() }.fetchOne(db)
        }
    }

    /// A document's pages in order; `range`: only those page numbers.
    public func pages(of id: StudyDocument.ID, range: ClosedRange<Int>? = nil) async throws -> [StudyDocumentPage] {
        try await store.database.read { db in
            if let range {
                return try StudyDocumentPage
                    .where { $0.documentID.eq(id) && $0.pageNumber.gte(range.lowerBound) && $0.pageNumber.lte(range.upperBound) }
                    .order(by: \.pageNumber)
                    .fetchAll(db)
            }
            return try StudyDocumentPage.where { $0.documentID.eq(id) }.order(by: \.pageNumber).fetchAll(db)
        }
    }

    /// Documents whose text is still to be read (added, or a quit interrupted reading), oldest first.
    public func waitingForText() async throws -> [StudyDocument] {
        try await store.database.read { db in
            try StudyDocument.where { $0.textState.eq(DocumentTextState.pending) }.order { $0.addedAt.asc() }.fetchAll(db)
        }
    }

    /// Documents with their text whose summary is not written yet, oldest first.
    public func waitingForSummary() async throws -> [StudyDocument] {
        try await store.database.read { db in
            try StudyDocument
                .where { $0.textState.eq(DocumentTextState.done) && $0.summaryState.eq(DocumentSummaryState.pending) }
                .order { $0.addedAt.asc() }
                .fetchAll(db)
        }
    }

    /// The documents the summary related to `courseID`, newest first (a course's screens).
    public func related(to courseID: Course.ID) async throws -> [StudyDocument] {
        try await all().filter { $0.courseIDs.contains(courseID) }
    }

    // MARK: Writing

    /// The open (queued, running, paused) `document` tasks of a document: the bank cancels them
    /// with `AgentTaskRepository.cancel` before it deletes the document.
    public func openTasks(of id: StudyDocument.ID) async throws -> [AgentTask] {
        let reference = StudyDocument.ID?.some(id)
        return try await store.database.read { db in
            try AgentTask.where { $0.documentID.eq(reference) && $0.state.in(AgentTaskState.open) }.fetchAll(db)
        }
    }

    /// Adds a document (its text and summary pending) unless one of the same file (`blob_sha256`)
    /// is kept already, which comes back instead (`isNew` false). The check and the insert are one
    /// write transaction: two adds of the same file at once keep one row.
    @discardableResult
    public func add(_ document: StudyDocument) async throws -> DocumentAddition {
        let stamped = store.stamp(document)
        return try await store.database.write { db in
            let sha = stamped.blobSHA256
            let known = sha.isEmpty ? nil : try StudyDocument.where { $0.blobSHA256.eq(sha) }.order { $0.addedAt.asc() }.fetchOne(db)
            if let known { return DocumentAddition(document: known, isNew: false) }
            try StudyDocument.upsert { stamped }.execute(db)
            return DocumentAddition(document: stamped, isNew: true)
        }
    }

    /// Queues the summary task (`agent_task` kind `document`, no tools) of a document whose text is
    /// read and whose summary is pending, in one transaction; nothing (nil) when it is gone, has no
    /// text yet, its summary is not pending, or an open `document` task for it exists. So an add,
    /// `DocumentBank.start()`, Undo and Read Again can all call it without queueing it twice.
    /// mt: `written` also queues it for a document whose summary is written (a personal document
    /// that became a course material: the runner writes its materials' card).
    @discardableResult
    public func queueSummary(
        _ id: StudyDocument.ID, model: String, effort: String, by author: Author, evenWhenWritten written: Bool = false
    ) async throws -> AgentTask? {
        let stamp = store.currentDate
        let reference = StudyDocument.ID?.some(id)
        return try await store.database.write { db in
            guard let document = try StudyDocument.find(id).fetchOne(db), document.textState == .done,
                  document.summaryState == .pending || (written && document.summaryState == .done)
            else { return nil }
            let open = try AgentTask.where { $0.documentID.eq(reference) && $0.state.in(AgentTaskState.open) }.fetchCount(db)
            guard open == 0 else { return nil }
            let task = AgentTask(
                kind: .document, title: "Read \u{201C}\(document.fileName)\u{201D}",
                goal: "Write the summary, kind, courses, key facts and dates of a kept document.", model: model, effort: effort,
                tools: [], documentID: id, createdBy: author, createdAt: stamp, updatedAt: stamp
            )
            try AgentTask.upsert { task }.execute(db)
            return task
        }
    }

    /// The text was read: the pages replace any earlier ones, in one transaction with the row
    /// (`text_state done`, its page count, text hash, language and outline; `error` cleared).
    public func setText(
        _ id: StudyDocument.ID, pages: [StudyDocumentPage], textSHA256: String, language: String, outline: [DocumentSection]
    ) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var document = try StudyDocument.find(id).fetchOne(db) else { return }
            try StudyDocumentPage.where { $0.documentID.eq(id) }.delete().execute(db)
            for var page in pages {
                page.updatedAt = stamp
                try StudyDocumentPage.upsert { page }.execute(db)
            }
            document.textState = .done
            document.pageCount = pages.count
            document.textSHA256 = textSHA256
            document.language = language
            document.outline = outline
            document.error = nil
            if document.summaryState == .skipped { document.summaryState = .pending }
            document.updatedAt = stamp
            try StudyDocument.upsert { document }.execute(db)
        }
    }

    /// The text could not be read (`error`: one readable sentence); nothing to summarise.
    public func setTextFailed(_ id: StudyDocument.ID, error: String) async throws {
        try await update(id) { document in
            document.textState = .failed
            document.summaryState = .skipped
            document.error = error
        }
    }

    /// The summary task's result.
    public func setSummary(_ id: StudyDocument.ID, _ summary: DocumentSummary) async throws {
        let stamp = store.currentDate
        try await update(id) { document in
            document.title = summary.title.isEmpty ? document.title : summary.title
            document.kind = summary.kind
            document.summary = summary.summary
            document.keyFacts = summary.keyFacts
            document.dates = summary.dates
            document.courseIDs = summary.courseIDs
            if document.outline.isEmpty { document.outline = summary.outline }
            document.summaryHash = summary.summaryHash
            document.model = summary.model
            document.apiCallID = summary.apiCallID
            document.summarizedAt = stamp
            document.summaryState = .done
            document.error = nil
        }
    }

    /// The summary could not be written (`error`: one readable sentence).
    public func setSummaryFailed(_ id: StudyDocument.ID, error: String) async throws {
        try await update(id) { document in
            document.summaryState = .failed
            document.error = error
        }
    }

    /// A summary task ended without writing a summary (the student cancelled it, or it was
    /// interrupted too often): the summary fails with `error`, so Read Again offers it and the next
    /// launch does not queue it again. Nothing when the document is gone, its summary is no longer
    /// pending, or another `document` task for it is open (Undo, Read Again queued one). One
    /// transaction; whether it closed it.
    @discardableResult
    public func closeSummary(_ id: StudyDocument.ID, error: String) async throws -> Bool {
        let stamp = store.currentDate
        let reference = StudyDocument.ID?.some(id)
        return try await store.database.write { db in
            guard var document = try StudyDocument.find(id).fetchOne(db), document.summaryState == .pending else { return false }
            let open = try AgentTask.where { $0.documentID.eq(reference) && $0.state.in(AgentTaskState.open) }.fetchCount(db)
            guard open == 0 else { return false }
            document.summaryState = .failed
            document.error = error
            document.updatedAt = stamp
            try StudyDocument.upsert { document }.execute(db)
            return true
        }
    }

    /// The newest `document` task of a document (any state; nil: none).
    public func latestTask(of id: StudyDocument.ID) async throws -> AgentTask? {
        let reference = StudyDocument.ID?.some(id)
        return try await store.database.read { db in
            try AgentTask.where { $0.documentID.eq(reference) }.order { $0.createdAt.desc() }.fetchOne(db)
        }
    }

    /// Read Again: the text is read again when it failed, else the summary waits to be written again.
    public func resetSummary(_ id: StudyDocument.ID) async throws {
        try await update(id) { document in
            if document.textState == .failed {
                document.textState = .pending
            }
            document.summaryState = .pending
            document.summaryHash = nil
            document.error = nil
        }
    }

    /// Deletes a document in one transaction: its pages and search chunks go with it (CASCADE).
    /// Returns what `restore` needs (nil: no such document). Its open task is not touched here:
    /// `DocumentBank.delete` cancels it first through `AgentTaskRepository.cancel` (AppAgent's
    /// queue then stops a running summary). The file stays in the BlobStore (the bank removes it
    /// at a later launch when `BlobUsage` finds no row using it).
    public func delete(_ id: StudyDocument.ID) async throws -> DocumentDeletion? {
        try await store.database.write { db in
            guard let document = try StudyDocument.find(id).fetchOne(db) else { return nil }
            let pages = try StudyDocumentPage.where { $0.documentID.eq(id) }.order(by: \.pageNumber).fetchAll(db)
            try StudyDocument.find(id).delete().execute(db)
            return DocumentDeletion(document: document, pages: pages)
        }
    }

    /// mt: a document's role changes (a course material's file the student keeps on Documents
    /// too, or a kept document deleted there that a course material still uses). Search moves its
    /// chunks to the role's kind.
    public func setRole(_ id: StudyDocument.ID, _ role: DocumentRole) async throws {
        try await update(id) { document in document.role = role }
    }

    /// Undo of `delete`: the row and its pages again, as they were (Search re-cuts the chunks).
    /// The bank then reads a text that was still pending and queues a summary that was
    /// (`queueSummary`), as their work was stopped by the delete.
    public func restore(_ deletion: DocumentDeletion) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            var document = deletion.document
            document.updatedAt = stamp
            try StudyDocument.upsert { document }.execute(db)
            for var page in deletion.pages {
                page.updatedAt = stamp
                try StudyDocumentPage.upsert { page }.execute(db)
            }
        }
    }

    // MARK: Support

    private func update(_ id: StudyDocument.ID, _ change: @Sendable (inout StudyDocument) -> Void) async throws {
        let stamp = store.currentDate
        try await store.database.write { db in
            guard var document = try StudyDocument.find(id).fetchOne(db) else { return }
            change(&document)
            document.updatedAt = stamp
            try StudyDocument.upsert { document }.execute(db)
        }
    }
}
