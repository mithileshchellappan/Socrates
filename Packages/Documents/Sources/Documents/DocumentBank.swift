import Foundation
import StudyCore
import Synchronization
import UniformTypeIdentifiers

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
/// - **Reading** is one serial worker (`.utility`): one document at a time, `DocumentExtractor`
///   in a detached task, then `setText` (or `setTextFailed` with the readable sentence), then
///   `queueSummary`. A quit leaves `text_state pending`; `start()` resumes it later.
/// - **Removal of files** of deleted documents: the file goes on a persisted pending list
///   (`<library>/DocumentBank/pending-removals.json`) with the time of the delete; a later launch
///   (after `cleanupDelay`, `.background`) removes those deleted before it started, only when no
///   row uses the hash any more (`BlobUsage.isUsed`). Never in the session that deleted it (Undo).
/// - Logs never carry a document's text, title or file name at `.public`.
public actor DocumentBank {
    public let services: StudyServices
    let now: @Sendable () -> Date

    /// The summary task's model and effort (`agent_task.model`, `.effort`).
    public static let summaryModel = DocumentSummarizer.model.rawValue
    public static let summaryEffort = DocumentSummarizer.effort.rawValue
    /// How long after `start()` the resumed reading begins, and the file removal.
    public static let resumeDelay: Duration = .seconds(20)
    public static let cleanupDelay: Duration = .seconds(60)

    /// Documents waiting for the reader, in order.
    private var readQueue: [StudyDocument.ID] = []
    private var reader: Task<Void, Never>?
    /// The document being read now and its extraction (`delete` cancels it: a scan deleted while
    /// it is OCR'd stops between pages, and the reader goes on with the next document).
    private var currentRead: (id: StudyDocument.ID, work: Task<ExtractedDocument, any Error>)?
    private var resumeWork: Task<Void, Never>?
    private var cleanupWork: Task<Void, Never>?
    private var started = false

    public init(services: StudyServices, now: @escaping @Sendable () -> Date = { Date() }) {
        self.services = services
        self.now = now
    }

    var documents: DocumentRepository { DocumentRepository(store: services.records) }

    // MARK: - Launch

    /// At launch. Returns at once: nothing is read, OCR'd or removed on the launch path. It
    /// schedules, at `.utility` after `resumeDelay`, reading the documents a quit left unread
    /// (`waitingForText`, one at a time) and queueing summaries still missing (`waitingForSummary`
    /// → `queueSummary`); at `.background` after `cleanupDelay`, removing the files of documents
    /// deleted in an earlier session that `BlobUsage.isUsed` finds unused.
    public func start() {
        guard !started else { return }
        started = true
        let launchedAt = now()
        resumeWork = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: Self.resumeDelay) } catch { return }
            await self?.resume()
        }
        cleanupWork = Task(priority: .background) { [weak self] in
            do { try await Task.sleep(for: Self.cleanupDelay) } catch { return }
            await self?.removeFiles(deletedBefore: launchedAt)
        }
    }

    /// The app quits: the scheduled work and the reader stop (a document being read stays
    /// `pending` and is read again at the next launch).
    public func stop() {
        resumeWork?.cancel()
        cleanupWork?.cancel()
        reader?.cancel()
        resumeWork = nil
        cleanupWork = nil
        reader = nil
        readQueue = []
    }

    private func resume() async {
        do {
            for document in try await documents.waitingForText() { enqueueRead(document.id) }
            for document in try await documents.waitingForSummary() {
                // A summary whose task the student cancelled, or that failed (interrupted too
                // often), is not queued again by a launch: it fails, and Read Again offers it.
                if let task = try await documents.latestTask(of: document.id), task.state == .cancelled || task.state == .failed {
                    try await documents.closeSummary(document.id, error: DocumentSummarizer.failure)
                    continue
                }
                try await documents.queueSummary(document.id, model: Self.summaryModel, effort: Self.summaryEffort, by: document.createdBy)
            }
        } catch {
            DocumentsModule.log.error("Resuming documents failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Adding

    /// Adds files (a drop, Import…; security-scoped URLs are accessed here): one addition per file
    /// taken, in order (a file already kept: its document, `isNew` false). Files of other types,
    /// over `StudyDocument.maximumBytes` or unreadable are skipped (logged); throws a
    /// `DocumentReadError` only when no file could be taken ("This file is larger than 200 MB.").
    /// Reading starts at once off the main actor; the summary is queued when the text is read.
    @discardableResult
    public func add(_ urls: [URL], by author: Author = .user) async throws -> [DocumentAddition] {
        var additions: [DocumentAddition] = []
        var firstError: DocumentReadError?
        for url in urls {
            do {
                additions.append(try await add(url, by: author))
            } catch let error as DocumentReadError {
                DocumentsModule.log.notice("A file was not kept: \(error.sentence, privacy: .public)")
                firstError = firstError ?? error
            } catch {
                DocumentsModule.log.error("Adding a file failed: \(String(describing: error), privacy: .private)")
                firstError = firstError ?? .unreadable
            }
        }
        if additions.isEmpty, let firstError { throw firstError }
        return additions
    }

    private func add(_ url: URL, by author: Author) async throws -> DocumentAddition {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isPackageKey, .fileSizeKey])
        let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
        guard let kind = StudyDocument.fileKind(for: type) else { throw DocumentReadError.unsupported }
        let blobs = services.blobs
        let blob: BlobRef
        if values?.isDirectory == true {
            // A Pages package: kept as the single-file Pages format (a zip of its contents).
            guard kind == .pages else { throw DocumentReadError.unsupported }
            blob = try await Self.storePackage(url, blobs: blobs)
        } else {
            if let size = values?.fileSize, size > StudyDocument.maximumBytes { throw DocumentReadError.tooLarge }
            // Copied (never moved) off the actor: hashing a large file takes a moment.
            blob = try await Task.detached(priority: .utility) {
                do {
                    return try blobs.importFile(at: url, mode: .copy)
                } catch {
                    throw DocumentReadError.unreadable
                }
            }.value
        }
        guard (blob.byteCount ?? 0) <= Int64(StudyDocument.maximumBytes) else { throw DocumentReadError.tooLarge }
        let fileName = url.lastPathComponent
        return try await keep(
            blob: blob, fileName: fileName, type: type, byteCount: Int(blob.byteCount ?? 0), author: author
        )
    }

    /// A Pages package zipped into the BlobStore (`ditto`), at most `maximumBytes`.
    private static func storePackage(_ package: URL, blobs: BlobStore) async throws -> BlobRef {
        #if os(macOS)
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appending(path: "Socrates-package-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fileManager.removeItem(at: directory) }
        let zip = directory.appending(path: package.lastPathComponent)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw DocumentReadError.unreadable
        }
        guard await DocumentExtractor.zipPackage(package, to: zip) else { throw DocumentReadError.unreadable }
        let size = (try? zip.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= StudyDocument.maximumBytes else { throw DocumentReadError.tooLarge }
        return try await Task.detached(priority: .utility) {
            do {
                return try blobs.importFile(at: zip, mode: .move)
            } catch {
                throw DocumentReadError.unreadable
            }
        }.value
        #else
        _ = (package, blobs)
        throw DocumentReadError.macOnly
        #endif
    }

    /// A file the student attached on the agent panel ("keep this"): its bytes are in the
    /// BlobStore already.
    public func add(attachment: AgentAttachment, by author: Author = .agent) async throws -> DocumentAddition {
        guard services.blobs.contains(attachment.blob) else { throw DocumentReadError.missing }
        let type = UTType(attachment.contentType) ?? UTType(filenameExtension: (attachment.fileName as NSString).pathExtension) ?? .data
        guard StudyDocument.fileKind(for: type) != nil else { throw DocumentReadError.unsupported }
        guard attachment.byteCount <= StudyDocument.maximumBytes else { throw DocumentReadError.tooLarge }
        return try await keep(
            blob: attachment.blob, fileName: attachment.fileName, type: type, byteCount: attachment.byteCount, author: author
        )
    }

    /// The row for a file in the BlobStore (its text and summary pending; the file name without
    /// its extension as the title until the summary names it), then reading.
    private func keep(blob: BlobRef, fileName: String, type: UTType, byteCount: Int, author: Author) async throws -> DocumentAddition {
        let date = now()
        let stem = (fileName as NSString).deletingPathExtension
        let addition = try await documents.add(StudyDocument(
            title: stem.isEmpty ? fileName : stem, fileName: fileName, fileType: type.identifier, blobSHA256: blob.sha256,
            blobPath: blob.relativePath, byteCount: byteCount, createdBy: author, addedAt: date, updatedAt: date
        ))
        if addition.isNew {
            // A file deleted earlier and added again is no longer to be removed.
            PendingRemovals.remove(blob.sha256, at: pendingFile)
            enqueueRead(addition.document.id)
        }
        return addition
    }

    // MARK: - Reading

    private func enqueueRead(_ id: StudyDocument.ID) {
        if !readQueue.contains(id) { readQueue.append(id) }
        guard reader == nil else { return }
        reader = Task(priority: .utility) { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !readQueue.isEmpty, !Task.isCancelled {
            let id = readQueue.removeFirst()
            await read(id)
        }
        reader = nil
    }

    /// Reads one document's text (if it is still there and still pending), stores its pages and
    /// queues its summary; a failure stores the readable sentence.
    private func read(_ id: StudyDocument.ID) async {
        do {
            guard let document = try await documents.document(id), document.textState == .pending else { return }
            guard let blob = document.blob, services.blobs.contains(blob) else {
                try await documents.setTextFailed(id, error: DocumentReadError.missing.sentence)
                return
            }
            let url = services.blobs.url(for: blob)
            let type = UTType(document.fileType) ?? UTType(filenameExtension: url.pathExtension) ?? .data
            let started = ContinuousClock.now
            let work = Task(priority: .utility) { try await DocumentExtractor.extract(fileAt: url, type: type) }
            currentRead = (id, work)
            defer { currentRead = nil }
            let extracted: ExtractedDocument
            do {
                extracted = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            } catch is CancellationError {
                return
            } catch let error as DocumentReadError {
                if Task.isCancelled || work.isCancelled { return }
                try await documents.setTextFailed(id, error: error.sentence)
                return
            }
            if Task.isCancelled || work.isCancelled { return }
            let pages = extracted.pages.map { page in
                StudyDocumentPage(
                    documentID: id, pageNumber: page.pageNumber, label: page.label, heading: page.heading, text: page.text, isOCR: page.isOCR
                )
            }
            // A document deleted meanwhile: `setText` finds no row and writes nothing.
            try await documents.setText(id, pages: pages, textSHA256: extracted.textSHA256, language: extracted.language, outline: extracted.outline)
            let elapsed = ContinuousClock.now - started
            DocumentsModule.log.info("""
                Read a document: \(pages.count) pages, \(pages.filter(\.isOCR).count) by OCR \
                in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds])), privacy: .public)
                """)
            try await documents.queueSummary(id, model: Self.summaryModel, effort: Self.summaryEffort, by: document.createdBy)
        } catch {
            DocumentsModule.log.error("Reading a document failed: \(String(describing: error), privacy: .private)")
            if !Task.isCancelled { try? await documents.setTextFailed(id, error: DocumentReadError.unreadable.sentence) }
        }
    }

    // MARK: - Deleting

    /// Deletes a document: the rows go (`DocumentRepository.delete`: pages and chunks cascade),
    /// then its open `document` task is cancelled through `AgentTaskRepository.cancel` (AppAgent's
    /// queue stops a running summary when its row turns `cancelled`; the row is gone first, so the
    /// stopped run closes no summary state that Undo would bring back) and reading it stops. Its
    /// file joins the pending-removal list (removed at a later launch when unused, never in this
    /// session: Undo). Nil when it is gone already.
    public func delete(_ id: StudyDocument.ID) async throws -> DocumentDeletion? {
        let open = try await documents.openTasks(of: id)
        guard let deletion = try await documents.delete(id) else { return nil }
        let tasks = AgentTaskRepository(store: services.records)
        for task in open {
            do {
                try await tasks.cancel(task.id)
            } catch {
                DocumentsModule.log.error("Cancelling a deleted document's summary failed: \(String(describing: error), privacy: .public)")
            }
        }
        readQueue.removeAll { $0 == id }
        if currentRead?.id == id { currentRead?.work.cancel() }
        if let blob = deletion.document.blob {
            PendingRemovals.add(blob, deletedAt: now(), at: pendingFile)
        }
        return deletion
    }

    /// Undo of `delete`: the rows back, the file off the pending-removal list, then the work the
    /// delete stopped: a text still `pending` is read again (off the main actor) and a summary
    /// still pending is queued again.
    public func restore(_ deletion: DocumentDeletion) async throws {
        try await documents.restore(deletion)
        PendingRemovals.remove(deletion.document.blobSHA256, at: pendingFile)
        if deletion.document.textState == .pending { enqueueRead(deletion.document.id) }
        try await documents.queueSummary(
            deletion.document.id, model: Self.summaryModel, effort: Self.summaryEffort, by: deletion.document.createdBy
        )
    }

    /// Read Again after a failure: the text when it failed (read again off the main actor), else
    /// the summary (`resetSummary` then `queueSummary`). An open summary task is cancelled first,
    /// so the new one can be queued.
    public func retry(_ id: StudyDocument.ID) async {
        do {
            guard let document = try await documents.document(id) else { return }
            let tasks = AgentTaskRepository(store: services.records)
            for task in try await documents.openTasks(of: id) {
                try await tasks.cancel(task.id)
            }
            try await documents.resetSummary(id)
            if document.textState == .failed || document.textState == .pending {
                enqueueRead(id)
            } else {
                try await documents.queueSummary(id, model: Self.summaryModel, effort: Self.summaryEffort, by: document.createdBy)
            }
        } catch {
            DocumentsModule.log.error("Read Again failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Removing files

    var pendingFile: URL {
        services.paths.root.appending(path: "DocumentBank", directoryHint: .isDirectory).appending(path: "pending-removals.json")
    }

    /// Removes the files of documents deleted before this launch that no row uses any more; the
    /// rest stay listed (a file deleted in this session waits for a later launch).
    private func removeFiles(deletedBefore launch: Date) async {
        let file = pendingFile
        let due = PendingRemovals.load(at: file).filter { $0.deletedAt < launch }
        guard !due.isEmpty else { return }
        var settled: [String] = []
        var removed = 0
        for entry in due {
            if Task.isCancelled { break }
            do {
                let used = try await services.database.read { db in try BlobUsage.isUsed(entry.sha256, in: db) }
                if !used {
                    try services.blobs.remove(BlobRef(sha256: entry.sha256, relativePath: entry.relativePath))
                    removed += 1
                }
                // A file a row uses again (Undo, the same file added again, a deck) is no longer
                // the bank's to remove.
                settled.append(entry.sha256)
            } catch {
                DocumentsModule.log.error("Removing a deleted document's file failed: \(String(describing: error), privacy: .public)")
            }
        }
        PendingRemovals.remove(settled, at: file)
        if removed > 0 { DocumentsModule.log.info("Removed \(removed) files of deleted documents") }
    }
}

/// The persisted list of files whose documents were deleted (JSON). Every read-modify-write holds
/// one process-wide lock, so a second bank (the agent's Undo of `keep_document`) never loses an
/// entry.
enum PendingRemovals {
    struct Entry: Codable, Hashable, Sendable {
        var sha256: String
        var relativePath: String
        var deletedAt: Date
    }

    private static let lock = Mutex(())

    static func load(at file: URL) -> [Entry] {
        lock.withLock { _ in read(file) }
    }

    static func add(_ blob: BlobRef, deletedAt: Date, at file: URL) {
        lock.withLock { _ in
            var entries = read(file).filter { $0.sha256 != blob.sha256 }
            entries.append(Entry(sha256: blob.sha256, relativePath: blob.relativePath, deletedAt: deletedAt))
            write(entries, to: file)
        }
    }

    static func remove(_ sha256: String, at file: URL) {
        remove([sha256], at: file)
    }

    static func remove(_ hashes: [String], at file: URL) {
        guard !hashes.isEmpty else { return }
        lock.withLock { _ in
            let entries = read(file)
            let kept = entries.filter { !hashes.contains($0.sha256) }
            if kept.count != entries.count { write(kept, to: file) }
        }
    }

    private static func read(_ file: URL) -> [Entry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        // Dates as seconds (full precision: a delete right after launch stays after it).
        let decoder = JSONDecoder()
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    private static func write(_ entries: [Entry], to file: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(entries).write(to: file, options: .atomic)
        } catch {
            DocumentsModule.log.error("Saving the files to remove failed: \(String(describing: error), privacy: .public)")
        }
    }
}
